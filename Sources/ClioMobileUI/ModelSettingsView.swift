import ClioMobileCore
import SwiftUI

/// Settings ▸ Model, as its own page.
struct ModelSettingsPage: View {
    var body: some View {
        Form { ModelSection() }
            .navigationTitle("Model")
    }
}

/// The catalog, one row per model, each row in whatever state that model
/// is in — downloadable, downloading, installed, selected, failed.
/// Selecting is a tap on an installed row; the rest is a menu.
struct ModelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.models.catalog) { entry in
                ModelRow(entry: entry)
            }
            Toggle("Keep model in memory", isOn: Binding(
                get: { model.settings.settings.keepModelInMemory },
                set: { model.settings.settings.keepModelInMemory = $0 }))
        } header: {
            Text("Model")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        let base = "Downloaded once from Hugging Face, then run on this phone's Neural "
                 + "Engine. Nothing you record is ever uploaded."
        if model.models.installed.isEmpty {
            return "Download a model to transcribe. Whisper Small is the one to start "
                 + "with. " + base
        }
        let kept = model.settings.settings.keepModelInMemory
            ? "The model stays loaded between recordings, so transcription starts at once."
            : "The model is loaded for each transcription and released after, which "
              + "saves memory and costs a few seconds per recording."
        return base + " " + kept
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogModel
    @State private var confirmingDelete = false

    private var manager: ModelManager { model.models }
    private var installed: InstalledModel? { manager.installedModel(id: entry.id) }
    private var progress: DownloadProgress? { manager.downloads[entry.id] }
    private var failure: String? { manager.failures[entry.id] }
    private var isActive: Bool { model.capture.activeModel?.id == entry.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.body)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Selected")
                    }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress.fraction)
                        .padding(.top, 2)
                }
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if installed != nil { model.select(model: entry.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(installed != nil ? .isButton : [])
        .confirmationDialog("Delete \(entry.displayName)?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Model", role: .destructive) {
                if let installed { try? manager.delete(installed) }
            }
        } message: {
            Text("It can be downloaded again at any time. Recordings are not affected.")
        }
    }

    private var detail: String {
        if let progress {
            guard progress.totalBytes > 0 else { return "Starting…" }
            let percent = Int((progress.fraction * 100).rounded(.down))
            return "\(percent)% · \(Format.bytes(progress.receivedBytes)) of "
                 + Format.bytes(progress.totalBytes)
        }
        if let installed {
            return "\(Format.bytes(installed.sizeBytes)) · \(entry.languages.label)"
                 + (isActive ? "" : " · Tap to select")
        }
        var parts = ["\(Format.bytes(entry.approximateBytes))", entry.languages.label,
                     entry.tier.label]
        if let note = entry.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if progress != nil {
            Button("Cancel download", systemImage: "xmark.circle.fill") {
                manager.cancel(entry.id)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
        } else if installed != nil {
            Menu {
                if !isActive {
                    Button("Use This Model", systemImage: "checkmark") {
                        model.select(model: entry.id)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(model.capture.state.isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More")
        } else {
            Button(failure == nil ? "Download" : "Retry",
                   systemImage: "arrow.down.circle.fill") {
                manager.download(entry)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
        }
    }
}

#Preview("Model section") {
    NavigationStack {
        Form { ModelSection() }
    }
    .environment(AppModel.simulating())
}

#Preview("Nothing installed") {
    NavigationStack {
        Form { ModelSection() }
    }
    .environment(AppModel.simulating(models: PreviewData.models(installed: [], downloads: [:],
                                                                 failures: [:])))
}
