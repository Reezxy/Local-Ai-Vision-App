import AVFoundation
import CoreImage
import Foundation
import Observation

/// Owns the AVCaptureSession that drives the full-screen live preview and,
/// crucially, hands out the *current* frame on demand. The vision model never
/// consumes the stream — it only gets a single frame captured the moment the
/// user asks a question.
@Observable
final class CameraManager: NSObject, @unchecked Sendable {

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.localvision.camera.session")
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "com.localvision.camera.samples")

    /// Latest frame, continuously updated on the sample queue.
    @ObservationIgnored private let frameLock = NSLock()
    @ObservationIgnored private var latestFrame: CIImage?

    private(set) var isRunning = false
    private(set) var authorized = false

    // MARK: Permissions

    func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await MainActor.run { self.authorized = true }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run { self.authorized = granted }
        default:
            await MainActor.run { self.authorized = false }
        }
    }

    // MARK: Lifecycle

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async { self.isRunning = true }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private var isConfigured = false
    private func configureIfNeeded() {
        guard !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
        isConfigured = true
    }

    // MARK: Frame capture

    /// The single frame handed to the vision model when the user asks something.
    func captureCurrentFrame() -> CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        frameLock.lock()
        latestFrame = image
        frameLock.unlock()
    }
}
