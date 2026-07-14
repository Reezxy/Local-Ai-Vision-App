import CoreImage
import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXVLM

/// On-device vision-language model through MLXVLM. An `actor` so the model
/// container is only ever touched by one request at a time (MLX state is not
/// re-entrant).
///
/// Defaults to SmolVLM2-500M: a 2B model (Qwen3-VL) reliably jetsam-kills 4–6 GB
/// iPhones during inference, whereas SmolVLM2-500M is built for on-device use
/// and fits comfortably. Swap `modelId` for `mlx-community/Qwen3-VL-2B-Instruct-4bit`
/// on an 8 GB device for higher quality.
///
/// NOTE: mlx-swift-examples' generation API moves fast. The call in `answer`
/// targets the token-callback form of `MLXLMCommon.generate`; if you bump the
/// package, re-check this one call site against the current README.
actor QwenVisionService: VisionLanguageService {

    private let modelId: String
    private let maxTokens: Int
    private let systemPrompt: String

    private var container: ModelContainer?
    private var state: ModelLoadState = .notLoaded
    /// The in-flight load, if any. Concurrent callers (setup page, warm-up, the
    /// first question) await this one instead of each kicking off their own
    /// download — an actor's `guard container == nil` doesn't prevent that,
    /// because every caller passes the guard before the first `await` resumes.
    private var loadTask: Task<Void, Error>?

    init(
        modelId: String = "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx",
        maxTokens: Int = 120,
        systemPrompt: String = """
        Answer the question about the image in ONE short sentence with only the \
        key information. Maximum 20 words. No introductions, no extra details, \
        no scene descriptions. English only.
        """
    ) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }

    var loadState: ModelLoadState { state }

    func prepare() async throws {
        if container != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task<Void, Error> { try await load() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Fetches the weights (if needed) and loads them, retrying transient
    /// failures. Download and load are separate steps: downloading must not touch
    /// the GPU, and a download that "succeeded" is verified on disk before we try
    /// to load it.
    private func load() async throws {
        state = .downloading(progress: 0)
        ModelStorage.migrateLegacyDownloadIfNeeded(repoId: modelId)

        let attempts = 3
        var lastError: Error?
        var didResetCache = false

        for attempt in 0 ..< attempts {
            do {
                // Explicit hub: MLX's `defaultHubApi` downloads into Library/Caches,
                // which iOS purges under storage pressure — the model would keep
                // disappearing. `ModelStorage.hub` writes to Application Support.
                let config = ModelConfiguration(id: modelId)
                if !ModelStorage.isRepoComplete(modelId) {
                    _ = try await downloadModel(
                        hub: ModelStorage.hub,
                        configuration: config
                    ) { [weak self] progress in
                        Task { await self?.setState(.downloading(progress: progress.fractionCompleted)) }
                    }
                    // `downloadModel` treats "offline" as success and falls back to
                    // whatever is already on disk, so its return is not proof the
                    // weights are all here — check.
                    guard ModelStorage.isRepoComplete(modelId) else {
                        throw ModelDownloadError.incomplete(modelId)
                    }
                    ModelStorage.excludeFromBackup(ModelStorage.repoDirectory(for: modelId))
                }

                state = .loading
                // Keep GPU cache bounded so we play nice with camera + audio on mobile.
                MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
                container = try await VLMModelFactory.shared.loadContainer(
                    hub: ModelStorage.hub,
                    configuration: config
                )
                state = .ready
                return
            } catch is CancellationError {
                state = .notLoaded
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }

                if Self.isTransient(error) {
                    // Leave the partial download alone — HubApi resumes from its
                    // `.incomplete` files, so a dropped connection costs seconds
                    // rather than restarting a ~1 GB download from zero.
                    state = .downloading(progress: 0)
                    try? await Task.sleep(for: .seconds(2 << attempt))
                } else if !didResetCache {
                    // Not a network problem, so the files we have are the problem:
                    // a truncated or corrupt cache fails here every time until it's
                    // thrown away. Do that exactly once, then re-download clean.
                    didResetCache = true
                    ModelStorage.deleteRepo(modelId)
                    state = .downloading(progress: 0)
                } else {
                    break
                }
            }
        }

        let error = lastError ?? AIError.modelNotReady
        state = .failed(error.localizedDescription)
        throw error
    }

    /// Network blips and interrupted downloads are worth retrying; a 404 on the
    /// repo id is not.
    private static func isTransient(_ error: Error) -> Bool {
        // Files still missing after a download pass: more of them may arrive on
        // the next attempt, and what's on disk is worth resuming from — so retry
        // rather than throw the partial download away.
        if case ModelDownloadError.incomplete = error { return true }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorDataNotAllowed,
        ].contains(nsError.code)
    }

    func answer(
        question: String,
        about frame: CIImage,
        onToken: @Sendable @escaping (String) -> Void,
        onSentence: (@Sendable (String) -> Void)?
    ) async throws -> String {
        if container == nil { try await prepare() }
        guard let container else { throw AIError.modelNotReady }

        let maxTokens = self.maxTokens
        let systemPrompt = self.systemPrompt

        let result = try await container.perform { context in
            // Use the chat-based UserInput so the model's message generator
            // inserts exactly one image placeholder token per frame. Passing a
            // raw `.text` prompt skips that and triggers "Number of placeholder
            // tokens does not match number of frames".
            //
            // Fold the instructions into the user turn rather than a separate
            // `.system` message — SmolVLM (and some other VLMs) don't support a
            // system role, so this stays model-agnostic.
            // Downscale the camera frame before vision encoding — the encoder
            // is the latency hot spot, and 512px is plenty for scene questions.
            let userInput = UserInput(
                chat: [
                    .user("\(systemPrompt)\n\n\(question)", images: [.ciImage(frame)])
                ],
                processing: .init(resize: CGSize(width: 512, height: 512))
            )
            let input = try await context.processor.prepare(input: userInput)

            // Offset up to which the text has already been handed to
            // `onSentence`. Lives on the (single) generation thread.
            var spokenOffset = 0

            let generation = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.4, topP: 0.9),
                context: context
            ) { tokens in
                // Check every couple of tokens, not every fourth: the first
                // speakable chunk is only a few words long, and waiting for a
                // 4-token boundary to notice it delays the first audio.
                if tokens.count % 2 == 0 {
                    let partial = context.tokenizer.decode(tokens: tokens)
                    onToken(partial)

                    // Cooperative TTS interleaving: hand each speakable chunk to
                    // the synthesizer right here, on this thread. Generation
                    // pauses for the fraction of a second the synthesis takes,
                    // then continues while that audio is already playing.
                    if let onSentence,
                       let chunk = Self.speakableChunk(
                           in: partial,
                           after: spokenOffset,
                           isFirst: spokenOffset == 0
                       ) {
                        spokenOffset += chunk.count
                        onSentence(chunk)
                    }
                }
                return tokens.count >= maxTokens ? .stop : .more
            }

            // Deliver whatever remains after the last sentence boundary.
            if let onSentence {
                let tail = String(generation.output.dropFirst(spokenOffset))
                if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSentence(tail)
                }
            }
            return generation
        }
        return result.output
    }

    /// The next chunk of `text` after `offset` that is ready to be spoken, or nil
    /// if nothing is ready yet.
    ///
    /// Breaking only on sentence ends (. ! ?) meant a chunk was never ready
    /// before the very last token: the prompt asks for ONE short sentence, so the
    /// first and only sentence boundary is the end of the answer. Speech could
    /// never overlap generation and the voice always arrived late. So we also
    /// break at clause boundaries, and the first chunk breaks as early as it
    /// reasonably can — the sooner the first audio exists, the sooner the user
    /// hears anything, and every later chunk is synthesized while it plays.
    private static func speakableChunk(
        in text: String,
        after offset: Int,
        isFirst: Bool
    ) -> String? {
        guard offset < text.count else { return nil }
        let pending = String(text.dropFirst(offset))

        // The first chunk buys the lowest possible time-to-first-sound; later
        // chunks are longer, which sounds more natural and stays ahead of
        // playback anyway (chunk N+1 is synthesized while chunk N is heard).
        let minWordsForClause = isFirst ? 3 : 6
        // 5 words, not 4: at 4 a short answer ("It is a red apple.") gets split
        // one word before its end, and a lone trailing "apple." sounds broken.
        let minWords = isFirst ? 5 : 8
        let hardCap = isFirst ? 8 : 14

        var words = 0
        var index = pending.startIndex
        var previousWasSpace = true

        while index < pending.endIndex {
            let character = pending[index]
            let next = pending.index(after: index)
            let isSpace = character.isWhitespace

            if !isSpace, previousWasSpace { words += 1 }
            previousWasSpace = isSpace

            let atBoundary = next == pending.endIndex || pending[next].isWhitespace

            if atBoundary, words >= 1 {
                // A finished sentence is always worth speaking.
                if character == "." || character == "!" || character == "?" {
                    return String(pending[..<next])
                }
                // A clause boundary, once there's enough to sound like a phrase.
                if character == "," || character == ";" || character == ":" || character == "—",
                   words >= minWordsForClause {
                    return String(pending[..<next])
                }
            }

            // Most answers are a single comma-less clause, so punctuation alone
            // would never yield a chunk before the final token — that is exactly
            // why speech used to start only after generation had finished. So we
            // also break on plain word gaps, but never right after a word that
            // leans on the next one ("a", "the", "on"…): ending a chunk there is
            // what makes split speech sound chopped.
            if isSpace, words >= minWords,
               words >= hardCap || !Self.leansOnNextWord(currentWordBefore(index, in: pending)) {
                return String(pending[..<index])
            }
            index = next
        }
        return nil
    }

    /// The word that just ended at `spaceIndex`.
    private static func currentWordBefore(_ spaceIndex: String.Index, in text: String) -> String {
        var start = spaceIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        return String(text[start ..< spaceIndex])
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }

    /// Function words that a listener expects to be glued to what follows —
    /// breaking a chunk after one of them sounds like a stutter.
    private static let danglingWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "into", "onto", "and", "or", "but", "is", "are", "was", "were",
        "his", "her", "its", "their", "this", "that", "these", "those", "some",
        "no", "not", "as", "than", "over", "under", "near", "next",
    ]

    private static func leansOnNextWord(_ word: String) -> Bool {
        danglingWords.contains(word)
    }

    private func setState(_ newState: ModelLoadState) { state = newState }

    /// Downloaded *and* complete — a repo folder left behind by an interrupted
    /// download doesn't count, or the UI would offer to use a model that can't load.
    func isDownloaded() async -> Bool {
        ModelStorage.migrateLegacyDownloadIfNeeded(repoId: modelId)
        return ModelStorage.isRepoComplete(modelId)
    }

    func deleteDownload() async {
        loadTask?.cancel()
        loadTask = nil
        container = nil
        state = .notLoaded
        ModelStorage.deleteRepo(modelId)
    }
}

enum AIError: LocalizedError {
    case modelNotReady
    case transcriptionFailed
    case synthesisFailed
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "The model is not loaded yet."
        case .transcriptionFailed: "Could not transcribe the audio."
        case .synthesisFailed: "Could not synthesize speech."
        case .notImplemented(let what): "\(what) is not implemented yet."
        }
    }
}
