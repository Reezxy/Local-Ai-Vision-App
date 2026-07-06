import SwiftUI

/// Settings page listing every on-device model: whether it's downloaded, its
/// size, and controls to download or delete it. Opened from the camera's
/// top-left settings button.
struct ModelManagementView: View {
    let models: [ModelDescriptor]

    @Environment(\.dismiss) private var dismiss
    @State private var downloaded: [UUID: Bool] = [:]
    @State private var busy: Set<UUID> = []

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

            HStack {
                if isDownloaded {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
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
                        Label("Download", systemImage: "arrow.down.circle")
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
        Task {
            try? await model.service.prepare()
            downloaded[model.id] = await model.service.isDownloaded()
            busy.remove(model.id)
        }
    }

    private func delete(_ model: ModelDescriptor) {
        busy.insert(model.id)
        Task {
            await model.service.deleteDownload()
            // Re-show the first-run setup flow so a required model is re-fetched.
            ModelSetupCoordinator.hasCompletedSetup = false
            downloaded[model.id] = await model.service.isDownloaded()
            busy.remove(model.id)
        }
    }
}
