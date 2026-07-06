import SwiftUI

/// Decides what the user sees on launch: the model-download page on first run
/// (or until setup completes), then the full-screen camera experience.
struct AppRootView: View {
    let environment: AppEnvironment

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
    }
}
