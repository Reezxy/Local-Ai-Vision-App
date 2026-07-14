import Foundation
import Hub

/// Where model weights live on the device, and how we decide a model is really
/// "downloaded".
///
/// This exists because MLX's `defaultHubApi` downloads into `Library/Caches`,
/// which iOS is free to purge whenever storage runs low — models would silently
/// vanish and the app would report them as missing. Everything here lives in
/// Application Support instead (never purged, excluded from iCloud backup since
/// the weights are re-downloadable).
enum ModelStorage {

    /// Base for Hugging Face repo downloads: `Application Support/huggingface`.
    /// Layout below it matches HubApi: `models/<repoId>/…`.
    static let hubDownloadBase: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(component: "huggingface")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
        return url
    }()

    /// The one HubApi the app uses. Never use `defaultHubApi` — it points at Caches.
    static let hub = HubApi(downloadBase: hubDownloadBase)

    /// Directory a Hub repo's files land in.
    static func repoDirectory(for repoId: String) -> URL {
        hub.localRepoLocation(Hub.Repo(id: repoId))
    }

    /// The old (purgeable) location MLX used by default, for one-time migration.
    private static func legacyCachesDirectory(for repoId: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appending(component: "models").appending(path: repoId)
    }

    /// Models a previous build downloaded into Caches are moved into the safe
    /// location instead of being re-downloaded. No-op once migrated (or if iOS
    /// already purged the old copy).
    static func migrateLegacyDownloadIfNeeded(repoId: String) {
        let destination = repoDirectory(for: repoId)
        guard !FileManager.default.fileExists(atPath: destination.path),
              let legacy = legacyCachesDirectory(for: repoId),
              FileManager.default.fileExists(atPath: legacy.path)
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: legacy, to: destination)
        } catch {
            // Migration is a best-effort optimisation: on failure we just
            // re-download into the new location.
            try? FileManager.default.removeItem(at: destination)
        }
    }

    /// Removes a repo from disk, old location included.
    static func deleteRepo(_ repoId: String) {
        try? FileManager.default.removeItem(at: repoDirectory(for: repoId))
        if let legacy = legacyCachesDirectory(for: repoId) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// True only if the repo is *usable*: a config, at least one non-empty
    /// weight file, and no download left mid-flight.
    ///
    /// A plain "does the folder exist?" check is what made the app claim a model
    /// was installed when an interrupted download had only created the folder —
    /// the UI said "Downloaded" and loading then failed with missing files.
    static func isRepoComplete(_ repoId: String) -> Bool {
        let directory = repoDirectory(for: repoId)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        guard let files = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return false }

        var hasConfig = false
        var hasWeights = false

        for case let url as URL in files {
            // HubApi writes `<file>.incomplete` while downloading — its presence
            // means the snapshot was interrupted.
            if url.pathExtension == "incomplete" { return false }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let isEmpty = (values?.fileSize ?? 0) == 0

            if url.lastPathComponent == "config.json", !isEmpty { hasConfig = true }
            if url.pathExtension == "safetensors", !isEmpty { hasWeights = true }
        }

        return hasConfig && hasWeights
    }

    /// Model weights are large and re-downloadable — keep them out of iCloud/iTunes
    /// backups (Apple rejects apps that back up regenerable multi-GB data).
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
