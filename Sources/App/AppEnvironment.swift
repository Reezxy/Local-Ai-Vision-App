import Foundation

/// Composition root — the one place that wires concrete services together.
/// Swap implementations here (e.g. system fallback -> Whisper/Kokoro) without
/// touching the pipeline or UI.
@MainActor
final class AppEnvironment {
    let camera: CameraManager
    let pipeline: VisionPipeline

    /// The models the setup page downloads/loads, in display order.
    let models: [ModelDescriptor]

    init() {
        let camera = CameraManager()
        let recorder = AudioRecorder()
        let player = AudioPlayer()

        // --- Model selection -------------------------------------------------
        //   Vision → SmolVLM2-500M (MLX), STT → Whisper (whisper.cpp),
        //   TTS → Kokoro-82M. Kokoro's engine is VENDORED into the app target
        //   (Vendor/Kokoro) instead of pulled as a package: a second MLX-consuming
        //   package makes Xcode duplicate-link MLXNN, which crashes inference.
        let vlm: any VisionLanguageService = QwenVisionService()
        let stt: any SpeechToTextService = WhisperSpeechToTextService()
        let tts: any TextToSpeechService = KokoroTextToSpeechService(player: player)
        // ---------------------------------------------------------------------

        self.camera = camera
        self.pipeline = VisionPipeline(
            camera: camera,
            stt: stt,
            tts: tts,
            vlm: vlm,
            recorder: recorder
        )

        self.models = [
            ModelDescriptor(
                name: "SmolVLM2 500M",
                role: "Vision · understands the camera frame",
                source: "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx",
                approxSize: "~1 GB",
                service: vlm
            ),
            ModelDescriptor(
                name: "Whisper (base.en)",
                role: "Speech-to-text · hears your question",
                source: "ggerganov/whisper.cpp",
                approxSize: "148 MB",
                service: stt
            ),
            ModelDescriptor(
                name: "Kokoro-82M",
                role: "Text-to-speech · reads the answer aloud",
                source: "prince-canuma/Kokoro-82M",
                approxSize: "~330 MB",
                service: tts
            ),
        ]
    }
}

/// One downloadable model shown on the setup page.
struct ModelDescriptor: Identifiable {
    let id = UUID()
    let name: String
    let role: String
    let source: String
    let approxSize: String
    let service: any PreparableModelService
}
