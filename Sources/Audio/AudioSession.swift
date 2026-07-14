import AVFoundation
import Foundation

/// The app's one AVAudioSession setup.
///
/// Recording and playback used to configure the session independently — the
/// recorder re-set the category and re-activated it on every push-to-talk. That
/// is a slow, blocking call that can fail while the player node is running, and
/// a failure meant the recording silently never started. Configure it once, keep
/// it active, and both sides just use it.
enum AudioSession {
    /// Guards `isConfigured` — `activate()` is called from the recorder actor,
    /// the player actor and the main actor, so it needs a lock, not isolation.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var isConfigured = false

        /// True exactly once: for the caller that wins the race to configure.
        func claim() -> Bool {
            lock.withLock {
                if isConfigured { return false }
                isConfigured = true
                return true
            }
        }

        func release() {
            lock.withLock { isConfigured = false }
        }
    }

    private static let state = State()

    /// Idempotent. Safe to call from anywhere; only the first call does work.
    static func activate() {
        guard state.claim() else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` up front so switching between listening and
            // speaking never needs a category change (each one costs ~100 ms and
            // interrupts audio that's already playing).
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            // Let the next caller try again rather than leaving the app with a
            // session that was never configured.
            state.release()
            print("[LocalVision] Audio session setup failed: \(error)")
        }
    }
}
