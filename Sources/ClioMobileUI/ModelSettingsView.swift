import ClioMobileCore
import SwiftUI

/// Settings ▸ Models, as its own page: the transcription models, then the
/// summarization models.
struct ModelSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ModelSection()
            SummaryModelSection()
            Section {
                Toggle("Keep models in memory", isOn: Binding(
                    get: { model.settings.settings.keepModelInMemory },
                    set: {
                        model.settings.settings.keepModelInMemory = $0
                        model.releaseModelsIfNotKept()
                    }))
            } footer: {
                Text(model.settings.settings.keepModelInMemory
                     ? "The transcription model and the summary model stay loaded "
                       + "between recordings, so both start at once."
                     : "Each model is loaded when needed and released after, which "
                       + "saves memory and costs a few seconds each time.")
            }
        }
        .navigationTitle("Models")
        .softScrollEdges()
    }
}

/// The Whisper catalog, one row per model, each row in whatever state that
/// model is in — downloadable, downloading, installed, selected, failed.
/// Selecting is a tap on an installed row; deleting is a long press.
struct ModelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.models.catalog) { entry in
                ModelRow(entry: entry, manager: model.models,
                         isActive: model.capture.activeModel?.id == entry.id,
                         busy: model.capture.state.isBusy) {
                    model.select(model: entry.id)
                }
            }
        } header: {
            Text("Transcription")
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
        return base
    }
}

/// Which model writes the summaries: Apple's, where the phone has it, or
/// one downloaded here. Each language model is a catalog row like the
/// Whisper ones above, with its size, the memory it needs, and whether this
/// phone can run it.
struct SummaryModelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let choice = model.settings.settings.summaryModel
        let device = model.summaries.deviceSupport
        Section {
            appleRow(selected: choice == .apple)
            ForEach(model.languageModels.catalog) { entry in
                ModelRow(entry: entry, manager: model.languageModels,
                         isActive: choice == .local(id: entry.id),
                         busy: model.intelligence.inProgress.isEmpty == false,
                         unsupported: model.summaries.support(for: entry).reason) {
                    model.select(summaryModel: .local(id: entry.id))
                }
            }
        } header: {
            Text("Summaries")
        } footer: {
            Text(device.isSupported
                 ? "Downloaded once from Hugging Face, then run on this phone's GPU. "
                   + "Both under Apache 2.0. Nothing you record is ever uploaded."
                 : (device.reason ?? "") + " Apple Intelligence is the only option here.")
        }
    }

    /// Apple's model as a row: a tap picks it when it is there, the reason
    /// when it is not.
    private func appleRow(selected: Bool) -> some View {
        let apple = model.summaries.appleAvailability
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Intelligence")
                Text(apple.isAvailable
                     ? "Built into iOS 26. Nothing to download."
                     : apple.reason ?? "Not available on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if apple.isAvailable {
                Image(systemName: selected ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: ModelRow.slot, height: ModelRow.slot)
                    .accessibilityLabel(selected ? "Selected" : "Available")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if apple.isAvailable { model.select(summaryModel: .apple) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(apple.isAvailable ? .isButton : [])
    }
}

/// One catalog row, for either kind of model: the Whisper models on the
/// Model page, the language models on the Intelligence page. The manager
/// says what state it is in; the caller says whether it is the one in use
/// and what a tap on an installed row does.
struct ModelRow: View {
    let entry: CatalogModel
    let manager: ModelManager
    var isActive: Bool
    /// Deleting is refused while a recording or transcription is running.
    var busy = false
    /// Why this phone cannot use the model, if it cannot. Shown on the
    /// row; the download is still offered, since the memory a model needs
    /// changes with what else is running.
    var unsupported: String? = nil
    var onSelect: () -> Void
    @State private var confirmingDelete = false

    private var installed: InstalledModel? { manager.installedModel(id: entry.id) }
    private var progress: DownloadProgress? { manager.downloads[entry.id] }
    private var failure: String? { manager.failures[entry.id] }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.body)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let unsupported {
                    Text(unsupported)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            // One slot at the far right, the same size in every state, so
            // the rows line up and keep their height as a download runs.
            trailing
                .frame(width: Self.slot, height: Self.slot)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if installed != nil { onSelect() }
        }
        .contextMenu {
            if installed != nil {
                Button("Delete Model", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(busy)
            }
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

    static let slot: CGFloat = 28

    /// What sits in the slot: a blue arrow to download, a small ring while
    /// it comes down (tap to cancel), a green check once it is here —
    /// filled for the one in use, outlined for the rest.
    @ViewBuilder
    private var trailing: some View {
        if let progress {
            Button {
                manager.cancel(entry.id)
            } label: {
                DownloadRing(fraction: progress.totalBytes > 0 ? progress.fraction : nil)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
            .accessibilityValue(detail)
        } else if installed != nil {
            Image(systemName: isActive ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityLabel(isActive ? "Selected" : "Installed")
        } else {
            Button(failure == nil ? "Download" : "Retry",
                   systemImage: "arrow.down.circle.fill") {
                manager.download(entry)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .foregroundStyle(.blue)
            .buttonStyle(.borderless)
        }
    }
}

/// A small circular progress ring, the size of the row's other icons: a
/// faint track with a blue arc over it, or a spinner before the size is
/// known.
private struct DownloadRing: View {
    /// Nil while the total is not yet known.
    let fraction: Double?

    var body: some View {
        if let fraction {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
            .frame(width: 20, height: 20)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
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
