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

    /// Downloads currently running, keyed by the name they write. Two callers
    /// asking for the same file (the setup page and the pipeline's warm-up both
    /// call `prepare()`) share one download instead of appending to the same
    /// partial file from two streams and corrupting it.
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Where all downloaded model files live, grouped under `Models/`.
    private var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    /// Local URL a remote file maps to (does not check existence).
    func localURL(for filename: String) -> URL {
        modelsDirectory.appendingPathComponent(filename)
    }

    /// True if the file is on this device *and* isn't empty. A zero-byte file is
    /// a failed download wearing the costume of a finished one.
    func exists(_ filename: String) -> Bool {
        let url = localURL(for: filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return false }
        if isDirectory.boolValue { return true }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0
    }

    /// Delete a downloaded file or directory under Models/, plus any partial
    /// download of it (no-op if absent).
    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: localURL(for: name))
        try? FileManager.default.removeItem(at: localURL(for: "\(name).partial"))
    }

    /// Returns the local URL for `filename`, downloading it from `remoteURL`
    /// only if it isn't already present. `onProgress` reports 0...1 while
    /// downloading. Safe to call every launch — it's a no-op once cached.
    func fileURL(
        filename: String,
        remoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if exists(filename) { return localURL(for: filename) }
        return try await coalesced(filename) {
            try await self.downloadFile(filename: filename, remoteURL: remoteURL, onProgress: onProgress)
        }
    }

    private func downloadFile(
        filename: String,
        remoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = localURL(for: filename)
        // A zero-byte leftover would otherwise shadow the real download forever.
        try? FileManager.default.removeItem(at: destination)

        try prepareModelsDirectory()

        let downloaded = try await downloadWithRetries(
            from: remoteURL,
            named: filename,
            onProgress: onProgress
        )

        // Move into place atomically so a killed download never leaves a
        // half-written file that later looks "present".
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    /// Runs `work` unless a download of `name` is already running, in which case
    /// both callers await that one.
    private func coalesced(
        _ name: String,
        _ work: @escaping @Sendable () async throws -> URL
    ) async throws -> URL {
        if let running = inFlight[name] {
            return try await running.value
        }
        let task = Task { try await work() }
        inFlight[name] = task
        defer { inFlight[name] = nil }
        return try await task.value
    }

    /// Creates `Models/` and keeps it out of iCloud backups — the weights are
    /// re-downloadable, and backing up ~1.5 GB of them is what gets apps rejected.
    private func prepareModelsDirectory() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        ModelStorage.excludeFromBackup(modelsDirectory)
    }

    /// Ensures an extracted directory (e.g. a `.mlmodelc` bundle) exists,
    /// downloading and unzipping `zipRemoteURL` into the Models folder if not.
    /// `directoryName` must match the folder the archive expands to.
    func directoryURL(
        directoryName: String,
        zipRemoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if exists(directoryName) {
            return modelsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        }
        return try await coalesced(directoryName) {
            try await self.downloadDirectory(
                directoryName: directoryName,
                zipRemoteURL: zipRemoteURL,
                onProgress: onProgress
            )
        }
    }

    private func downloadDirectory(
        directoryName: String,
        zipRemoteURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = modelsDirectory.appendingPathComponent(directoryName, isDirectory: true)

        try prepareModelsDirectory()

        let downloaded = try await downloadWithRetries(
            from: zipRemoteURL,
            named: directoryName,
            onProgress: onProgress
        )

        // Give the temp file a .zip extension so ZIPFoundation is happy.
        let zipURL = downloaded.appendingPathExtension("zip")
        try? FileManager.default.removeItem(at: zipURL)
        try FileManager.default.moveItem(at: downloaded, to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        // Unzip beside the target and move into place only once it's whole, so a
        // crash mid-extraction can't leave a partial bundle that looks installed.
        let staging = modelsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.unzipItem(at: zipURL, to: staging)
        let extracted = staging.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw ModelDownloadError.extractionFailed(directoryName)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
        return destination
    }

    // MARK: - URLSession download with progress, resume and retries

    /// Long timeouts and `waitsForConnectivity` — these are hundreds of MB over
    /// a phone connection, and the default 60 s resource timeout kills them.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration)
    }()

    /// Downloads to a `.partial` file that survives between attempts, so a
    /// dropped connection resumes where it left off rather than starting a
    /// multi-hundred-MB download over. Returns the completed partial file's URL.
    private func downloadWithRetries(
        from url: URL,
        named name: String,
        onProgress: (@Sendable (Double) -> Void)?,
        attempts: Int = 4
    ) async throws -> URL {
        let partial = modelsDirectory.appendingPathComponent("\(name).partial")
        var lastError: Error?

        for attempt in 0 ..< attempts {
            do {
                try await download(from: url, to: partial, named: name, onProgress: onProgress)
                return partial
            } catch let ModelDownloadError.badStatus(code, file) {
                // A bad status (404, 403…) won't fix itself by retrying.
                try? FileManager.default.removeItem(at: partial)
                throw ModelDownloadError.badStatus(code, file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }
                try await Task.sleep(for: .seconds(2 << attempt))
            }
        }
        throw lastError ?? ModelDownloadError.incomplete(name)
    }

    private func download(
        from url: URL,
        to partial: URL,
        named name: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        let manager = FileManager.default
        var received = Int64(
            (try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )

        var request = URLRequest(url: url)
        if received > 0 {
            request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelDownloadError.incomplete(name)
        }

        switch http.statusCode {
        case 206:
            break // server honoured the range: append to what we have
        case 200:
            // No resume support (or a fresh start) — begin from zero.
            try? manager.removeItem(at: partial)
            received = 0
        case 416:
            // "Range not satisfiable": our partial is already the whole file, or
            // it's longer than the remote. Start over to be sure it's valid.
            try? manager.removeItem(at: partial)
            received = 0
            throw ModelDownloadError.incomplete(name)
        default:
            throw ModelDownloadError.badStatus(http.statusCode, name)
        }

        // `expectedContentLength` is the length of *this* response, so with a
        // range request it covers only the remaining bytes.
        let total = response.expectedContentLength > 0
            ? received + response.expectedContentLength
            : -1

        if !manager.fileExists(atPath: partial.path) {
            manager.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { onProgress?(Double(received) / Double(total)) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        // Verify we actually got everything. Without this a connection that dies
        // cleanly mid-stream yields a truncated file that we'd happily install and
        // then fail to load — the "model is there but broken" case.
        if total > 0, received != total {
            throw ModelDownloadError.incomplete(name)
        }
        guard received > 0 else { throw ModelDownloadError.incomplete(name) }
        onProgress?(1.0)
    }
}

enum ModelDownloadError: LocalizedError {
    case badStatus(Int, String)
    case extractionFailed(String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let file):
            "Failed to download \(file) (HTTP \(code))."
        case .extractionFailed(let name):
            "Failed to unzip \(name)."
        case .incomplete(let name):
            "The download of \(name) was incomplete."
        }
    }
}
