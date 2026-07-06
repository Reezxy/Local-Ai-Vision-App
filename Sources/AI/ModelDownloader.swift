import Foundation
import ZIPFoundation

/// Downloads and caches model files on-device. This is the piece that makes a
/// fresh install work: every model checks "is it already on this device?" and
/// only downloads if it's missing. Files live in Application Support so iOS
/// won't purge them like it can with Caches.
///
/// MLX models (Qwen) manage their own Hugging Face cache, so they don't go
/// through here — this handles the plain-file models (Whisper .bin, Kokoro
/// .safetensors + voice).
actor ModelDownloader {
    static let shared = ModelDownloader()

    /// Where all downloaded model files live, grouped under `Models/`.
    private var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    /// Local URL a remote file maps to (does not check existence).
    func localURL(for filename: String) -> URL {
        modelsDirectory.appendingPathComponent(filename)
    }

    /// True if the file already exists on this device.
    func exists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: filename).path)
    }

    /// Delete a downloaded file or directory under Models/ (no-op if absent).
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: localURL(for: name))
    }

    /// Returns the local URL for `filename`, downloading it from `remoteURL`
    /// only if it isn't already present. `onProgress` reports 0...1 while
    /// downloading. Safe to call every launch — it's a no-op once cached.
    func fileURL(
        filename: String,
        remoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localURL(for: filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (tempURL, response) = try await download(from: remoteURL, onProgress: onProgress)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelDownloadError.badStatus(http.statusCode, filename)
        }

        // Move into place atomically so a killed download never leaves a
        // half-written file that later looks "present".
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// Ensures an extracted directory (e.g. a `.mlmodelc` bundle) exists,
    /// downloading and unzipping `zipRemoteURL` into the Models folder if not.
    /// `directoryName` must match the folder the archive expands to.
    func directoryURL(
        directoryName: String,
        zipRemoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = modelsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let (tempURL, response) = try await download(from: zipRemoteURL, onProgress: onProgress)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelDownloadError.badStatus(http.statusCode, directoryName)
        }

        // Give the temp file a .zip extension so ZIPFoundation is happy.
        let zipURL = tempURL.appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: zipURL)
        try FileManager.default.moveItem(at: tempURL, to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        try FileManager.default.unzipItem(at: zipURL, to: modelsDirectory)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ModelDownloadError.extractionFailed(directoryName)
        }
        return destination
    }

    // MARK: - URLSession download with progress

    private func download(
        from url: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expected = response.expectedContentLength

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { onProgress?(Double(received) / Double(expected)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        onProgress?(1.0)
        return (tempURL, response)
    }
}

enum ModelDownloadError: LocalizedError {
    case badStatus(Int, String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let file):
            "Failed to download \(file) (HTTP \(code))."
        case .extractionFailed(let name):
            "Failed to unzip \(name)."
        }
    }
}
