import SwiftUI

@main
struct LocalVisionApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
