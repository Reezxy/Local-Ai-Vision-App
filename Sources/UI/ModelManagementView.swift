import SwiftUI

/// Settings page listing every on-device model: whether it's downloaded, its
/// size, and controls to download or delete it. Opened from the camera's
/// top-left settings button.
struct ModelManagementView: View {
    let models: [ModelDescriptor]

    @Environment(\.dismiss) private var dismiss
    @State private var downloaded: [UUID: Bool] = [:]
    @State private var busy: Set<UUID> = []
    @State private var failures: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(models) { model in
                        row(model)
                    }
                } footer: {
                    Text("Everything runs fully on-device. Deleting a model frees storage; it re-downloads the next time it's needed.")
                }

                Section {
                    Text("made by Reezxy")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refreshAll() }
        }
    }

    @ViewBuilder
    private func row(_ model: ModelDescriptor) -> some View {
        let isDownloaded = downloaded[model.id] ?? false
        let isBusy = busy.contains(model.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline)
                    Text(model.role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.approxSize).font(.caption).foregroundStyle(.secondary)
            }

            Text(model.source)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)

            if let failure = failures[model.id] {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                if isDownloaded {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if isBusy {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Not downloaded", systemImage: "circle.dashed")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if isBusy {
                    ProgressView()
                } else if isDownloaded {
                    Button(role: .destructive) { delete(model) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button { download(model) } label: {
                        Label(
                            failures[model.id] == nil ? "Download" : "Retry",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func refreshAll() async {
        for model in models {
            downloaded[model.id] = await model.service.isDownloaded()
        }
    }

    private func download(_ model: ModelDescriptor) {
        busy.insert(model.id)
        failures[model.id] = nil
        Task {
            do {
                try await model.service.prepare()
            } catch {
                failures[model.id] = error.localizedDescription
            }
            downloaded[model.id] = await model.service.isDownloaded()
            busy.remove(model.id)
        }
    }

    private func delete(_ model: ModelDescriptor) {
        busy.insert(model.id)
        failures[model.id] = nil
        Task {
            await model.service.deleteDownload()
            // The model is re-fetched on demand (or by the setup page on the next
            // launch, which checks the disk rather than a "setup done" flag).
            ModelSetupCoordinator.hasCompletedSetup = false
            downloaded[model.id] = await model.service.isDownloaded()
            busy.remove(model.id)
        }
    }
}
