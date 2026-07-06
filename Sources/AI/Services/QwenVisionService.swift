import CoreImage
import Foundation
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
        guard container == nil else { return }
        state = .loading
        // Keep GPU cache bounded so we play nice with camera + audio on mobile.
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)

        do {
            let config = ModelConfiguration(id: modelId)
            container = try await VLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                Task { await self?.setState(.downloading(progress: progress.fractionCompleted)) }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
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
                // Stream partial text roughly every few tokens.
                if tokens.count % 4 == 0 {
                    let partial = context.tokenizer.decode(tokens: tokens)
                    onToken(partial)

                    // Cooperative TTS interleaving: hand each COMPLETED
                    // sentence to the synthesizer right here, on this thread.
                    // Generation pauses for the fraction of a second the
                    // synthesis takes, then continues while the audio plays.
                    if let onSentence,
                       let chunk = Self.completedSentence(in: partial, after: spokenOffset) {
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

    /// The next completed sentence (ending in . ! ? followed by whitespace or
    /// end-of-text) in `text` after `offset`, or nil if none is finished yet.
    private static func completedSentence(in text: String, after offset: Int) -> String? {
        guard offset < text.count else { return nil }
        let pending = String(text.dropFirst(offset))
        var index = pending.startIndex
        while index < pending.endIndex {
            let character = pending[index]
            let next = pending.index(after: index)
            if character == "." || character == "!" || character == "?",
               next == pending.endIndex || pending[next].isWhitespace {
                return String(pending[..<next])
            }
            index = next
        }
        return nil
    }

    private func setState(_ newState: ModelLoadState) { state = newState }

    /// Where swift-transformers' HubApi stores this model:
    /// `Documents/huggingface/models/<repoId>`.
    private var hubModelDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "huggingface/models/\(modelId)")
    }

    func isDownloaded() async -> Bool {
        FileManager.default.fileExists(atPath: hubModelDirectory.path)
    }

    func deleteDownload() async {
        container = nil
        state = .notLoaded
        try? FileManager.default.removeItem(at: hubModelDirectory)
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
