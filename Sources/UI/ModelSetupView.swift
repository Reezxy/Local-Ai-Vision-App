import SwiftUI

/// First-run page that downloads the on-device models over their links and
/// shows per-model progress. Advances to the camera once everything is ready.
struct ModelSetupView: View {
    let environment: AppEnvironment
    let onReady: () -> Void

    @State private var coordinator: ModelSetupCoordinator

    init(environment: AppEnvironment, onReady: @escaping () -> Void) {
        self.environment = environment
        self.onReady = onReady
        _coordinator = State(initialValue: ModelSetupCoordinator(models: environment.models))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.10), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                header

                VStack(spacing: 14) {
                    ForEach(coordinator.items) { item in
                        ModelRow(item: item)
                    }
                }

                Spacer()

                footer
            }
            .padding(24)
        }
        .task {
            coordinator.startIfNeeded()
        }
        .onChange(of: coordinator.allReady) { _, ready in
            if ready {
                // Brief beat so the user sees everything hit "Ready".
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    onReady()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white)
            Text("Setting up Local Vision")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Downloading the AI models to your device. This happens once — they run fully offline afterwards.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private var footer: some View {
        if coordinator.hasFailure {
            VStack(spacing: 12) {
                Text("Some downloads failed. Check your connection and try again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Retry failed") { coordinator.retryFailed() }
                    .buttonStyle(.borderedProminent)
            }
        } else if coordinator.allReady {
            Button(action: onReady) {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Label("Keep the app open while models download", systemImage: "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct ModelRow: View {
    let item: ModelSetupCoordinator.Item

    var body: some View {
        HStack(spacing: 14) {
            statusIcon
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Text(item.approxSize)
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Text(item.role)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))

                progress
            }
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusIcon: some View {
        Group {
            switch item.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .downloading, .loading:
                ProgressView().tint(.white)
            case .notLoaded:
                Image(systemName: "circle.dashed").foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(.title3)
    }

    @ViewBuilder
    private var progress: some View {
        switch item.state {
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .tint(.white)
                .padding(.top, 4)
        case .loading:
            Text("Loading into memory…")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                .padding(.top, 2)
        case .ready:
            Text("Ready")
                .font(.caption2).foregroundStyle(.green)
                .padding(.top, 2)
        case .failed(let message):
            Text(message)
                .font(.caption2).foregroundStyle(.orange)
                .padding(.top, 2)
        case .notLoaded:
            Text("Waiting…")
                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 2)
        }
    }
}
