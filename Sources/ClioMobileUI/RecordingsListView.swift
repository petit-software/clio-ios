import ClioMobileCore
import SwiftUI

/// Two ways to put the record button under the list. Both kept, so the
/// one that is not the default can be looked at: `CLIO_HOME=pane` or
/// `CLIO_HOME=floating` at launch.
public enum HomeStyle: String, Sendable {
    /// The list ends above a red pane that is the button.
    case pane
    /// The list runs the full height; a red capsule floats over its
    /// bottom edge on a gradient that fades up from the screen edge.
    case floating

    public static let `default`: HomeStyle = .floating
}

/// The library, newest first, grouped by day. The record button sits
/// under it so it is never more than one tap away — as a pane or floating,
/// see `HomeStyle`; a capsule when the phone is sideways and height is
/// short.
struct RecordingsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var query = ""
    var style: HomeStyle = .default
    var onRecord: () -> Void
    /// Opens Settings, for the banner when nothing is installed.
    var onSettings: () -> Void = {}

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscape
            } else if style == .floating {
                floating
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
            RecordPane(onRecord: onRecord)
                .clipShape(.rect(topLeadingRadius: Self.seamRadius,
                                 topTrailingRadius: Self.seamRadius))
        }
        .background(Color.windowBackground, ignoresSafeAreaEdges: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }

    /// The list scrolls under a red wash that rises from the bottom edge
    /// and is gone a little above the button; the button floats on it.
    private var floating: some View {
        content
            // Room at the end of the list for the last row to scroll clear
            // of the button; the container reaches through the bottom safe
            // area so the wash runs to the screen edge.
            .contentMargins(.bottom, FloatingRecordPane.buttonHeight
                                     + FloatingRecordPane.buttonBottomPadding
                                     + 16 + bottomInset, for: .scrollContent)
            .overlay(alignment: .bottom) {
                FloatingRecordPane(onRecord: onRecord)
            }
            .ignoresSafeArea(edges: .bottom)
    }

    @Environment(\.safeAreaInsets) private var safeArea
    private var bottomInset: CGFloat {
        #if os(iOS)
        safeArea.bottom
        #else
        0
        #endif
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

/// The floating version: the gradient, and the capsule on it. Gone while
/// a search is in progress. With "Hold to record" on, the capsule records
/// while the finger is on it.
struct FloatingRecordPane: View {
    var onRecord: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching
    @Environment(\.safeAreaInsets) private var safeArea

    /// How far above the button the wash reaches before it is gone.
    static let washAboveButton: CGFloat = 72
    static let buttonHeight: CGFloat = 56
    static let buttonBottomPadding: CGFloat = 12

    /// How much taller the wash gets at full voice, in hold-to-record.
    static let washSwell: CGFloat = 220

    var body: some View {
        if !isSearching {
            let capture = model.capture
            let listening = model.settings.settings.holdToRecord && capture.state == .recording
            // While a held recording runs, the wash is the meter: it swells
            // up the screen with the voice and settles between words.
            let swell = listening ? CGFloat(capture.level) : 0
            ZStack(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: Color.red.opacity(0), location: 0),
                        .init(color: Color.red.opacity(0.35 + 0.2 * swell), location: 0.45),
                        .init(color: Color.red.opacity(0.95), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.washAboveButton + Self.buttonHeight
                                 + Self.buttonBottomPadding + bottomInset
                                 + swell * Self.washSwell)
                    .animation(.smooth(duration: 0.12), value: swell)
                    .allowsHitTesting(false)
                FloatingRecordButton(onRecord: onRecord)
                    .padding(.horizontal, 20)
                    .padding(.bottom, Self.buttonBottomPadding + bottomInset)
            }
        }
    }

    private var bottomInset: CGFloat {
        #if os(iOS)
        safeArea.bottom
        #else
        0
        #endif
    }
}

/// The capsule that floats on the wash. A tap opens the sheet; with
/// "Hold to record" on, a press records until the finger lifts.
struct FloatingRecordButton: View {
    var onRecord: () -> Void
    @Environment(AppModel.self) private var model
    @State private var pressing = false

    var body: some View {
        let capture = model.capture
        let hold = model.settings.settings.holdToRecord
        Group {
            if hold {
                label(capture)
                    .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 60) {
                    } onPressingChanged: { isPressing in
                        pressing = isPressing
                        Task { isPressing ? await press() : await release() }
                    }
                    .accessibilityLabel(capture.state.isCapturing ? "Recording. Release to stop." : "Record")
                    .accessibilityHint("Press and hold to record")
            } else {
                Button(action: onRecord) { label(capture) }
                    .buttonStyle(RecordStripStyle())
                    .accessibilityHint("Starts a new recording")
            }
        }
    }

    private func label(_ capture: CaptureController) -> some View {
        VStack(spacing: 1) {
            Text(title(capture))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let subtitle = subtitle(capture) {
                Text(subtitle).font(.caption2).opacity(0.85)
            }
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity)
        .frame(height: FloatingRecordPane.buttonHeight)
        .whiteGlass(dimmed: capture.state.isCapturing)
        .contentShape(Capsule(style: .continuous))
    }

    private func press() async {
        guard !model.capture.state.isBusy else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStarted() }
        await model.capture.start()
        if !pressing, model.capture.state.isCapturing { await model.capture.stop() }
    }

    private func release() async {
        guard model.capture.state.isCapturing else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStopped() }
        await model.capture.stop()
    }

    /// No clock while holding: the finger is on the button and the wash
    /// shows the voice. Only what happens after letting go is worth a word.
    private func title(_ capture: CaptureController) -> String {
        guard model.settings.settings.holdToRecord else { return "Record" }
        switch capture.state {
        case .transcribing: return "Transcribing…"
        default: return "Record"
        }
    }

    private func subtitle(_ capture: CaptureController) -> String? {
        nil
    }
}

/// The pane under the list. Gone while a search is in progress — the
/// keyboard is there, and the list is the point — and, with "Hold to
/// record" on, the button is the recorder itself.
struct RecordPane: View {
    var onRecord: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !isSearching {
            if model.settings.settings.holdToRecord {
                HoldRecordButton()
            } else {
                RecordButton(action: onRecord)
            }
        }
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

/// Press and hold: the microphone runs while the finger is down and stops
/// when it lifts. The strip shows the clock while it runs, then
/// "Transcribing…" until the recording opens.
struct HoldRecordButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.safeAreaInsets) private var safeArea
    @State private var pressing = false

    var body: some View {
        let capture = model.capture
        VStack(spacing: 2) {
            Text(title(capture))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let subtitle = subtitle(capture) {
                Text(subtitle)
                    .font(.footnote)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .padding(.bottom, bottomInset)
        .background(capture.state.isCapturing ? Color.red.opacity(0.85) : Color.red)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 60) {
            // Nothing on completion: the press itself is the action.
        } onPressingChanged: { isPressing in
            pressing = isPressing
            Task { isPressing ? await press() : await release() }
        }
        .accessibilityLabel(capture.state.isCapturing ? "Recording. Release to stop." : "Record")
        .accessibilityHint("Press and hold to record")
    }

    private func press() async {
        guard model.capture.state == .idle || !model.capture.state.isBusy else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStarted() }
        await model.capture.start()
        // Let go before the microphone was ready: nothing to keep.
        if !pressing, model.capture.state.isCapturing { await model.capture.stop() }
    }

    private func release() async {
        guard model.capture.state.isCapturing else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStopped() }
        await model.capture.stop()
    }

    private func title(_ capture: CaptureController) -> String {
        switch capture.state {
        case .starting: return "Starting…"
        case .recording, .interrupted, .paused: return Format.duration(capture.elapsed)
        case .transcribing: return "Transcribing…"
        case .idle, .failed: return "Hold to Record"
        }
    }

    private func subtitle(_ capture: CaptureController) -> String? {
        switch capture.state {
        case .recording: return "Release to stop"
        case .interrupted, .paused: return "Paused"
        case .failed(let message): return message
        default: return nil
        }
    }

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

private extension View {
    /// White Liquid Glass on iOS 26, so the wash and the rows show through
    /// the capsule under the red word; a plain white fill before it.
    @ViewBuilder
    func whiteGlass(dimmed: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(Color.white.opacity(dimmed ? 0.6 : 0.85)).interactive(),
                        in: Capsule(style: .continuous))
        } else {
            background(dimmed ? Color.white.opacity(0.85) : Color.white,
                       in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
    }
}
