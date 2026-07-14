import Foundation
import MLX

/// Kokoro-82M text-to-speech via KokoroSwift (MLX). The model weights and the
/// chosen voice are downloaded on first use and reused after that. Output is
/// 24 kHz mono Float PCM, played through `AudioPlayer`.
///
/// All synthesis funnels through `SynthCore` — a lock-guarded synchronous core
/// that can also be invoked directly on the vision model's generation thread
/// (see `inlineSynthesizer`), which is how speech starts while the answer is
/// still being generated.
actor KokoroTextToSpeechService: TextToSpeechService {

    /// Kokoro model + voice, both from the MLX-format Kokoro repo.
    private static let repoBase = "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main"
    private let modelFilename = "kokoro-v1_0.safetensors"
    private let voiceName: String

    private let player: AudioPlayer
    private var core: SynthCore?
    private var state: ModelLoadState = .notLoaded
    /// Shared by concurrent `prepare()` callers so the model is only loaded once.
    private var loadTask: Task<Void, Error>?

    /// `af_heart` is Kokoro's default English voice. See the repo's VOICES.md
    /// for the full list (af_*, am_*, bf_*, bm_* …).
    init(player: AudioPlayer, voiceName: String = "af_heart") {
        self.player = player
        self.voiceName = voiceName
    }

    var loadState: ModelLoadState { state }

    func prepare() async throws {
        if core != nil { return }
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
            let voiceFile = "\(voiceName).safetensors"

            let modelURL = try await ModelDownloader.shared.fileURL(
                filename: modelFilename,
                remoteURL: URL(string: "\(Self.repoBase)/\(modelFilename)")!
            ) { [weak self] progress in
                Task { await self?.setState(.downloading(progress: progress * 0.9)) }
            }
            let voiceURL = try await ModelDownloader.shared.fileURL(
                filename: voiceFile,
                remoteURL: URL(string: "\(Self.repoBase)/voices/\(voiceFile)")!
            )

            state = .loading
            // A voice file holds a single style tensor; take it.
            guard let voiceArray = try MLX.loadArrays(url: voiceURL).values.first else {
                throw AIError.synthesisFailed
            }
            let core = SynthCore(
                tts: KokoroTTS(modelPath: modelURL, g2p: .misaki),
                voice: voiceArray,
                player: player
            )

            // Kokoro's first synthesis is far slower than the rest — it compiles
            // the MLX graph and warms the G2P tables. Pay that here, during
            // warm-up, instead of in the middle of the first answer where it
            // shows up as a long silence before the voice starts. The audio is
            // discarded, and the audio engine is started for the same reason.
            core.warmUp()
            await player.prewarm(sampleRate: Double(KokoroTTS.Constants.samplingRate))

            self.core = core
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Synchronous synthesize-and-queue hook for cooperative interleaving with
    /// the vision model (called on the generation thread). nil until prepared.
    var inlineSynthesizer: (@Sendable (String) -> Void)? {
        guard let core else { return nil }
        return { text in core.synthesizeAndEnqueue(text) }
    }

    func speak(_ text: String) async throws {
        guard try await enqueueSpeech(text) else { throw AIError.synthesisFailed }
        await player.waitUntilIdle()
    }

    /// Synthesize and queue for gapless playback; returns right after synthesis
    /// so the next chunk can be generated while this one plays.
    /// GPU synthesis only — the CPU device fatal-errors on iOS
    /// ("[Compiled::eval_cpu] CPU compilation not supported on the platform").
    func enqueueSpeech(_ text: String) async throws -> Bool {
        if core == nil { try await prepare() }
        guard let core else { throw AIError.modelNotReady }
        core.synthesizeAndEnqueue(text)
        return true
    }

    func finishSpeaking() async {
        // Wait for any in-flight synthesis to enqueue, then for playback.
        await core?.waitForPendingEnqueues()
        await player.waitUntilIdle()
    }

    func stop() async {
        await player.stop()
    }

    private func setState(_ newState: ModelLoadState) { state = newState }

    /// The voice file is as required as the weights — without it synthesis fails,
    /// so a model-without-voice must not count as downloaded.
    func isDownloaded() async -> Bool {
        let hasWeights = await ModelDownloader.shared.exists(modelFilename)
        let hasVoice = await ModelDownloader.shared.exists("\(voiceName).safetensors")
        return hasWeights && hasVoice
    }

    func deleteDownload() async {
        loadTask?.cancel()
        loadTask = nil
        core = nil
        state = .notLoaded
        await ModelDownloader.shared.delete(modelFilename)
        await ModelDownloader.shared.delete("\(voiceName).safetensors")
    }
}

/// Lock-guarded synchronous synthesis core. Safe to call from any thread —
/// including the vision model's generation thread, where running Kokoro
/// inline (same thread, same GPU) briefly pauses generation instead of
/// deadlocking against it.
private final class SynthCore: @unchecked Sendable {
    private let tts: KokoroTTS
    private let voice: MLXArray
    private let player: AudioPlayer

    private let lock = NSLock()
    /// Serial chain that keeps playback enqueues in synthesis order.
    private var enqueueChain: Task<Void, Never>?

    init(tts: KokoroTTS, voice: MLXArray, player: AudioPlayer) {
        self.tts = tts
        self.voice = voice
        self.player = player
    }

    /// Run one throwaway synthesis so the expensive first-call work (graph
    /// compilation, G2P warm-up) is done before the user asks anything.
    func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? tts.generateAudio(voice: voice, language: .enUS, text: "Ready.")
    }

    /// Synthesize `text` on the CALLING thread and queue the audio for gapless
    /// playback. Returns when synthesis is done (playback continues async).
    func synthesizeAndEnqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let (samples, _) = try? tts.generateAudio(voice: voice, language: .enUS, text: trimmed),
              !samples.isEmpty
        else { return }

        let player = self.player
        let previous = enqueueChain
        enqueueChain = Task {
            await previous?.value
            try? await player.enqueue(pcm: samples, sampleRate: Double(KokoroTTS.Constants.samplingRate))
        }
    }

    func waitForPendingEnqueues() async {
        let chain = lock.withLock { enqueueChain }
        await chain?.value
    }
}
