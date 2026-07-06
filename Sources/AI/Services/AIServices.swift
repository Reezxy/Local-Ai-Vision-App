import CoreImage
import Foundation

/// Progress of a model that must be downloaded/loaded before first use.
enum ModelLoadState: Sendable, Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Common shape of any model-backed service: it must download/load its weights
/// before use and report progress. The model-setup and management pages drive
/// all services through this protocol.
protocol PreparableModelService: Sendable {
    var loadState: ModelLoadState { get async }
    func prepare() async throws
    /// True if the model's files are already present on disk.
    func isDownloaded() async -> Bool
    /// Remove the model's files from disk and reset to `.notLoaded`.
    func deleteDownload() async
}

extension PreparableModelService {
    // System-backed services (Apple Speech/AVSpeech) have nothing to manage.
    func isDownloaded() async -> Bool { await loadState.isReady }
    func deleteDownload() async {}
}

// MARK: - Speech to text (Whisper)

/// Turns recorded speech into text. Backed by Whisper on-device.
protocol SpeechToTextService: PreparableModelService {
    /// Transcribe a finished audio recording at `url` into English text.
    func transcribe(audioAt url: URL) async throws -> String
}

// MARK: - Text to speech (Kokoro-82M)

/// Turns the assistant's answer into spoken audio. Backed by Kokoro-82M.
protocol TextToSpeechService: PreparableModelService {
    /// Synthesize `text` and play it back. Returns when playback finishes.
    func speak(_ text: String) async throws
    func stop() async

    /// Streaming: synthesize `text` and QUEUE it for gapless playback,
    /// returning as soon as the audio is queued — NOT when it finishes. This
    /// lets the caller synthesize the next chunk while this one plays.
    /// Returns false if the engine doesn't support streaming.
    func enqueueSpeech(_ text: String) async throws -> Bool
    /// Suspends until all queued speech has finished playing.
    func finishSpeaking() async
}

extension TextToSpeechService {
    func enqueueSpeech(_ text: String) async throws -> Bool { false }
    func finishSpeaking() async {}
}

extension TextToSpeechService {
    /// Synchronous synthesis hook for cooperative interleaving with the vision
    /// model: called on the GENERATION thread with each completed sentence, it
    /// synthesizes right there (briefly pausing generation — same GPU, same
    /// thread, so no contention) and queues the audio for gapless playback.
    /// nil when the engine doesn't support it or isn't loaded yet.
    var inlineSynthesizer: (@Sendable (String) -> Void)? { get async { nil } }
}

// MARK: - Vision language model (Qwen3-VL 2B)

/// Answers a question about a single captured frame. This is the core model:
/// it only ever sees ONE frame per user turn, never a stream, to keep the
/// context small and the app fast on-device.
protocol VisionLanguageService: PreparableModelService {
    /// Ask `question` about `frame`. `onToken` streams the answer as it is
    /// generated so the UI can show partial text. `onSentence`, if provided,
    /// is called SYNCHRONOUSLY on the generation thread with each completed
    /// sentence (and the final tail) — used to interleave TTS synthesis with
    /// generation so speech starts while the model is still writing.
    func answer(
        question: String,
        about frame: CIImage,
        onToken: @Sendable @escaping (String) -> Void,
        onSentence: (@Sendable (String) -> Void)?
    ) async throws -> String
}
