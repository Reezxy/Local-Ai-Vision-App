import AVFoundation
import Foundation

/// Records microphone input to a temporary file for Whisper to transcribe.
/// 16 kHz mono PCM is exactly what Whisper wants, so we record it natively.
///
/// The recorder is armed *before* the user presses the button (`prewarm`), so
/// push-to-talk starts capturing immediately instead of paying for file setup
/// and hardware start-up after the finger is already down — that lag used to eat
/// the first word of the question.
actor AudioRecorder {
    /// Recordings shorter than this are a stray tap, not a question.
    private static let minimumDuration: TimeInterval = 0.3

    private var recorder: AVAudioRecorder?
    private var armed: AVAudioRecorder?
    private var currentURL: URL?

    func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Build and arm a recorder so the next `startRecording()` is instant.
    /// Cheap to call repeatedly; a no-op while one is already armed.
    func prewarm() {
        guard armed == nil, recorder == nil else { return }
        // Before the user has granted access there is nothing to arm, and asking
        // the session for the mic here would be the app's first (silent) attempt
        // to record — let the permission prompt happen on the first real press.
        guard AVAudioApplication.shared.recordPermission == .granted else { return }

        AudioSession.activate()
        armed = try? makeRecorder()
        armed?.prepareToRecord()
    }

    @discardableResult
    func startRecording() throws -> URL {
        AudioSession.activate()

        let recorder: AVAudioRecorder
        if let armed, armed.record() {
            recorder = armed
        } else {
            // Either nothing was armed, or the armed one refused to start (it can
            // go stale across an audio interruption). Build a fresh one rather
            // than report a failure the user would experience as a dead mic.
            let fresh = try makeRecorder()
            guard fresh.record() else { throw AudioRecorderError.couldNotStart }
            recorder = fresh
        }
        armed = nil

        self.recorder = recorder
        currentURL = recorder.url
        return recorder.url
    }

    /// Stops recording and returns the finished file, or nil if nothing usable
    /// was captured (no recording running, or just a stray tap).
    func stopRecording() -> URL? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        // `stop()` closes and finalises the file synchronously, so the WAV is
        // complete and readable by the time this returns.
        recorder.stop()
        self.recorder = nil

        let url = currentURL
        currentURL = nil

        guard duration >= Self.minimumDuration else {
            if let url { try? FileManager.default.removeItem(at: url) }
            prewarm() // ready for the next attempt right away
            return nil
        }

        prewarm()
        return url
    }

    func discardRecording() {
        recorder?.stop()
        recorder = nil
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        currentURL = nil
    }

    /// Current input loudness, 0...1, or nil when nothing is being recorded.
    /// Drives the on-screen listening animation — which doubles as proof that the
    /// mic is actually live, instead of the UI just claiming it is.
    func currentLevel() -> Double? {
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        // averagePower is in dBFS: -160 (silence) ... 0 (max). Speech mostly
        // lives in the top ~50 dB, so map that range onto 0...1.
        let decibels = Double(recorder.averagePower(forChannel: 0))
        let normalized = (decibels + 50) / 50
        return min(max(normalized, 0), 1)
    }

    private func makeRecorder() throws -> AVAudioRecorder {
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
        recorder.isMeteringEnabled = true
        return recorder
    }
}

enum AudioRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Could not start recording."
        }
    }
}
