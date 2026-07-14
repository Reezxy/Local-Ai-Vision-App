import SwiftUI

/// Decides what the user sees on launch: the model-download page on first run
/// (or whenever a model is missing from disk), then the full-screen camera.
struct AppRootView: View {
    let environment: AppEnvironment

    /// The persisted flag is only an optimistic first guess so a returning user
    /// doesn't get a flash of the setup page. The disk check below is what
    /// actually decides — if a model is gone or incomplete, we go back to setup
    /// and re-fetch it instead of dropping into a camera that can't answer.
    @State private var isReady = ModelSetupCoordinator.hasCompletedSetup

    var body: some View {
        Group {
            if isReady {
                RootView(environment: environment)
                    .transition(.opacity)
            } else {
                ModelSetupView(environment: environment) {
                    withAnimation(.easeInOut) { isReady = true }
                }
                .transition(.opacity)
            }
        }
        .task {
            let present = await ModelSetupCoordinator.allModelsPresent(environment.models)
            ModelSetupCoordinator.hasCompletedSetup = present
            if !present, isReady {
                withAnimation(.easeInOut) { isReady = false }
            }
        }
    }
}
