import CoreImage
import Foundation
import Observation
import SwiftUI
import UIKit

/// The brain of the app. Drives the loop:
///
///   user question (typed or spoken)
///     -> [if spoken] Whisper transcribes
///     -> grab the CURRENT camera frame (one screenshot, not the stream)
///     -> Qwen3-VL answers about that frame
///     -> Kokoro speaks the answer
///
/// UI only reads `phase`, `transcript`, and `partialAnswer`.
@MainActor
@Observable
final class VisionPipeline {

    // Observable UI state
    private(set) var phase: PipelinePhase = .idle
    private(set) var transcript: [Interaction] = []
    private(set) var partialAnswer: String = ""
    /// The question/answer currently shown on screen. Cleared automatically a
    /// few seconds after the answer has finished being spoken.
    private(set) var visibleQuestion: String?
    private(set) var visibleAnswer: String?
    /// True while the vision model is still loading into memory. The UI shows a
    /// glowing "initializing" badge so a slow first answer doesn't look frozen.
    private(set) var isModelLoading = false
    /// Set if the vision model failed to load, so the UI can show why instead of
    /// glowing forever.
    private(set) var modelLoadError: String?

    // Dependencies
    private let camera: CameraManager
    private let stt: any SpeechToTextService
    private let tts: any TextToSpeechService
    private let vlm: any VisionLanguageService
    private let recorder: AudioRecorder

    private var currentTask: Task<Void, Never>?

    init(
        camera: CameraManager,
        stt: any SpeechToTextService,
        tts: any TextToSpeechService,
        vlm: any VisionLanguageService,
        recorder: AudioRecorder
    ) {
        self.camera = camera
        self.stt = stt
        self.tts = tts
        self.vlm = vlm
        self.recorder = recorder
    }

    /// Warm up the models in the background so the first question is fast.
    /// Tracks the vision model's readiness so the UI can show a loading glow.
    func warmUp() {
        guard !isModelLoading else { return }
        isModelLoading = true
        modelLoadError = nil
        let vlm = self.vlm, stt = self.stt, tts = self.tts
        Task {
            if await vlm.loadState.isReady == false {
                do {
                    try await vlm.prepare()
                } catch {
                    modelLoadError = error.localizedDescription
                    print("[LocalVision] Vision model failed to load: \(error)")
                }
            }
            isModelLoading = false
            // STT/TTS can finish warming after the badge clears; they're not
            // needed to show the first answer on screen.
            Task.detached(priority: .utility) {
                try? await stt.prepare()
                try? await tts.prepare()
            }
        }
    }

    func retryModelLoad() {
        modelLoadError = nil
        warmUp()
    }

    // MARK: Text input path

    /// User typed a question and hit send.
    func submit(text question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run { await self.handle(question: trimmed) }
    }

    // MARK: Voice input path

    func startVoiceInput() {
        // The push-to-talk gesture fires onChanged repeatedly while the finger
        // moves — only the first call may start a recording, or it would be
        // restarted over and over and transcription would get an empty file.
        guard phase != .listening else { return }
        phase = .listening // set synchronously so re-entrant gesture calls bail
        run {
            guard await self.recorder.requestPermission() else {
                self.phase = .error("Microphone permission denied")
                return
            }
            _ = try? await self.recorder.startRecording()
        }
    }

    /// User released the talk button; transcribe then run the same handler.
    func finishVoiceInput() {
        run {
            guard let url = await self.recorder.stopRecording() else {
                self.phase = .idle
                return
            }
            self.phase = .transcribing
            do {
                let question = try await self.stt.transcribe(audioAt: url)
                await self.handle(question: question)
            } catch {
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Core handler (shared by text + voice)

    private func handle(question: String) async {
        transcript.append(Interaction(role: .user, text: question))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        clearTask?.cancel()
        visibleQuestion = question
        visibleAnswer = nil

        // One frame, captured the instant the question lands.
        phase = .capturingFrame
        guard let frame = camera.captureCurrentFrame() else {
            phase = .error("No camera frame available")
            return
        }

        phase = .thinking
        partialAnswer = ""
        await tts.stop()
        do {
            // Cooperative interleaving: if the TTS engine is loaded, it hands
            // us a synchronous synthesizer that the vision service calls on
            // its generation thread with each completed sentence — generation
            // pauses for a beat per sentence, the audio plays while the rest
            // is still being written. Same thread + same GPU = no contention.
            let inline = await tts.inlineSynthesizer

            let answer = try await vlm.answer(
                question: question,
                about: frame,
                onToken: { token in
                    Task { @MainActor in self.partialAnswer = token }
                },
                onSentence: inline
            )
            transcript.append(Interaction(role: .assistant, text: answer))
            partialAnswer = ""
            visibleAnswer = answer

            phase = .speaking
            if inline == nil {
                // Engine wasn't ready for interleaving — speak now, chunked
                // and gapless (chunk N+1 synthesizes while N plays).
                for chunk in Self.sentenceChunks(of: answer) {
                    enqueueSpeech(chunk)
                }
                await speechTask?.value
            }
            await tts.finishSpeaking()   // queued audio finished playing
            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }
        scheduleClear()
    }

    /// Fade the on-screen conversation out 6 seconds after speech finished.
    private var clearTask: Task<Void, Never>?
    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                self.visibleQuestion = nil
                self.visibleAnswer = nil
            }
        }
    }

    // MARK: Sentence-chunked speech

    private var speechTask: Task<Void, Never>?

    /// Split an answer into sentences so playback can start after the first
    /// one while the rest still synthesize.
    private static func sentenceChunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                chunks.append(current)
                current = ""
            }
        }
        chunks.append(current)
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Serialized SYNTHESIS chain: `enqueueSpeech` on the service returns as
    /// soon as the chunk's audio is queued (gapless), so chunk N+1 synthesizes
    /// while chunk N is still playing — no pause between sentences.
    private func enqueueSpeech(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        let previous = speechTask
        let tts = self.tts
        speechTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let streamed = (try? await tts.enqueueSpeech(sentence)) ?? false
            if !streamed {
                // Engine without streaming support (system TTS fallback).
                try? await tts.speak(sentence)
            }
        }
    }

    // MARK: Helpers

    func cancel() {
        currentTask?.cancel()
        speechTask?.cancel()
        speechTask = nil
        Task { await tts.stop() }
        phase = .idle
    }

    private func run(_ operation: @escaping () async -> Void) {
        currentTask?.cancel()
        currentTask = Task { await operation() }
    }
}
