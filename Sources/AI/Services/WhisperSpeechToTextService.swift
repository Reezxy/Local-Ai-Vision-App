import AVFoundation
import Foundation
import SwiftWhisper

/// Wraps the non-Sendable `Whisper` so it can cross into a nonisolated async
/// helper without a data-race diagnostic. whisper.cpp is internally serialized.
private struct WhisperBox: @unchecked Sendable {
    let whisper: Whisper
    init(_ whisper: Whisper) { self.whisper = whisper }
}

/// Whisper speech-to-text via whisper.cpp (SwiftWhisper). The ggml model is
/// downloaded to the device on first use and reused after that.
actor WhisperSpeechToTextService: SpeechToTextService {

    /// `base.en` = 148 MB, a solid speed/accuracy balance for phones.
    /// Swap for `ggml-small.en.bin` (488 MB) for higher accuracy, or
    /// `ggml-tiny.en.bin` (78 MB) for lowest latency.
    private let modelFilename: String
    private let remoteURL: URL

    private var whisper: Whisper?
    private var state: ModelLoadState = .notLoaded
    /// Shared by concurrent `prepare()` callers so the model is only loaded once.
    private var loadTask: Task<Void, Error>?

    init(modelFilename: String = "ggml-base.en.bin") {
        self.modelFilename = modelFilename
        self.remoteURL = URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFilename)"
        )!
    }

    /// Model filename without the `.bin` extension, e.g. `ggml-base.en`.
    private var modelStem: String {
        (modelFilename as NSString).deletingPathExtension
    }

    var loadState: ModelLoadState { state }

    func prepare() async throws {
        if whisper != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task<Void, Error> { try await self.load() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func load() async throws {
        do {
            let url = try await ModelDownloader.shared.fileURL(
                filename: modelFilename,
                remoteURL: remoteURL
            ) { [weak self] progress in
                // Reserve the last 15% for the CoreML encoder download.
                Task { await self?.setState(.downloading(progress: progress * 0.85)) }
            }

            // whisper.cpp (built with CoreML) looks for a `-encoder.mlmodelc`
            // bundle next to the .bin. Fetch + unzip it so it uses the Neural
            // Engine instead of falling back to CPU.
            let encoderDir = "\(modelStem)-encoder.mlmodelc"
            _ = try await ModelDownloader.shared.directoryURL(
                directoryName: encoderDir,
                zipRemoteURL: URL(
                    string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(encoderDir).zip"
                )!
            ) { [weak self] progress in
                Task { await self?.setState(.downloading(progress: 0.85 + progress * 0.15)) }
            }

            state = .loading

            // SwiftWhisper defaults to `.auto` language detection, which costs a
            // detection pass and can mis-fire on short questions — this is an
            // English-only model, so say so. `no_context` keeps each question
            // independent (the previous question is not a prompt for this one,
            // and carrying it over invents words that were never said).
            let params = WhisperParams(strategy: .greedy)
            params.language = .english
            params.translate = false
            params.no_context = true
            params.suppress_blank = true
            params.print_progress = false
            params.print_realtime = false
            params.print_special = false
            params.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))

            let whisper = Whisper(fromFileURL: url, withParams: params)
            self.whisper = whisper

            // First transcription pays for loading the CoreML encoder onto the
            // Neural Engine (seconds). Do it now on a scrap of silence so the
            // user's first real question isn't the one that waits.
            _ = try? await Self.runTranscription(WhisperBox(whisper), [Float](repeating: 0, count: 16_000))

            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func transcribe(audioAt url: URL) async throws -> String {
        if whisper == nil { try await prepare() }
        guard let whisper else { throw AIError.modelNotReady }

        let frames = try Self.read16kMonoFloats(from: url)
        // `Whisper` isn't Sendable and `transcribe` is async, so run it through a
        // nonisolated helper via an unchecked box rather than sending actor state.
        let segments = try await Self.runTranscription(WhisperBox(whisper), frames)
        let text = segments
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw AIError.transcriptionFailed }
        return text
    }

    private func setState(_ newState: ModelLoadState) { state = newState }

    /// Both pieces must be present: the weights *and* the CoreML encoder bundle.
    /// Reporting "downloaded" with only the .bin made the app skip setup and then
    /// re-download the encoder at the worst possible moment (first question).
    func isDownloaded() async -> Bool {
        let hasWeights = await ModelDownloader.shared.exists(modelFilename)
        let hasEncoder = await ModelDownloader.shared.exists("\(modelStem)-encoder.mlmodelc")
        return hasWeights && hasEncoder
    }

    func deleteDownload() async {
        loadTask?.cancel()
        loadTask = nil
        whisper = nil
        state = .notLoaded
        await ModelDownloader.shared.delete(modelFilename)
        await ModelDownloader.shared.delete("\(modelStem)-encoder.mlmodelc")
    }

    /// whisper.cpp does its own internal threading and serializes work, so
    /// running transcription off the actor is safe.
    private nonisolated static func runTranscription(
        _ box: WhisperBox,
        _ frames: [Float]
    ) async throws -> [Segment] {
        try await box.whisper.transcribe(audioFrames: frames)
    }

    // MARK: - Audio conversion

    /// whisper.cpp wants 16 kHz mono Float32. We record at 16 kHz already, so
    /// this just reads the file's Float channel data (channel 0).
    static func read16kMonoFloats(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw AIError.transcriptionFailed }
        try file.read(into: buffer)

        // Resample/convert to 16 kHz mono Float if needed.
        if file.processingFormat.sampleRate == 16_000,
           file.processingFormat.channelCount == 1,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let out = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
              ) else { throw AIError.transcriptionFailed }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let channel = out.floatChannelData else { throw AIError.transcriptionFailed }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
