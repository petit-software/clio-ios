import AVFoundation
import ClioMobileCore
import SwiftUI

/// One recording: play it, read it, name it, share it, delete it — and
/// record more into it, from the button at the foot of the screen.
struct RecordingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.safeAreaInsets) private var safeArea
    let id: Recording.ID
    /// The transcript was copied on the way in (auto copy): say so.
    var copiedOnArrival = false

    @State private var player = AudioPlayerController()
    /// The part the player has loaded. Nil until something is loaded.
    @State private var playingPart: RecordingPart.ID?
    @State private var title = ""
    @State private var deleting: DeletionRequest?
    @State private var copied = false

    var body: some View {
        if let recording = model.library[id] {
            content(recording)
        } else {
            ContentUnavailableView("Recording Deleted", systemImage: "trash")
        }
    }

    private func content(_ recording: Recording) -> some View {
        List {
            Section {
                if recording.parts.count == 1 {
                    transcript(recording.parts[0], of: recording)
                } else {
                    // One on top of another, oldest first: each part's
                    // time and length, a button to play it, and its words.
                    ForEach(Array(recording.parts.enumerated()), id: \.element.id) { index, part in
                        VStack(alignment: .leading, spacing: 6) {
                            partHeader(part, number: index + 1)
                            transcript(part, of: recording)
                        }
                    }
                }
            } header: {
                sectionHeader("Transcript",
                              copy: recording.transcript.isEmpty ? nil : recording.transcript)
            }

            // The summary: a plain card like the transcript's.
            if showsSummary(recording) {
                Section {
                    summarySection(recording)
                } header: {
                    sectionHeader("Summary", copy: recording.summary.flatMap {
                        $0.isEmpty || model.intelligence.isSummarizing(id) ? nil : $0
                    })
                }
            }

            // The player is a card of its own under the summary, in the
            // flow of the page rather than pinned to its foot. With several
            // parts it plays them one after another.
            Section {
                PlayerCard(player: player, caption: playerCaption(recording))
            }

            // Bare metadata, the way Photos prints a picture's: two columns
            // in a monospaced face, no heading, no card, no separators.
            Section {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    detail("Recorded",
                           recording.createdAt.formatted(
                               .dateTime.day().month(.abbreviated).year().hour().minute()))
                    detail("Length", Format.duration(recording.duration))
                    if recording.parts.count > 1 {
                        detail("Parts", "\(recording.parts.count)")
                    }
                    detail("Language", TranscriptionLanguage.name(for: recording.language))
                    if let modelID = recording.modelID {
                        detail("Model", model.models.displayName(for: modelID))
                    }
                    let bytes = fileSize(recording)
                    if bytes > 0 {
                        detail("Audio", Format.bytes(bytes))
                    }
                    if let location = recording.location {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Location")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Link(destination: mapsURL(location)) {
                                HStack(spacing: 6) {
                                    Text(location.label)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                            .gridColumnAlignment(.leading)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                // Inside the row's rounded corners, which clip whatever
                // crosses them even with no background drawn.
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .navigationTitle($title)
        .navigationBarTitleDisplayModeInline()
        .softScrollEdges()
        // Room for the record button that floats over the foot of the
        // screen, so the last lines can scroll clear of it.
        .contentMargins(.bottom, FloatingRecordPane.buttonHeight
                                 + FloatingRecordPane.buttonBottomPadding + 16,
                        for: .scrollContent)
        .toolbar {
            // One menu. iOS 26 folds a second trailing item into an
            // overflow menu of its own anyway, so a separate share button
            // only looked like one in the source. Grouped: sending it
            // somewhere, taking the text, doing the work again, and
            // Delete on its own at the bottom.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section {
                        ShareLink(item: shareText(recording)) {
                            Label("Share Transcript", systemImage: "square.and.arrow.up")
                        }
                        ShareLink(items: model.library.audioURLs(for: recording)) {
                            Label("Share Audio", systemImage: "waveform")
                        }
                        .disabled(!player.isAvailable)
                    }
                    Section {
                        Button("Copy Transcript", systemImage: Self.menuCopySymbol) {
                            copy(recording.transcript)
                        }
                        .disabled(recording.transcript.isEmpty)
                        Button("Copy Summary", systemImage: Self.menuCopySymbol) {
                            copy(recording.summary ?? "")
                        }
                        .disabled((recording.summary ?? "").isEmpty)
                    }
                    Section {
                        Button("Transcribe Again", systemImage: "arrow.clockwise") {
                            Task { await model.capture.retranscribe(id) }
                        }
                        .disabled(model.capture.state.isBusy)
                        if model.intelligence.availability.isAvailable {
                            Button(recording.summary == nil ? "Summarize" : "Summarize Again",
                                   systemImage: "text.badge.star") {
                                model.intelligence.summarize(id)
                            }
                            .disabled(recording.transcript.isEmpty
                                      || model.intelligence.isSummarizing(id))
                        }
                        // Undoes a merge, or takes back what was recorded
                        // into it. Each part keeps its audio and words.
                        if recording.parts.count > 1 {
                            Button("Split into \(recording.parts.count) Recordings",
                                   systemImage: "square.split.1x2") {
                                player.stop()
                                playingPart = nil
                                model.library.split(id)
                                if let first = model.library[id]?.parts.first {
                                    load(first)
                                }
                            }
                            .disabled(model.capture.state.isBusy)
                        }
                    }
                    Section {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleting = DeletionRequest(ids: [id])
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        // The same confirmation the list shows, and the same deletion.
        .confirmDeletion($deleting, library: model.library) {
            player.stop()
            dismiss()
        }
        .onAppear {
            title = recording.displayTitle
            load(recording.parts[0])
            #if DEBUG
            if LaunchOptions.autoplay { player.play() }
            #endif
        }
        .onDisappear { player.stop() }
        // One part played to its end: the next one follows, so several
        // parts play as the one recording they are.
        .onChange(of: player.isPlaying) { was, now in
            guard was, !now, player.currentTime >= player.duration - 0.1,
                  let current = model.library[id],
                  let index = current.parts.firstIndex(where: { $0.id == playingPart }),
                  index + 1 < current.parts.count else { return }
            load(current.parts[index + 1])
            player.play()
        }
        .onChange(of: title) { _, newValue in
            // Only a name the user typed is stored; the derived one stays derived.
            guard newValue != recording.displayTitle || !recording.title.isEmpty else { return }
            model.library.rename(id, to: newValue)
        }
        .onAppear { if copiedOnArrival { showCopied() } }
        .onChange(of: recording.displayTitle) { _, newValue in
            // The language model named it while this screen was open. Only
            // shown if the user has not typed a name of their own.
            if recording.title.isEmpty, title != newValue { title = newValue }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Toast("Copied", systemImage: Self.copySymbol)
                    .padding(.bottom, ToastLayout.bottomInset(above: safeArea.bottom))
                    .transition(ToastLayout.transition)
            }
        }
    }

    /// The mark copying has everywhere: the list's rows, the section
    /// headers here, the menu and the toast.
    static let copySymbol = "square.fill.on.square.fill"
    /// The same mark in outline, for the menu, where every other item's
    /// symbol is a line drawing.
    static let menuCopySymbol = "square.on.square"

    /// A section's name with a copy button at its trailing end, the same
    /// small mark as on the list's rows. No button when there is nothing
    /// to copy.
    private func sectionHeader(_ name: LocalizedStringKey, copy text: String?) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let text {
                Button {
                    copy(text)
                } label: {
                    Label { Text("Copy \(Text(name))") } icon: { Image(systemName: Self.copySymbol) }
                }
                .labelStyle(.iconOnly)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                // Off the card's edge a little, not flush with it.
                .padding(.trailing, 4)
            }
        }
    }

    /// Above a part's words: when it was recorded, how long, and a button
    /// that plays it from the top.
    private func partHeader(_ part: RecordingPart, number: Int) -> some View {
        let playing = playingPart == part.id && player.isPlaying
        return HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(part.createdAt.formatted(.dateTime.hour().minute()))
            Text("·").foregroundStyle(.tertiary)
            Text(Format.duration(part.duration)).monospacedDigit()
            Spacer()
            Button(playing ? "Pause Part \(number)" : "Play Part \(number)",
                   systemImage: playing ? "pause.circle.fill" : "play.circle.fill") {
                if playingPart == part.id {
                    player.toggle()
                } else {
                    load(part)
                    player.play()
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// With several parts, which one the player is on.
    private func playerCaption(_ recording: Recording) -> String? {
        guard recording.parts.count > 1,
              let index = recording.parts.firstIndex(where: { $0.id == playingPart })
        else { return nil }
        return "Part \(index + 1) of \(recording.parts.count)"
    }

    /// Put a part's audio in the player, unless it is there already.
    private func load(_ part: RecordingPart) {
        guard playingPart != part.id else { return }
        playingPart = part.id
        player.load(model.library.audioURL(for: part))
    }

    @ViewBuilder
    private func transcript(_ part: RecordingPart, of recording: Recording) -> some View {
        switch part.status {
        case .transcribed:
            if part.segments.isEmpty {
                Text(part.transcript)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            } else {
                SegmentedTranscript(segments: part.segments,
                                    currentTime: playingPart == part.id
                                        && (player.isPlaying || player.currentTime > 0)
                                        ? player.currentTime : nil) { time in
                    load(part)
                    guard player.isAvailable else { return }
                    player.seek(to: time)
                    if !player.isPlaying { player.play() }
                }
                .padding(.vertical, 4)
            }
        case .nothingHeard:
            Label("Nothing was heard in this recording.", systemImage: "waveform.slash")
                .foregroundStyle(.secondary)
        case .pending:
            if model.capture.isTranscribing(part) {
                HStack(spacing: 8) { ProgressView(); Text("Transcribing…") }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                transcribeAgain("Not transcribed yet.")
            }
        case .failed(let message):
            transcribeAgain(message)
        }
    }

    // MARK: Summary

    /// The section exists when there is a summary, one is on its way, one
    /// failed, or the phone could write one on request. On a phone that
    /// cannot, there is nothing to show and nothing to explain here —
    /// Settings has the reason.
    private func showsSummary(_ recording: Recording) -> Bool {
        guard recording.status == .transcribed else { return false }
        if let summary = recording.summary, !summary.isEmpty { return true }
        if model.intelligence.isSummarizing(id) { return true }
        if model.intelligence.failures[id] != nil { return true }
        return model.intelligence.availability.isAvailable
    }

    /// The summary that is there stays on screen while a new one is
    /// written and when writing one fails: a failed Summarize Again costs
    /// nothing, and says so above the words it left alone.
    @ViewBuilder
    private func summarySection(_ recording: Recording) -> some View {
        let summary = recording.summary.flatMap { $0.isEmpty ? nil : $0 }
        if model.intelligence.isSummarizing(id) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { ProgressView(); Text(summary == nil ? "Summarizing…" : "Summarizing again…") }
                    .foregroundStyle(.secondary)
                if let summary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        } else if let failure = model.intelligence.failures[id] {
            VStack(alignment: .leading, spacing: 12) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button(summary == nil ? "Try Again" : "Summarize Again") {
                    model.intelligence.summarize(id)
                }
                .buttonStyle(.bordered)
                if let summary {
                    Text(summary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        } else if let summary {
            Text(summary)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        } else {
            Button("Summarize", systemImage: "text.badge.star") {
                model.intelligence.summarize(id)
            }
        }
    }

    private func transcribeAgain(_ message: String) -> some View {
        let recording = model.library[id]
        return
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            if let recording, model.capture.isTranscribing(recording) {
                HStack(spacing: 8) { ProgressView(); Text("Transcribing…") }
                    .foregroundStyle(.secondary)
            } else {
                Button("Transcribe Again") {
                    Task { await model.capture.retranscribe(id) }
                }
                .buttonStyle(.bordered)
                .disabled(model.capture.state.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func shareText(_ recording: Recording) -> String {
        recording.transcript.isEmpty ? recording.displayTitle : recording.transcript
    }

    private func fileSize(_ recording: Recording) -> Int64 {
        model.library.audioBytes(of: recording)
    }

    /// The place in Maps, pinned as "Recording".
    private func mapsURL(_ location: RecordingLocation) -> URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [
            URLQueryItem(name: "ll", value: "\(location.latitude),\(location.longitude)"),
            URLQueryItem(name: "q", value: "Recording"),
        ]
        return parts.url!
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
        showCopied()
    }

    /// The toast, for a copy made here or one made for the user on the
    /// way in.
    private func showCopied() {
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - Segments

/// The transcript as one flowing paragraph whose sentences can be tapped.
///
/// Each segment is a link in one attributed string, so the text wraps like
/// prose rather than stacking a view per sentence; the tap arrives through
/// `openURL` with the segment's start time. The sentence being played is
/// tinted, which is how the eye follows the audio.
struct SegmentedTranscript: View {
    let segments: [TranscriptSegment]
    let currentTime: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.scheme,
                      let seconds = TimeInterval(url.host() ?? "") else { return .discarded }
                onSeek(seconds)
                return .handled
            })
            .accessibilityHint("Tap a sentence to play it")
    }

    private static let scheme = "clio-seek"

    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            var piece = AttributedString(segment.text)
            piece.link = URL(string: "\(Self.scheme)://\(segment.start)")
            piece.foregroundColor = .primary
            if let currentTime, segment.contains(currentTime) {
                piece.backgroundColor = Color.accentColor.opacity(0.22)
                piece.foregroundColor = .accentColor
            }
            result.append(piece)
            if index < segments.count - 1 { result.append(AttributedString(" ")) }
        }
        return result
    }
}

// MARK: - Player

/// Play, pause, scrub. Wraps AVAudioPlayer; position is polled rather than
/// delivered by delegate so nothing here needs to be an NSObject.
@MainActor
@Observable
final class AudioPlayerController {
    private(set) var isPlaying = false
    private(set) var isAvailable = false
    var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        isAvailable = player != nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    if player.currentTime == 0 || player.currentTime >= player.duration - 0.05 {
                        self.currentTime = player.duration
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func stop() {
        player?.stop()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }
}

/// The player, a card in the flow of the detail view: the scrubber with
/// the times under it, and a lone play button to its right.

/// Where a toast sits and how it goes.
enum ToastLayout {
    /// In place: it fades and shrinks where it is, no sliding in or out.
    static var transition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.85))
    }

    /// Room to sit above the floating record button on the list. On the
    /// main actor because the numbers it adds up belong to a View, and in
    /// Swift 6 that makes them main-actor too — every caller is a body.
    @MainActor
    static func bottomInset(above safeAreaBottom: CGFloat) -> CGFloat {
        FloatingRecordPane.buttonHeight + FloatingRecordPane.buttonBottomPadding
            + safeAreaBottom + 16
    }
}

/// A word and a symbol in a glass capsule, in the theme's inverse: white
/// on a dark screen, near-black on a light one, so it reads as a note
/// laid on top rather than another control.
struct Toast<Icon: View>: View {
    let title: LocalizedStringKey
    let icon: Icon
    /// With one, an X at the trailing end that stops what the toast is
    /// about — the transcription, say. Without, the toast is a note only.
    var onCancel: (() -> Void)?
    var cancelLabel: LocalizedStringKey = "Cancel"
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: LocalizedStringKey, onCancel: (() -> Void)? = nil,
         cancelLabel: LocalizedStringKey = "Cancel", @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.icon = icon()
        self.onCancel = onCancel
        self.cancelLabel = cancelLabel
    }

    init(_ title: LocalizedStringKey, systemImage: String) where Icon == Image {
        self.title = title
        self.icon = Image(systemName: systemImage)
    }

    var body: some View {
        let dark = colorScheme == .dark
        let foreground = dark ? Color.black : Color.white
        HStack(spacing: 12) {
            Label { Text(title) } icon: { icon }
                .accessibilityAddTraits(.isStaticText)
            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(foreground.opacity(0.15), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cancelLabel)
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(foreground)
        // A spinner as the icon takes the tint, not the foreground.
        .tint(foreground)
        .padding(.leading, 16)
        .padding(.trailing, onCancel == nil ? 16 : 10)
        .padding(.vertical, onCancel == nil ? 10 : 8)
        .invertedGlass(dark: dark)
    }
}

private extension View {
    /// Liquid Glass on iOS 26, a plain fill before it, tinted to the
    /// theme's inverse.
    @ViewBuilder
    func invertedGlass(dark: Bool) -> some View {
        let tint = dark ? Color.white : Color.black
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(tint.opacity(0.9)), in: Capsule(style: .continuous))
        } else {
            background(tint.opacity(0.92), in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(dark ? 0.3 : 0.2), radius: 10, y: 4)
        }
    }

}

struct PlayerCard: View {
    @Bindable var player: AudioPlayerController
    /// Above the scrubber, when there is something to say: which part.
    var caption: String? = nil
    @State private var scrubbing = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let caption {
                    Text(caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $player.currentTime, in: 0...max(player.duration, 0.01)) { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: player.currentTime) }
                }
                .disabled(!player.isAvailable)

                HStack {
                    Text(Format.duration(player.currentTime)).monospacedDigit()
                    Spacer()
                    Text("-" + Format.duration(max(0, player.duration - player.currentTime)))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button(player.isPlaying ? "Pause" : "Play",
                   systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                player.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 28))
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
    }
}

#Preview("Transcribed") {
    let model = AppModel.simulating()
    NavigationStack {
        RecordingDetailView(id: model.library.recordings[1].id)
    }
    .environment(model)
}

#Preview("Failed") {
    let model = AppModel.simulating()
    NavigationStack {
        RecordingDetailView(id: model.library.recordings[4].id)
    }
    .environment(model)
}

#Preview("No summary yet") {
    let model = AppModel.simulating()
    NavigationStack {
        RecordingDetailView(id: model.library.recordings[3].id)
    }
    .environment(model)
}

#Preview("No Apple Intelligence") {
    let model = AppModel.simulating(
        summarizer: StubSummaryEngine(availability: .unavailable(reason: "Apple Intelligence is off.")))
    NavigationStack {
        RecordingDetailView(id: model.library.recordings[3].id)
    }
    .environment(model)
}

/// The system clipboard, one call for either platform.
enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
