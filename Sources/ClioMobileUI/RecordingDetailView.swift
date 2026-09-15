import AVFoundation
import ClioMobileCore
import SwiftUI

/// One recording: play it, read it, name it, share it, delete it.
struct RecordingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: Recording.ID

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

            if showsSummary(recording) {
                Section("Summary") {
                    summarySection(recording)
                }
            }

            Section("Details") {
                LabeledContent("Recorded",
                               value: recording.createdAt.formatted(date: .long, time: .shortened))
                LabeledContent("Length", value: Format.duration(recording.duration))
                LabeledContent("Language", value: TranscriptionLanguage.name(for: recording.language))
                if let modelID = recording.modelID {
                    LabeledContent("Model", value: model.models.displayName(for: modelID))
                }
                let bytes = fileSize(recording)
                if bytes > 0 {
                    LabeledContent("Audio", value: Format.bytes(bytes))
                }
            }
        }
        .navigationTitle($title)
        .navigationBarTitleDisplayModeInline()
        .playerBar { PlayerBar(player: player) }
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
        .onChange(of: recording.displayTitle) { _, newValue in
            // The language model named it while this screen was open. Only
            // shown if the user has not typed a name of their own.
            if recording.title.isEmpty, title != newValue { title = newValue }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

private extension View {
    /// The recording zooms out of its row, so it closes like a sheet: an
    /// X where the stack would draw a back chevron. The zoom's own drag
    /// still dismisses it.
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

    func skip(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }
}

/// The player, in the bar at the bottom of the detail view: the scrubber
/// with the times under it, and the three transport buttons.
struct PlayerBar: View {
    @Bindable var player: AudioPlayerController

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: $player.currentTime, in: 0...max(player.duration, 0.01)) { editing in
                if !editing { player.seek(to: player.currentTime) }
            }
            .disabled(!player.isAvailable)
            HStack {
                Text(Format.duration(player.currentTime)).monospacedDigit()
                Spacer()
                HStack(spacing: 36) {
                    Button("Back 15 seconds", systemImage: "gobackward.15") { player.skip(-15) }
                    Button(player.isPlaying ? "Pause" : "Play",
                           systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        player.toggle()
                    }
                    .font(.system(size: 28))
                    .contentTransition(.symbolEffect(.replace))
                    Button("Forward 15 seconds", systemImage: "goforward.15") { player.skip(15) }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.plain)
                .disabled(!player.isAvailable)
                Spacer()
                Text("-" + Format.duration(max(0, player.duration - player.currentTime)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private extension View {
    /// The bar under the detail view. `safeAreaBar` on iOS 26 gets the
    /// scroll-edge treatment; `safeAreaInset` is the same idea before it.
    @ViewBuilder
    func playerBar<Bar: View>(@ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom) { bar() }
        } else {
            safeAreaInset(edge: .bottom) { bar().background(.bar) }
        }
    }
}

struct PlayerCard: View {
    @Bindable var player: AudioPlayerController
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 12) {
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

            HStack(spacing: 40) {
                Button("Back 15 seconds", systemImage: "gobackward.15") { player.skip(-15) }
                Button(player.isPlaying ? "Pause" : "Play",
                       systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.toggle()
                }
                .font(.system(size: 36))
                .contentTransition(.symbolEffect(.replace))
                Button("Forward 15 seconds", systemImage: "goforward.15") { player.skip(15) }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
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
