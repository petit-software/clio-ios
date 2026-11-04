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

/// What RootView needs from the library screen to draw the wash and the
/// button above the navigation stack instead of inside it: whether that
/// screen is the one on show, and whether the search field has it.
/// Reported upwards because `isSearching` only exists below `searchable`.
struct HomeChrome: Equatable, Sendable {
    var onScreen = false
    var searching = false
    /// Rows are being picked to delete. The record button and its wash are
    /// gone for the duration: the delete bar stands where the button does.
    var selecting = false
}

/// Carries `isSearching` out of the searchable view to the binding.
private struct SearchingReporter: View {
    @Binding var searching: Bool
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Color.clear
            .onChange(of: isSearching, initial: true) { _, now in
                searching = now
            }
    }
}

/// The library, newest first, grouped by day. The record button sits
/// under it so it is never more than one tap away — as a pane or floating,
/// see `HomeStyle`. The phone is portrait only (Info.plist), so there is
/// no sideways layout.
struct RecordingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Up while the "Copied" toast is on screen.
    @State private var copied = false
    /// Picking rows to delete: what is ticked, and whether the list is in
    /// that mode at all. A long press on any row starts it.
    ///
    /// Ticked by hand rather than through `EditMode` and `List(selection:)`:
    /// those put their circles on the leading edge and push the row across,
    /// and the tick belongs where the copy button is — the row's trailing
    /// edge, where the eye already is. It also keeps the whole thing off
    /// `EditMode`, which does not exist on macOS.
    @State private var selection: Set<Recording.ID> = []
    @State private var selecting = false
    /// The rows about to be deleted — from the bar or a swipe — while the
    /// confirmation is up.
    @State private var deleting: DeletionRequest?
    var style: HomeStyle = .default
    @Binding var chrome: HomeChrome
    var onRecord: () -> Void
    /// Pushes a recording. Done by hand rather than with a `NavigationLink`
    /// in the row: the link was invisible and behind the row, and worked
    /// only because a `List` cell activates a link it finds in its own
    /// subtree. A long press on the row takes the touch away from the cell
    /// before that can happen, and the row stops opening. A tap the row
    /// owns outright has nothing to lose it to.
    var onOpen: (Recording.ID) -> Void = { _ in }
    /// Opens Settings, for the banner when nothing is installed.
    var onSettings: (SettingsPage?) -> Void = { _ in }

    var body: some View {
        screen
            .animation(.smooth(duration: 0.25), value: selecting)
            // Above the record button, where the transcribing toast goes,
            // so the two never sit in different places.
            .overlay(alignment: .bottom) {
                if copied {
                    Toast("Copied", systemImage: "square.fill.on.square.fill")
                        .padding(.bottom, ToastLayout.bottomInset(above: safeArea.bottom))
                        .transition(ToastLayout.transition)
                }
            }
            .animation(.smooth(duration: 0.3), value: copied)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { endSelecting() }
                    }
                }
            }
            .deleteBar(showing: selecting && !selection.isEmpty,
                       merge: selection.count > 1 ? { mergeSelected() } : nil) {
                deleting = DeletionRequest(ids: Array(selection))
            }
            // The same confirmation a recording's own page shows, and the
            // same deletion behind it. A swipe asks too: there is no undo.
            .confirmDeletion($deleting, library: model.library) {
                if selecting { endSelecting() }
            }
            // Reported up so RootView can take the record button away, and
            // put it back the moment the mode ends.
            .onChange(of: selecting, initial: true) { _, now in
                chrome.selecting = now
            }
            // A recording deleted from somewhere else must not stay ticked.
            .onChange(of: model.library.recordings) { _, recordings in
                guard selecting else { return }
                let alive = Set(recordings.map(\.id))
                selection.formIntersection(alive)
                if alive.isEmpty { endSelecting() }
            }
            // The wash and the button are drawn by RootView, over the whole
            // navigation stack. It needs to know when this screen is the one
            // on show — and, because a pushed detail's arrival is what takes
            // them away, `onDisappear` is late by a push, which is exactly
            // right: they are covered by then.
            .onAppear { chrome.onScreen = true }
            .onDisappear { chrome.onScreen = false }
    }

    @ViewBuilder
    private var screen: some View {
        if model.library.recordings.isEmpty {
            layout
        } else {
            layout
                .navigationTitle("Recordings")
                // Under the title, not in the bottom bar where iOS 26 would
                // put it: the bottom belongs to the record button alone.
                // Out of the way until the list is pulled down.
                .searchable(text: $query, placement: .searchPlacement, prompt: "Search transcripts")
        }
    }

    @ViewBuilder
    private var layout: some View {
        if style == .floating {
            floating
        } else {
            portrait
        }
    }

    /// Nothing recorded: the screen carries no title and no search, only
    /// the empty message, the wash, the settings button in the bar, and
    /// the record button. With no model to transcribe with either, the
    /// first thing to do is download one, and the record button goes too.
    /// One at a time: a second copy restarts the toast rather than
    /// letting the first one take it away early.
    @State private var copyDismissal: Task<Void, Never>?

    private func showCopied() {
        copied = true
        copyDismissal?.cancel()
        copyDismissal = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private var needsModelFirst: Bool {
        model.library.recordings.isEmpty && model.models.installed.isEmpty
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
            if !needsModelFirst {
                RecordPane(onRecord: onRecord)
                    .clipShape(.rect(topLeadingRadius: Self.seamRadius,
                                     topTrailingRadius: Self.seamRadius))
            }
        }
        .background(Color.windowBackground, ignoresSafeAreaEdges: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }

    /// The list scrolls under a green wash that rises from the bottom edge
    /// and is gone a little above the button; the button floats on it. Only
    /// the list is here: the wash, the button and the clock are drawn by
    /// RootView over the whole navigation stack, because while a held
    /// recording runs the stack goes back as one layer — bar, title, search
    /// and rows together — and they have to stay out of it.
    private var floating: some View {
        content
            // Room at the end of the list for the last row to scroll clear
            // of the button; the container reaches through the bottom safe
            // area so the wash runs to the screen edge.
            .contentMargins(.bottom, FloatingRecordPane.buttonHeight
                                     + FloatingRecordPane.buttonBottomPadding
                                     + 16 + bottomInset, for: .scrollContent)
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

    @ViewBuilder
    private var content: some View {
        Group {
            if model.library.recordings.isEmpty {
                ContentUnavailableView {
                    if model.models.installed.isEmpty {
                        Label("Pick your local model to start recording.", systemImage: "cube.fill")
                    } else {
                        Label("No Recordings", systemImage: "waveform")
                    }
                } actions: {
                    if model.models.installed.isEmpty {
                        Button("Download") { onSettings(.model) }
                            .fontWeight(.medium)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.black)
                            .padding(.top, 12)
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SearchingReporter(searching: $chrome.searching) }
    }

    private var list: some View {
        List {
            if model.models.installed.isEmpty, !selecting {
                noModelBanner
            }
            ForEach(sections, id: \.day) { section in
                Section(section.day) {
                    ForEach(section.recordings) { recording in
                        RecordingRow(recording: recording,
                                     transcribing: model.capture.isTranscribing(recording),
                                     selecting: selecting,
                                     selected: selection.contains(recording.id)) {
                            showCopied()
                        }
                        // The whole row, gaps included, so a tap anywhere
                        // but the copy button counts.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selecting {
                                toggle(recording.id)
                            } else {
                                onOpen(recording.id)
                            }
                        }
                        .onLongPressGesture { beginSelecting(recording.id) }
                    }
                    // Swipe to delete is the other way to do this; one at a
                    // time is not what the mode is for, and the red minus
                    // would fight the tick for the left of the row.
                    .onDelete(perform: selecting ? nil : { offsets in
                        deleting = DeletionRequest(ids: offsets.map { section.recordings[$0].id })
                    })
                }
            }
        }
        .softTopEdge()
    }

    /// The long press that starts it ticks the row it landed on: nobody
    /// holds a row down meaning "and now select nothing".
    private func beginSelecting(_ id: Recording.ID) {
        guard !selecting else { return }
        if model.settings.settings.hapticFeedback { Haptics.selectionBegan() }
        selection = [id]
        withAnimation(.smooth(duration: 0.25)) { selecting = true }
    }

    private func toggle(_ id: Recording.ID) {
        withAnimation(.smooth(duration: 0.2)) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

    private func endSelecting() {
        withAnimation(.smooth(duration: 0.25)) { selecting = false }
        selection = []
    }

    /// The ticked recordings as one, oldest first, each keeping its audio
    /// and its words; then the title and summary are written again over
    /// the whole, and it opens. Split undoes it, from the recording's menu.
    private func mergeSelected() {
        guard let merged = model.library.merge(selection) else { return }
        endSelecting()
        model.intelligence.resummarize(merged)
        onOpen(merged)
    }


    /// Recording works without a model — the audio is kept and can be
    /// transcribed later — but nobody should find that out from a failed
    /// row. Shown until something is installed, and it opens Settings on
    /// the Model page: the banner is about a download, not about settings.
    private var noModelBanner: some View {
        Section {
            Button { onSettings(.model) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No transcription model")
                            .font(.headline)
                        Text("Download to start recording.")
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
    /// The transcript is being written right now: the row says so instead
    /// of "Not transcribed yet", which is what a pending part reads as.
    var transcribing = false
    /// Rows are being picked: the tick takes the copy button's place, so
    /// the row's trailing edge means one thing at a time.
    var selecting = false
    var selected = false
    /// Copying from the row, so a transcript can be had without opening
    /// it. The toast belongs to the screen, not the row, so the row only
    /// says it happened.
    var onCopy: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // One symbol for the row, centred beside the title and the
            // snippet: a text mark with a badge that says how the transcript
            // went. Only the badge is coloured; the lines stay the text's.
            if let badge {
                Image(systemName: badge.name)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(badge.color, .primary)
                    .font(.title3)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(transcribing && recording.transcript.isEmpty ? "Transcribing…" : recording.snippet)
                    .font(.subheadline)
                    .foregroundStyle(recording.status == .transcribed ? .secondary : .tertiary)
                    .lineLimit(1)
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
            trailingAction
        }
        .padding(.vertical, 2)
    }

    /// One slot on the trailing edge, past the pill: the tick while rows
    /// are being picked, the copy button otherwise, and nothing at all for
    /// a recording with no transcript to take.
    ///
    /// Always the same width, held even when it is empty. The three take
    /// different room — a circle is wider than the copy mark, and nothing
    /// is widest of all — and without the frame every pill in the list
    /// would slide as the mode changed or a row happened to have no
    /// transcript.
    private var trailingAction: some View {
        Group {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(selected ? .palette : .monochrome)
                    .foregroundStyle(selected ? Accent.ink : .secondary, Accent.lime)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(selected ? "Selected" : "Not selected")
            } else if !recording.transcript.isEmpty {
                Button("Copy Transcript", systemImage: "square.fill.on.square.fill") {
                    Clipboard.copy(recording.transcript)
                    onCopy()
                }
                .labelStyle(.iconOnly)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Plain and shaped: in a list a bordered button takes the
                // whole row with it, and the row is the link to the
                // recording.
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                Color.clear
            }
        }
        .frame(width: Self.actionWidth)
    }

    /// Wide enough for the widest of the three, which is the tick.
    static let actionWidth: CGFloat = 26

    /// A green check for a transcript, an orange cross when nothing was
    /// heard; nothing while it is pending or failed, which say so in words.
    private var badge: (name: String, color: Color)? {
        switch recording.status {
        case .transcribed: ("text.badge.checkmark", .green)
        case .nothingHeard: ("text.badge.xmark", .orange)
        case .pending, .failed: nil
        }
    }
}

private extension View {
    /// Delete, in the middle of the bottom toolbar. The bottom belongs to
    /// the record button, which is gone while rows are being picked — so
    /// the bar can have it, and the spacers put the button in the middle.
    /// `showing` is false for no bar at all; macOS has neither a bottom bar
    /// nor this mode.
    @ViewBuilder
    func deleteBar(showing: Bool, merge: (() -> Void)? = nil,
                   action: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            if showing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    // Merge beside Delete once there are two to put
                    // together; the words, not symbols, since the alert
                    // that follows Delete says how many. One item, so the
                    // two share one capsule with a hairline between them,
                    // and each word has room either side.
                    HStack(spacing: 0) {
                        if let merge {
                            Button(action: merge) {
                                Text("Merge").padding(.horizontal, 10)
                            }
                            Divider()
                                .frame(height: 18)
                        }
                        Button(role: .destructive, action: action) {
                            Text("Delete").padding(.horizontal, 10)
                        }
                        .tint(.red)
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        }
        #else
        self
        #endif
    }

    /// The bar over a scrolled list stays translucent and fades into the
    /// rows, with no hairline where the two meet. Before iOS 26 the bar's
    /// own blur applies, which draws its usual line.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26, macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

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
    /// Off, the wash stays and the button is left out: the screen has
    /// nothing to record with yet.
    var showsButton = true
    /// Passed in, not read: the pane is drawn above the navigation stack,
    /// where `isSearching` is always false.
    var searching = false
    @Environment(AppModel.self) private var model
    @Environment(\.safeAreaInsets) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The meter as drawn: a spring per bar, stepped once a frame.
    @State private var meter = WashMeter()
    /// The frame clock runs while a held recording does, and a moment
    /// after, for the edge to settle; otherwise nothing is redrawn.
    @State private var animating = false

    /// How far above the button the wash reaches before it is gone.
    static let washAboveButton: CGFloat = 60
    static let buttonHeight: CGFloat = 56
    static let buttonBottomPadding: CGFloat = 12

    /// How much taller the wash is while a held recording runs, before the
    /// voice adds to it: the recording has to be visible from across the
    /// room, not only heard in the meter.
    static let washWhileHeld: CGFloat = 80
    /// How much taller again at full voice, in hold-to-record. Large: the
    /// wash is the only meter while the finger is down, and it has to be
    /// seen moving from arm's length, not studied.
    static let washSwell: CGFloat = 260

    var body: some View {
        if !searching {
            let capture = model.capture
            let held = model.settings.settings.holdToRecord && capture.state.isCapturing
            // While a held recording runs the wash steps up and brightens,
            // and on top of that it is the meter: its top edge is a curve
            // through the six bars, so a syllable lifts one side more than
            // the other, and it settles flat between words. The bars are
            // gated in silence, unlike the raw level, so it does not fidget
            // to room noise.
            //
            // The levels come in ~60 times a second, and the screen draws up
            // to 120: an animation started on each new level is cut short by
            // the next and moves in jerks. Instead a spring per bar chases
            // the latest level, stepped on the display's own clock, so the
            // edge moves every frame and never changes speed abruptly.
            let base = Self.washAboveButton + Self.buttonHeight
                     + Self.buttonBottomPadding + bottomInset
                     + (held ? Self.washWhileHeld : 0)
            let height = base + Self.washSwell
            // With motion reduced the edge stays flat: the lift on hold
            // still says a recording is running, the voice does not move it.
            TimelineView(.animation(paused: !animating || reduceMotion)) { context in
                let bars = animating && !reduceMotion
                    ? meter.step(toward: held ? capture.bands : [], at: context.date)
                    : BarVector([Float](repeating: 0, count: MeterAnalyzer.barCount))
                wash(bars: bars, base: base, height: height, held: held)
            }
            .animation(reduceMotion ? .linear(duration: 0.2) : .smooth(duration: 0.3), value: held)
            .onChange(of: held, initial: true) { _, now in
                if now {
                    animating = true
                } else {
                    // Long enough for the springs to come down to rest.
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        guard !(model.settings.settings.holdToRecord
                                && model.capture.state.isCapturing) else { return }
                        animating = false
                        meter.reset()
                    }
                }
            }
        }
    }

    private func wash(bars: BarVector, base: CGFloat, height: CGFloat, held: Bool) -> some View {
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
                        VoiceWash(bars: bars, base: base, swell: Self.washSwell,
                                  held: held, solid: true)
                    }
                    .allowsHitTesting(false)
                VoiceWash(bars: bars, base: base, swell: Self.washSwell, held: held)
                    .frame(height: height)
                    .allowsHitTesting(false)
                if showsButton {
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

/// The wash's six bars as drawn. Each is a critically damped spring pulled
/// toward the latest level: it rises quickly to a syllable, falls more
/// slowly after it, and never overshoots. Stepped by the time between
/// frames, so it moves the same at 60 Hz and 120. A class, not state: it
/// changes every frame, and only the frame clock needs to know.
@MainActor
final class WashMeter {
    private var position = [Double](repeating: 0, count: MeterAnalyzer.barCount)
    private var velocity = [Double](repeating: 0, count: MeterAnalyzer.barCount)
    private var last: Date?

    /// Stiffness, as the spring's natural frequency in radians a second.
    /// Quick up, so a syllable is a visible jump; slower down, so the edge
    /// settles rather than drops.
    static let rise = 36.0
    static let fall = 12.0

    /// An empty target is silence: every bar back to rest.
    func step(toward target: [Float], at date: Date) -> BarVector {
        // A frame dropped, or the first one: never a leap of more than a
        // thirtieth of a second, which is what would make it jump.
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), 1.0 / 30)
        last = date
        // Split into substeps so a long frame integrates as stably as a
        // short one.
        let substeps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Double(substeps)
        for index in position.indices {
            let goal = index < target.count ? Double(target[index]) : 0
            let omega = goal > position[index] ? Self.rise : Self.fall
            for _ in 0..<substeps {
                let acceleration = omega * omega * (goal - position[index])
                    - 2 * omega * velocity[index]
                velocity[index] += acceleration * h
                position[index] += velocity[index] * h
            }
            position[index] = min(max(position[index], 0), 1)
        }
        return BarVector(values: position)
    }

    func reset() {
        position = position.map { _ in 0 }
        velocity = velocity.map { _ in 0 }
        last = nil
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
    static let floor = 0.04
    /// The bars are lifted before they are drawn — a root — so ordinary
    /// speech, which the analyser puts around a third, moves the edge by
    /// more than half, and only a whisper stays near the floor.
    static let lift = 0.6
    /// How far down the wash the fade runs before the colour is solid.
    static let fadeEnd = 1.0
    /// The ease-in's power. Higher keeps the colour faint further down:
    /// at 2.4 it is a fifth of full strength halfway, two thirds at 85%.
    static let fadeCurve = 2.4
    static let columns = 96

    var body: some View {
        Canvas { context, size in
            let stops: [Gradient.Stop] = solid
                ? Self.easedStops(.black, to: 1, reaching: 0.25)
                // Faint for most of the way down and only full at the
                // screen edge: an ease-in, so it gathers late, not early.
                : Self.easedStops(Accent.lime, to: 1, reaching: Self.fadeEnd,
                                  curve: { pow($0, Self.fadeCurve) })
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

    /// Nothing at the top to `opacity` at `reaching` (0…1 down the wash),
    /// along a smoothstep: it leaves the background with no slope at all,
    /// so there is no line where the colour starts, and the many stops
    /// keep a bend in a straight-line ramp from showing as a band.
    static func easedStops(_ color: Color, to opacity: Double,
                           reaching end: Double = 1, count: Int = 24,
                           curve: (Double) -> Double = { $0 * $0 * (3 - 2 * $0) })
        -> [Gradient.Stop] {
        var stops = (0...count).map { i -> Gradient.Stop in
            let t = Double(i) / Double(count)
            let eased = curve(t)
            return .init(color: color.opacity(opacity * eased), location: t * end)
        }
        if end < 1 { stops.append(.init(color: color.opacity(opacity), location: 1)) }
        return stops
    }

    /// The bars above the floor, each blended with its neighbours so a
    /// loud one makes a hill and not a flame.
    static func smoothed(_ bars: [Double]) -> [CGFloat] {
        let raw = bars.map { pow(max(0, ($0 - floor) / (1 - floor)), lift) }
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
                    stops: VoiceWash.easedStops(.black, to: strength, reaching: VoiceWash.fadeEnd),
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
                    .accessibilityHint(model.capture.appendTarget == nil
                                       ? "Starts a new recording"
                                       : "Records more into this recording")
            }
        }
    }

    private func label(_ capture: CaptureController) -> some View {
        Text(title(capture))
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
        // Plain: black on white glass in light mode, white on black in dark.
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
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
        // A held recording with no speech in it is thrown away, not saved
        // as "nothing heard": a brush of the button leaves nothing behind.
        await model.capture.start(discardingSilence: true)
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
    /// On a recording's page the button adds to it, and says so in the
    /// title rather than a second line.
    private func title(_ capture: CaptureController) -> String {
        let adding = model.capture.appendTarget != nil
        guard model.settings.settings.holdToRecord else {
            return adding ? "Add a Recording" : "Record"
        }
        switch capture.state {
        case .starting: return "Starting…"
        case .recording, .interrupted, .paused: return "Recording"
        case .transcribing, .idle, .failed: return adding ? "Add a Recording" : "Hold to Record"
        }
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
        // A held recording with no speech in it is thrown away, not saved
        // as "nothing heard": a brush of the button leaves nothing behind.
        await model.capture.start(discardingSilence: true)
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
