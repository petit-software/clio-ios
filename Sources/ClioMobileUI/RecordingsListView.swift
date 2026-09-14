import ClioMobileCore
import SwiftUI

/// The library, newest first, grouped by day. The record button sits in
/// the bottom bar so it is never more than one tap away.
struct RecordingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    var onRecord: () -> Void
    /// Opens Settings, for the banner when nothing is installed.
    var onSettings: () -> Void = {}

    var body: some View {
        Group {
            if model.library.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Tap record, speak, and the transcript is made on this phone. "
                         + "Nothing leaves it.")
                } actions: {
                    if model.models.installed.isEmpty {
                        Button("Download a Model", action: onSettings)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list
            }
        }
        .navigationTitle("Recordings")
        .searchable(text: $query, prompt: "Search transcripts")
        .toolbar {
            // The bottom bar, where iOS 26 also puts the search field, so
            // the two controls that matter share one row.
            ToolbarItem(placement: .recordButtonPlacement) {
                RecordButton(action: onRecord)
            }
        }
    }

    private var list: some View {
        List {
            if model.models.installed.isEmpty {
                noModelBanner
            }
            ForEach(sections, id: \.day) { section in
                Section(section.day) {
                    ForEach(section.recordings) { recording in
                        NavigationLink(value: recording.id) {
                            RecordingRow(recording: recording)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            model.library.delete(section.recordings[index])
                        }
                    }
                }
            }
        }
    }

    /// Recording works without a model — the audio is kept and can be
    /// transcribed later — but nobody should find that out from a failed
    /// row. Shown until something is installed.
    private var noModelBanner: some View {
        Section {
            Button(action: onSettings) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No transcription model")
                            .font(.headline)
                        Text("Recordings are saved but not transcribed until one is downloaded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
            }
            .tint(.primary)
        }
    }

    private var filtered: [Recording] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.library.recordings }
        return model.library.recordings.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(needle)
                || $0.transcript.localizedCaseInsensitiveContains(needle)
        }
    }

    private var sections: [(day: String, recordings: [Recording])] {
        var order: [String] = []
        var groups: [String: [Recording]] = [:]
        for recording in filtered {
            let day = Format.relativeDay(recording.createdAt)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(recording)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.displayTitle)
                .font(.headline)
                .lineLimit(1)
            Text(recording.snippet)
                .font(.subheadline)
                .foregroundStyle(recording.status == .transcribed ? .secondary : .tertiary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(recording.createdAt, style: .time)
                Text("·")
                Text(Format.duration(recording.duration))
                if case .failed = recording.status {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The one control that matters. Large, red, centred, and labelled so
/// nobody has to guess.
struct RecordButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Record", systemImage: "mic.fill")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(.red)
        .accessibilityHint("Starts a new recording")
    }
}

#Preview("List") {
    NavigationStack {
        RecordingsListView(onRecord: {})
    }
    .environment(AppModel.simulating())
}

#Preview("Empty") {
    NavigationStack {
        RecordingsListView(onRecord: {})
    }
    .environment(AppModel.simulating(recordings: []))
}

#Preview("No model") {
    NavigationStack {
        RecordingsListView(onRecord: {})
    }
    .environment(AppModel.simulating(
        models: PreviewData.models(installed: [], downloads: [:], failures: [:])))
}

private extension ToolbarItemPlacement {
    /// The bottom bar does not exist on macOS, where the package is also
    /// built for tests.
    static var recordButtonPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}
