import AVFoundation
import Foundation

/// Records microphone input to a temporary file for Whisper to transcribe.
/// 16 kHz mono PCM is exactly what Whisper wants, so we record it natively.
actor AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func startRecording() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("question-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        self.recorder = recorder
        self.currentURL = url
        return url
    }

    /// Stops recording and returns the finished file.
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        let url = currentURL
        return url
    }
}
