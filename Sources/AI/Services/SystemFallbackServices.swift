import AVFoundation
import Foundation
import Speech

/// System-provided STT/TTS used as the default so the pipeline runs end-to-end
/// on day one. Swap these for `WhisperSpeechToTextService` /
/// `KokoroTextToSpeechService` in `AppEnvironment` once those models are ready.

/// On-device transcription using Apple's Speech framework.
actor SystemSpeechToTextService: SpeechToTextService {
    private var state: ModelLoadState = .notLoaded

    var loadState: ModelLoadState { state }

    func prepare() async throws {
        let granted = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        state = granted ? .ready : .failed("Speech recognition not authorized")
        if !granted { throw AIError.transcriptionFailed }
    }

    func transcribe(audioAt url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw AIError.transcriptionFailed
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let error { cont.resume(throwing: error); return }
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

/// Speech synthesis using `AVSpeechSynthesizer`.
final class SystemTextToSpeechService: NSObject, TextToSpeechService, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    var loadState: ModelLoadState { .ready }

    override init() {
        super.init()
        synth.delegate = self
    }

    func prepare() async throws {}

    func speak(_ text: String) async throws {
        await stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.synth.speak(utterance)
        }
    }

    func stop() async {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        continuation?.resume()
        continuation = nil
    }
}

extension SystemTextToSpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }
}
