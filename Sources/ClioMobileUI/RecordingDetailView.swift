import AVFoundation
import ClioMobileCore
import SwiftUI

/// One recording: play it, read it, name it, share it, delete it.
struct RecordingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let id: Recording.ID
    /// The transcript was copied on the way in (auto copy): say so.
    var copiedOnArrival = false

    @State private var player = AudioPlayerController()
    @State private var title = ""
    @State private var confirmingDelete = false
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
            Section("Transcript") {
                transcript(recording)
            }

            // The summary: a plain card like the transcript's.
            if showsSummary(recording) {
                Section("Summary") {
                    summarySection(recording)
                }
            }

            // The player is a card of its own under the summary, in the
            // flow of the page rather than pinned to its foot.
            Section {
                PlayerCard(player: player)
            }

            // Bare metadata, the way Photos prints a picture's: two columns
            // in a monospaced face, no heading, no card, no separators.
            Section {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    detail("Recorded",
                           recording.createdAt.formatted(date: .long, time: .shortened))
                    detail("Length", Format.duration(recording.duration))
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
                .font(.system(.subheadline, design: .monospaced))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
        }
        .navigationTitle($title)
        .navigationBarTitleDisplayModeInline()
        .softScrollEdges()
        .closeInsteadOfBack { dismiss() }
        .toolbar {
            // One menu. iOS 26 folds a second trailing item into an
            // overflow menu of its own anyway, so a separate share button
            // only looked like one in the source.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(item: shareText(recording)) {
                        Label("Share Transcript", systemImage: "square.and.arrow.up")
                    }
                    ShareLink(item: model.library.audioURL(for: recording)) {
                        Label("Share Audio", systemImage: "waveform")
                    }
                    .disabled(!player.isAvailable)
                    Button("Copy Transcript", systemImage: "doc.on.doc") {
                        copy(recording.transcript)
                    }
                    .disabled(recording.transcript.isEmpty)
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
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                player.stop()
                model.library.delete(id)
                dismiss()
            }
        } message: {
            Text("The audio and its transcript are removed from this phone.")
        }
        .onAppear {
            title = recording.displayTitle
            player.load(model.library.audioURL(for: recording))
            #if DEBUG
            if LaunchOptions.autoplay { player.play() }
            #endif
        }
        .onDisappear { player.stop() }
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
        .overlay(alignment: .top) {
            if copied {
                Toast("Copied", systemImage: "square.filled.on.square")
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func transcript(_ recording: Recording) -> some View {
        switch recording.status {
        case .transcribed:
            if recording.segments.isEmpty {
                Text(recording.transcript)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            } else {
                SegmentedTranscript(segments: recording.segments,
                                    currentTime: player.isPlaying || player.currentTime > 0
                                        ? player.currentTime : nil) { time in
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
            transcribeAgain("Not transcribed yet.")
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

    @ViewBuilder
    private func summarySection(_ recording: Recording) -> some View {
        if model.intelligence.isSummarizing(id) {
            HStack(spacing: 8) { ProgressView(); Text("Summarizing…") }
                .foregroundStyle(.secondary)
        } else if let failure = model.intelligence.failures[id] {
            VStack(alignment: .leading, spacing: 12) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { model.intelligence.summarize(id) }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        } else if let summary = recording.summary, !summary.isEmpty {
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
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            if model.capture.state == .transcribing {
                HStack(spacing: 8) { ProgressView(); Text("Transcribing…") }
                    .foregroundStyle(.secondary)
            } else {
                Button("Transcribe Again") {
                    Task { await model.capture.retranscribe(id) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func shareText(_ recording: Recording) -> String {
        recording.transcript.isEmpty ? recording.displayTitle : recording.transcript
    }

    private func fileSize(_ recording: Recording) -> Int64 {
        let url = model.library.audioURL(for: recording)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
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
    /// An X where the stack would draw a back chevron. Hiding the back
    /// button also loses the edge swipe; the X is the way out.
    @ViewBuilder
    func closeInsteadOfBack(_ close: @escaping () -> Void) -> some View {
        #if os(iOS)
        navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: close)
                }
            }
        #else
        self
        #endif
    }

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

/// A word and a symbol in a glass capsule, in the theme's inverse: white
/// on a dark screen, near-black on a light one, so it reads as a note
/// laid on top rather than another control.
struct Toast<Icon: View>: View {
    let title: LocalizedStringKey
    let icon: Icon
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: LocalizedStringKey, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.icon = icon()
    }

    init(_ title: LocalizedStringKey, systemImage: String) where Icon == Image {
        self.title = title
        self.icon = Image(systemName: systemImage)
    }

    var body: some View {
        let dark = colorScheme == .dark
        Label { Text(title) } icon: { icon }
            .font(.callout.weight(.semibold))
            .foregroundStyle(dark ? Color.black : Color.white)
            // A spinner as the icon takes the tint, not the foreground.
            .tint(dark ? Color.black : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .invertedGlass(dark: dark)
            .accessibilityAddTraits(.isStaticText)
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
    @State private var scrubbing = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 6) {
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
                   systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 28))
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
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
