import AVFoundation
import Foundation

/// Plays raw PCM audio produced by Kokoro. Supports gapless streaming: buffers
/// enqueued back-to-back play seamlessly via AVAudioPlayerNode's queue, so the
/// next sentence can be synthesized while the current one is still playing.
actor AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isConfigured = false

    private var pendingBuffers = 0
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    private func configureIfNeeded(sampleRate: Double) throws {
        guard !isConfigured else { return }
        engine.attach(playerNode)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        isConfigured = true
    }

    private func makeBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData!.pointee.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Queue PCM for gapless playback and return immediately (does NOT wait for
    /// the audio to finish). Buffers play seamlessly in enqueue order.
    func enqueue(pcm samples: [Float], sampleRate: Double = 24_000) throws {
        guard !samples.isEmpty else { return }
        try configureIfNeeded(sampleRate: sampleRate)
        guard let buffer = makeBuffer(samples, sampleRate: sampleRate) else { return }

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { await self?.bufferFinished() }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Play mono Float32 PCM samples, returning when playback finishes.
    func play(pcm samples: [Float], sampleRate: Double = 24_000) async throws {
        try enqueue(pcm: samples, sampleRate: sampleRate)
        await waitUntilIdle()
    }

    /// Suspends until every queued buffer has finished playing.
    func waitUntilIdle() async {
        guard pendingBuffers > 0 else { return }
        await withCheckedContinuation { idleContinuations.append($0) }
    }

    private func bufferFinished() {
        pendingBuffers -= 1
        if pendingBuffers <= 0 {
            pendingBuffers = 0
            let waiters = idleContinuations
            idleContinuations = []
            waiters.forEach { $0.resume() }
        }
    }

    func stop() {
        if playerNode.isPlaying { playerNode.stop() }
        // Stopping fires the completion handlers of dropped buffers, which
        // resumes any idle waiters via bufferFinished().
    }
}
