import ClioMobileCore
import SwiftUI

/// Two ways to put the record button under the list. Both kept, so the
/// one that is not the default can be looked at: `CLIO_HOME=pane` or
/// `CLIO_HOME=floating` at launch.
/// The app's colour, taken from the icon: a lime that the icon's gradient
/// ends in at the bottom, the olive from its middle for a word on white,
/// and the near-black from its top for a word on the lime.
enum Accent {
    /// The bright green at the foot of the icon.
    static let lime = Color(red: 0.816, green: 0.973, blue: 0.471)
    /// The olive halfway up the icon, dark enough to read on white.
    static let olive = Color(red: 0.376, green: 0.447, blue: 0.216)
    /// The near-black at the top of the icon, for a word on the lime.
    static let ink = Color(red: 0.075, green: 0.086, blue: 0.043)
}

public enum HomeStyle: String, Sendable {
    /// The list ends above a green pane that is the button.
    case pane
    /// The list runs the full height; a capsule floats over its
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
        // the bottom belongs to the record button alone. Out of the way
        // until the list is pulled down.
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

    /// The list scrolls under a green wash that rises from the bottom edge
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
                        RecordingRow(recording: recording)
                            // The link is behind the row, not around it,
                            // so the list draws no chevron: the length
                            // pill has the right edge.
                            .background {
                                NavigationLink(value: recording.id) { EmptyView() }
                                    .opacity(0)
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

/// A row: the title and the start of the transcript on the left, the
/// length in a glass pill on the right, where a list would put its
/// chevron. When it was recorded is the section heading above and the
/// detail view; the row does not repeat it.
struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(recording.snippet)
                    .font(.subheadline)
                    .foregroundStyle(recording.status == .transcribed ? .secondary : .tertiary)
                    .lineLimit(2)
                if case .failed = recording.status {
                    Label("Not transcribed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Text(Format.duration(recording.duration))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .pillGlass()
        }
        .padding(.vertical, 2)
    }
}

private extension View {
    /// Liquid Glass on iOS 26, a thin material before it.
    @ViewBuilder
    func pillGlass() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
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

    /// How much taller the wash is while a held recording runs, before the
    /// voice adds to it: the recording has to be visible from across the
    /// room, not only heard in the meter.
    static let washWhileHeld: CGFloat = 80
    /// How much taller again at full voice, in hold-to-record.
    static let washSwell: CGFloat = 150

    var body: some View {
        if !isSearching {
            let capture = model.capture
            let held = model.settings.settings.holdToRecord && capture.state.isCapturing
            // While a held recording runs the wash steps up and brightens,
            // and on top of that it is the meter: its top edge is a curve
            // through the six bars, so a syllable lifts one side more than
            // the other, and it settles flat between words. The bars are
            // gated in silence, unlike the raw level, so it does not fidget
            // to room noise.
            let bands = held ? capture.bands : [Float](repeating: 0, count: MeterAnalyzer.barCount)
            let base = Self.washAboveButton + Self.buttonHeight
                     + Self.buttonBottomPadding + bottomInset
                     + (held ? Self.washWhileHeld : 0)
            let height = base + Self.washSwell
            ZStack(alignment: .bottom) {
                // Under the colour, a blur that comes on with it: nothing at
                // the top of the wash, the full radius by the button, so the
                // rows soften as they scroll in and are gone by the button.
                // Masked by the wash itself, so it follows the same edge.
                // Masked by the wash's shape, solid, not by its colour: masked
                // by the colour it lived only in the thin band where the
                // colour was neither gone nor opaque.
                WashBlur(strength: held ? 1 : 0.6)
                    .frame(height: height)
                    .mask {
                        VoiceWash(bars: BarVector(bands), base: base, swell: Self.washSwell,
                                  held: held, solid: true)
                            .animation(.smooth(duration: 0.1), value: bands)
                    }
                    .allowsHitTesting(false)
                VoiceWash(bars: BarVector(bands), base: base, swell: Self.washSwell, held: held)
                    .animation(.smooth(duration: 0.1), value: bands)
                    .frame(height: height)
                    .allowsHitTesting(false)
                FloatingRecordButton(onRecord: onRecord)
                    .padding(.horizontal, 20)
                    .padding(.bottom, Self.buttonBottomPadding + bottomInset)
            }
            .animation(.smooth(duration: 0.3), value: held)
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

/// Bar heights as a vector SwiftUI can interpolate, so the wash's edge
/// glides between meter updates instead of stepping.
struct BarVector: VectorArithmetic {
    var values: [Double]

    init(_ bands: [Float]) { values = bands.map(Double.init) }
    init(values: [Double]) { self.values = values }

    static var zero: BarVector { BarVector(values: []) }

    static func + (lhs: BarVector, rhs: BarVector) -> BarVector {
        BarVector(values: combine(lhs.values, rhs.values, +))
    }
    static func - (lhs: BarVector, rhs: BarVector) -> BarVector {
        BarVector(values: combine(lhs.values, rhs.values, -))
    }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// Elementwise, the shorter side padded with zeros.
    private static func combine(_ a: [Double], _ b: [Double],
                                _ op: (Double, Double) -> Double) -> [Double] {
        (0..<max(a.count, b.count)).map { i in
            op(i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
        }
    }
}

/// The wash, drawn as a row of thin columns each with its own height and
/// gradient: at silence a flat edge at `base`, with a voice a curve
/// through the six meter bars up to `base + swell`. Each column's gradient
/// runs from nothing at its own top to solid at the bottom, so the edge is
/// soft wherever it is. Animatable in the bars and the base, so a syllable
/// rises over a tenth of a second and the lift on hold eases in.
struct VoiceWash: View, @preconcurrency Animatable {
    var bars: BarVector
    var base: CGFloat
    var swell: CGFloat
    var held: Bool
    /// Black, opaque below a short feather at the edge: the same shape as
    /// a mask for what sits under the colour.
    var solid = false
    @Environment(\.displayScale) private var scale

    var animatableData: AnimatablePair<CGFloat, BarVector> {
        get { AnimatablePair(base, bars) }
        set { base = newValue.first; bars = newValue.second }
    }

    /// Below this a bar is silence: the edge does not move for a breath.
    static let floor = 0.06
    static let columns = 96

    var body: some View {
        Canvas { context, size in
            let stops: [Gradient.Stop] = solid ? [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.25),
                .init(color: .black, location: 1),
            ] : [
                .init(color: Accent.lime.opacity(0), location: 0),
                .init(color: Accent.lime.opacity(held ? 0.6 : 0.35), location: 0.45),
                .init(color: Accent.lime.opacity(held ? 1 : 0.95), location: 1),
            ]
            let gradient = Gradient(stops: stops)
            let heights = Self.smoothed(bars.values)
            // Column edges on device pixels, no overlap: an edge between
            // pixels is drawn twice or half and shows as a seam.
            let edges = (0...Self.columns).map { column in
                (size.width * CGFloat(column) / CGFloat(Self.columns) * scale).rounded() / scale
            }
            for column in 0..<Self.columns {
                let x = (CGFloat(column) + 0.5) / CGFloat(Self.columns)
                let h = min(size.height, base + swell * Self.lift(at: x, heights: heights))
                let rect = CGRect(x: edges[column], y: size.height - h,
                                  width: edges[column + 1] - edges[column], height: h)
                context.fill(Path(rect),
                             with: .linearGradient(gradient,
                                                   startPoint: CGPoint(x: 0, y: rect.minY),
                                                   endPoint: CGPoint(x: 0, y: rect.maxY)))
            }
        }
    }

    /// The bars above the floor, each blended with its neighbours so a
    /// loud one makes a hill and not a flame.
    static func smoothed(_ bars: [Double]) -> [CGFloat] {
        let raw = bars.map { max(0, ($0 - floor) / (1 - floor)) }
        return raw.indices.map { i in
            let left = i > 0 ? raw[i - 1] : raw[i]
            let right = i + 1 < raw.count ? raw[i + 1] : raw[i]
            return CGFloat(0.25 * left + 0.5 * raw[i] + 0.25 * right)
        }
    }

    /// The edge's height at `x` in 0…1 across the width: the bars laid out
    /// left to right, a cosine curve between neighbours, the ends held.
    static func lift(at x: CGFloat, heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        let count = CGFloat(heights.count)
        // Bar centres sit at (k + 0.5) / count.
        let position = x * count - 0.5
        let lower = Int(position.rounded(.down))
        let upper = lower + 1
        if lower < 0 { return heights[0] }
        if upper >= heights.count { return heights[heights.count - 1] }
        let t = position - CGFloat(lower)
        let eased = (1 - cos(t * .pi)) / 2
        return heights[lower] + (heights[upper] - heights[lower]) * eased
    }
}

/// The blur under the wash: a material masked by a vertical gradient, so
/// its tint and blur fade in together from the top of the wash. Not a
/// variable blur — there is no public one, and the private one was tried
/// and taken out — but it reads as one. `strength` is the material's
/// opacity at the bottom, stronger while a held recording runs.
struct WashBlur: View {
    var strength: Double

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.6 * strength), location: 0.45),
                        .init(color: .black.opacity(strength), location: 0.7),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
    }
}

/// The capsule that floats on the wash. A tap opens the sheet; with
/// "Hold to record" on, a press records until the finger lifts.
struct FloatingRecordButton: View {
    var onRecord: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
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
        .foregroundStyle(colorScheme == .dark ? Accent.lime : Accent.olive)
        // Quiet while the transcript is written: the pill at the top says so.
        .opacity(capture.state == .transcribing ? 0.5 : 1)
        .frame(maxWidth: .infinity)
        .frame(height: FloatingRecordPane.buttonHeight)
        .capsuleGlass(dark: colorScheme == .dark, dimmed: capture.state.isCapturing)
        .contentShape(Capsule(style: .continuous))
    }

    private func press() async {
        guard !model.capture.state.isBusy else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStarted() }
        await model.capture.start()
        // Let go before the microphone was ready: nothing to keep.
        if !pressing { await release() }
    }

    /// Lifting the finger stops the recording — unless the press was a
    /// tap, which throws it away rather than opening an empty recording.
    private func release() async {
        guard model.capture.state.isCapturing else { return }
        guard model.capture.elapsed >= HoldRecordButton.minimumHold else {
            await model.capture.cancel()
            return
        }
        if model.settings.settings.hapticFeedback { Haptics.recordStopped() }
        await model.capture.stop()
    }

    /// No clock while holding: the finger is on the button and the wash
    /// shows the voice. The word says what the button does, then what it
    /// is doing.
    private func title(_ capture: CaptureController) -> String {
        guard model.settings.settings.holdToRecord else { return "Record" }
        switch capture.state {
        case .starting: return "Starting…"
        case .recording, .interrupted, .paused: return "Recording"
        case .transcribing, .idle, .failed: return "Press and hold to record"
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
/// button: green from edge to edge and down through the home indicator,
/// with the word on it. Not a capsule, not a toolbar item — a pane.
struct RecordButton: View {
    var action: () -> Void
    @Environment(\.safeAreaInsets) private var safeArea

    var body: some View {
        Button(action: action) {
            Text("Record")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Accent.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .padding(.bottom, bottomInset)
                .background(Accent.lime)
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
        .foregroundStyle(Accent.ink)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .padding(.bottom, bottomInset)
        .background(capture.state.isCapturing ? Accent.lime.opacity(0.85) : Accent.lime)
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

    /// A press shorter than this is a tap, not a recording: it is thrown
    /// away instead of saved and opened as an empty recording.
    static let minimumHold: TimeInterval = 0.5

    private func press() async {
        guard model.capture.state == .idle || !model.capture.state.isBusy else { return }
        if model.settings.settings.hapticFeedback { Haptics.recordStarted() }
        await model.capture.start()
        // Let go before the microphone was ready: nothing to keep.
        if !pressing { await release() }
    }

    private func release() async {
        guard model.capture.state.isCapturing else { return }
        guard model.capture.elapsed >= Self.minimumHold else {
            await model.capture.cancel()
            return
        }
        if model.settings.settings.hapticFeedback { Haptics.recordStopped() }
        await model.capture.stop()
    }

    private func title(_ capture: CaptureController) -> String {
        switch capture.state {
        case .starting: return "Starting…"
        case .recording, .interrupted, .paused: return Format.duration(capture.elapsed)
        case .transcribing, .idle, .failed: return "Hold to Record"
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

/// The landscape button: a full-width green capsule that says "Record".
struct RecordCapsule: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Record")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Accent.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .prominentStyle()
        .buttonBorderShape(.capsule)
        .tint(Accent.lime)
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
        .navigationBarDrawer(displayMode: .automatic)
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
    /// Liquid Glass on iOS 26, so the wash and the rows show through the
    /// capsule under the word: white in light mode, near-black in dark. A
    /// plain fill before iOS 26.
    @ViewBuilder
    func capsuleGlass(dark: Bool, dimmed: Bool) -> some View {
        let tint = dark ? Accent.ink : Color.white
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(tint.opacity(dimmed ? 0.6 : 0.85)).interactive(),
                        in: Capsule(style: .continuous))
        } else {
            background(dimmed ? tint.opacity(0.85) : tint,
                       in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 12, y: 6)
        }
    }
}
