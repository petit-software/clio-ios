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
        // Under the title, not in the bottom bar where iOS 26 would put it:
        // the bottom belongs to the record button alone.
        .searchable(text: $query, placement: .searchPlacement, prompt: "Search transcripts")
        .recordBar { RecordButton(action: onRecord) }
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

/// The one control that matters. The full width of the bottom bar, red,
/// and a word rather than a symbol: a toolbar item on iOS 26 collapses a
/// labelled button to its glyph, and a lone microphone is a guess, so
/// this is not a toolbar item — see `recordBar`.
struct RecordButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Record")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .prominentStyle()
        .buttonBorderShape(.capsule)
        .tint(.red)
        .controlSize(.large)
        .accessibilityHint("Starts a new recording")
    }
}

private extension View {
    /// Liquid Glass on iOS 26, the plain filled capsule before it.
    @ViewBuilder
    func prominentStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// The bar the record button sits in: the bottom of the screen, above
    /// the home indicator, with the list scrolling under it. `safeAreaBar`
    /// is what iOS 26 uses for its own bottom bars — the content gets the
    /// scroll-edge treatment — and `safeAreaInset` is the same idea on 18.
    @ViewBuilder
    func recordBar<Bar: View>(@ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        let content = bar()
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom) { content }
        } else {
            safeAreaInset(edge: .bottom) { content }
        }
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

private extension SearchFieldPlacement {
    static var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}
