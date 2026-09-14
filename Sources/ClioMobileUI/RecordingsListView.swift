import ClioMobileCore
import SwiftUI

/// The library, newest first, grouped by day. The record button sits
/// under it so it is never more than one tap away: a red pane of its own
/// upright, a capsule when the phone is sideways and height is short.
struct RecordingsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var query = ""
    var onRecord: () -> Void
    /// Opens Settings, for the banner when nothing is installed.
    var onSettings: () -> Void = {}

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscape
            } else {
                portrait
            }
        }
        .navigationTitle("Recordings")
        // Under the title, not in the bottom bar where iOS 26 would put it:
        // the bottom belongs to the record button alone.
        .searchable(text: $query, placement: .searchPlacement, prompt: "Search transcripts")
    }

    static let seamRadius: CGFloat = 20
    static let seamGap: CGFloat = 8

    /// Two panes, stacked: the list, and the record button in a strip of
    /// its own beneath it, with rounded corners where they meet over the
    /// window background, so the seam reads as two surfaces and not a line.
    private var portrait: some View {
        VStack(spacing: Self.seamGap) {
            content
                // The list is not clipped or masked: on iOS 26 the large
                // title scrolls inside it, and either takes the title or
                // the scroll position with it. Its bottom corners are
                // painted over instead.
                .overlay(alignment: .bottom) {
                    CornerCaps(radius: Self.seamRadius, color: .windowBackground)
                        .frame(height: Self.seamRadius)
                }
            RecordButton(action: onRecord)
                .clipShape(.rect(topLeadingRadius: Self.seamRadius,
                                 topTrailingRadius: Self.seamRadius))
        }
        .background(Color.windowBackground, ignoresSafeAreaEdges: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Sideways there is no height to give a pane to: a capsule under the
    /// list, as it was before the strip.
    private var landscape: some View {
        VStack(spacing: 0) {
            content
            Divider()
            RecordCapsule(action: onRecord)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.groupedBackground)
        }
    }

    @ViewBuilder
    private var content: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The one control that matters. The whole strip under the list is the
/// button: red from edge to edge and down through the home indicator,
/// with the word on it. Not a capsule, not a toolbar item — a pane.
struct RecordButton: View {
    var action: () -> Void
    @Environment(\.safeAreaInsets) private var safeArea

    var body: some View {
        Button(action: action) {
            Text("Record")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .padding(.bottom, bottomInset)
                .background(Color.red)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecordStripStyle())
        .accessibilityHint("Starts a new recording")
    }

    /// The stack ignores the bottom safe area so the red reaches the screen
    /// edge; the word stays above the home indicator.
    private var bottomInset: CGFloat {
        #if os(iOS)
        safeArea.bottom
        #else
        0
        #endif
    }
}

/// The landscape button: a full-width red capsule that says "Record".
struct RecordCapsule: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Record")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
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
}

/// The window background in the two corners of a pane's bottom edge, so
/// the pane looks rounded without touching the pane.
private struct CornerCaps: View {
    let radius: CGFloat
    let color: Color

    var body: some View {
        color
            .mask {
                Rectangle()
                    .overlay {
                        UnevenRoundedRectangle(bottomLeadingRadius: radius,
                                               bottomTrailingRadius: radius)
                            .padding(.top, -radius)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// Pressed is a shade darker, nothing else; the strip must not shrink.
private struct RecordStripStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}

extension EnvironmentValues {
    /// The window's safe area, read once at the root and passed down: a
    /// view that ignores the safe area no longer sees it, and the label
    /// still needs the number.
    @Entry var safeAreaInsets: EdgeInsets = EdgeInsets()
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

private extension Color {
    /// The list's own ground.
    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// What shows through the rounded corners where the panes meet.
    static var windowBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
}
