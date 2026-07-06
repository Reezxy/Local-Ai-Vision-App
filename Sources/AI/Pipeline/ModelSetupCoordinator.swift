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

    /// Persisted so we skip the setup page on later launches.
    private static let completedKey = "modelsSetupCompleted"
    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
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
            // Retry transient failures automatically so the user rarely has to
            // tap "Retry" (flaky networks drop the first big download often).
            for attempt in 0..<3 {
                let prepare = Task.detached { try? await service.prepare() }
                while true {
                    let state = await service.loadState
                    apply(state, at: index)
                    if state.isReady { break }
                    if case .failed = state { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                _ = await prepare.value
                let final = await service.loadState
                apply(final, at: index)
                if final.isReady { break }

                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(2))
                    items[index].state = .downloading(progress: 0)
                }
            }
            if allReady { Self.hasCompletedSetup = true }
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
