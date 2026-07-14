import Foundation
import Observation

/// Drives the first-run model setup: kicks off each model's download/load and
/// mirrors its `loadState` into observable UI state. Once every model is
/// `.ready`, `allReady` flips true and the app can enter the camera.
@MainActor
@Observable
final class ModelSetupCoordinator {

    struct Item: Identifiable {
        let id: UUID
        let name: String
        let role: String
        let source: String
        let approxSize: String
        var state: ModelLoadState
    }

    private(set) var items: [Item]
    private let models: [ModelDescriptor]
    private var started = false

    /// Persisted so we skip the setup page on later launches. It's only a hint:
    /// the disk is the truth (see `allModelsPresent`). Files can go missing
    /// between launches — a user deletes a model, or a download that once looked
    /// finished turns out to be incomplete — and trusting this flag alone is how
    /// the app ended up in the camera with a model it couldn't load.
    private static let completedKey = "modelsSetupCompleted"
    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// Whether every model's files are really on disk, complete, right now.
    static func allModelsPresent(_ models: [ModelDescriptor]) async -> Bool {
        for model in models {
            if await model.service.isDownloaded() == false { return false }
        }
        return true
    }

    init(models: [ModelDescriptor]) {
        self.models = models
        self.items = models.map {
            Item(id: $0.id, name: $0.name, role: $0.role,
                 source: $0.source, approxSize: $0.approxSize, state: .notLoaded)
        }
    }

    var allReady: Bool { items.allSatisfy { $0.state.isReady } }

    var hasFailure: Bool {
        items.contains { if case .failed = $0.state { return true } else { return false } }
    }

    /// Start (or restart failed) downloads. Idempotent while running.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        for index in models.indices {
            downloadModel(at: index)
        }
    }

    /// Retry only the models that failed.
    func retryFailed() {
        for index in items.indices {
            if case .failed = items[index].state {
                downloadModel(at: index)
            }
        }
    }

    private func downloadModel(at index: Int) {
        let service = models[index].service
        items[index].state = .downloading(progress: 0)

        Task {
            // Retry on top of the retries the services already do themselves, so
            // the user rarely has to tap "Retry" (flaky networks drop big
            // downloads often).
            for attempt in 0 ..< 2 {
                // Mirror the service's progress while `prepare()` runs. The
                // outcome comes from `prepare()` itself, never from this poll —
                // reading `loadState` can otherwise pick up the *previous*
                // attempt's `.failed` before the new one has started and report
                // a failure that isn't happening.
                let poll = Task {
                    while !Task.isCancelled {
                        let state = await service.loadState
                        if case .failed = state {} else { apply(state, at: index) }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                do {
                    try await service.prepare()
                    poll.cancel()
                    items[index].state = .ready
                    break
                } catch {
                    poll.cancel()
                    if attempt == 1 {
                        items[index].state = .failed(error.localizedDescription)
                    } else {
                        items[index].state = .downloading(progress: 0)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
            Self.hasCompletedSetup = allReady
        }
    }

    /// Applies a new state but keeps the download bar monotonic — the Hub
    /// reports per-file progress that can dip, and a bar that jumps backwards
    /// looks broken.
    private func apply(_ new: ModelLoadState, at index: Int) {
        if case .downloading(let next) = new,
           case .downloading(let current) = items[index].state,
           next < current {
            return
        }
        items[index].state = new
    }
}
