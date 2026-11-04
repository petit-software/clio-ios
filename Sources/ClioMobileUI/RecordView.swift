import ClioMobileCore
import SwiftUI

/// The record sheet: a red pill saying it is recording, the clock, the
/// meter, and the pause and stop capsules in the bottom inset. A system
/// sheet at medium height in the phone's appearance; recording starts as
/// it appears, Stop closes it, and the transcript is written behind the
/// list.
///
/// The recorder is the shared `CaptureController`, so the sheet shows
/// whatever state the controller is in and the rest of the app — the Live
/// Activity, the list — follows the same state.
struct RecordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 64
    @State private var confirmingDiscard = false
    /// Recording has been asked for from this sheet: an idle state after
    /// it means the recording landed or was cancelled, and the sheet goes.
    @State private var started = false
    private let startsAutomatically: Bool
    /// Called when the sheet should go: discarded, closed after a failure,
    /// or the recording stopped. The root opens a recording that lands.
    private let onClose: () -> Void

    /// The controls' height and fills: the capsules the sheet has had all
    /// along, on fills that follow the appearance.
    static let actionHeight: CGFloat = 52
    static let inertFill = Color.secondary.opacity(0.18)
    static let destructive = Color.red

    init(startsAutomatically: Bool = true, onClose: @escaping () -> Void = {}) {
        self.startsAutomatically = startsAutomatically
        self.onClose = onClose
    }

    var body: some View {
        let capture = model.capture
        VStack(spacing: 16) {
            statusPill(capture)
                .padding(.top, 8)
            Spacer(minLength: 0)
            clock(capture)
            VoiceBarsMeter(bands: capture.bands, reduceMotion: reduceMotion)
                .frame(height: 64)
                .padding(.horizontal, 32)
                .opacity(capture.state == .recording ? 1 : 0.35)
                .animation(.default, value: capture.state == .recording)
            if capture.state == .interrupted {
                Text("Another app has the microphone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = capture.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            controls(capture)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // A swipe down must not throw a recording away. The X asks first.
        .interactiveDismissDisabled(capture.state.isBusy)
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                Task { await close(cancelling: true) }
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The audio so far is deleted.")
        }
        .task {
            if startsAutomatically { await begin() }
        }
        .onChange(of: capture.state) { _, state in
            guard started else { return }
            // Stopped, or the cap was reached: the words are written behind
            // the list, where the root shows a pill for the wait and opens
            // the recording when it is there. Nothing to add here.
            if state == .transcribing { onClose() }
            // Landed without a transcript to wait for (nothing was heard):
            // the root opens it.
            if state == .idle, capture.lastRecordingID != nil { onClose() }
        }
    }

    // MARK: Status

    /// Where a title would be: a red pill that says Recording, grey when
    /// paused or still starting.
    private func statusPill(_ capture: CaptureController) -> some View {
        let recording = capture.state == .recording
        let word: String = switch capture.state {
        case .recording: capture.appendingTo == nil ? "Recording" : "Adding to Recording"
        case .paused, .interrupted: "Paused"
        case .starting: "Starting…"
        case .failed: "Failed"
        case .idle, .transcribing: "Recording"
        }
        return HStack(spacing: 8) {
            if recording {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            Text(word)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(recording ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(recording ? Self.destructive : Self.inertFill, in: Capsule(style: .continuous))
        .animation(.default, value: recording)
        .accessibilityLabel(word)
    }

    private func clock(_ capture: CaptureController) -> some View {
        let seconds = Int(capture.elapsed)
        return Text(Format.duration(capture.elapsed))
            .font(.system(size: clockSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(seconds)))
            .animation(reduceMotion ? nil : .default, value: seconds)
            .accessibilityLabel("\(statusWord(capture)), \(Format.duration(capture.elapsed))")
    }

    private func statusWord(_ capture: CaptureController) -> String {
        switch capture.state {
        case .recording: "Recording"
        case .paused, .interrupted: "Paused"
        case .starting: "Starting"
        case .failed: "Failed"
        case .idle, .transcribing: ""
        }
    }

    // MARK: Controls

    /// Pause, Stop, and the X that discards — the capsules the sheet had
    /// before, each `actionHeight` tall and drawing its own fill.
    @ViewBuilder
    private func controls(_ capture: CaptureController) -> some View {
        switch capture.state {
        case .failed:
            HStack(spacing: 12) {
                capsuleButton("Close", fill: Self.inertFill) {
                    Task { await close(cancelling: false) }
                }
                capsuleButton("Try Again", fill: Self.destructive, foreground: .white) {
                    capture.dismissFailure()
                    Task { await begin() }
                }
            }
        default:
            let paused = capture.state == .paused
            let canPause = capture.state == .recording || paused
            let canStop = capture.state.isCapturing
            HStack(spacing: 12) {
                iconButton(paused ? "play.fill" : "pause.fill",
                           label: paused ? "Resume" : "Pause",
                           disabled: !canPause) {
                    Task { paused ? await capture.resume() : await capture.pause() }
                }
                Button {
                    Task { await stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: Self.actionHeight)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .background(canStop ? Self.destructive : Self.inertFill,
                            in: Capsule(style: .continuous))
                .disabled(!canStop)
                .accessibilityLabel("Stop recording")
                iconButton("xmark", label: "Discard recording", disabled: !capture.state.isBusy) {
                    confirmingDiscard = true
                }
            }
        }
    }

    private func capsuleButton(_ title: LocalizedStringKey, fill: Color,
                               foreground: Color = .primary,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: Self.actionHeight)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(fill, in: Capsule(style: .continuous))
    }

    private func iconButton(_ symbol: String, label: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
                .frame(maxWidth: .infinity, minHeight: Self.actionHeight)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Self.inertFill, in: Capsule(style: .continuous))
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func begin() async {
        started = true
        await model.capture.start()
        if model.capture.state == .recording {
            haptic(Haptics.recordStarted)
        } else if case .failed = model.capture.state {
            haptic(Haptics.failure)
        }
    }

    /// Stop, and go: the transcript is written behind the list, where the
    /// root shows a pill for the wait, and the recording opens when it is
    /// there. The sheet has nothing to add to that.
    private func stop() async {
        haptic(Haptics.recordStopped)
        Task { await model.capture.stop() }
        onClose()
    }

    private func close(cancelling: Bool) async {
        if cancelling { await model.capture.cancel() } else { model.capture.dismissFailure() }
        onClose()
    }

    private func haptic(_ play: @MainActor () -> Void) {
        guard model.settings.settings.hapticFeedback else { return }
        play()
    }
}

/// The red dot that says a recording is running: on the sheet, in the held
/// overlay and on the hold button. It breathes unless motion is reduced.
struct RecordingDot: View {
    var pulsing = true

    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(.red)
            .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
            .accessibilityHidden(true)
    }
}

/// Six bars that stay where they are and react to the voice: circles at
/// rest, each one rising with the part of the voice it hears. No timeline,
/// nothing scrolls; the meter is a face, not a chart. The levels arrive
/// sixty times a second already smoothed by `MeterAnalyzer`; the animation
/// here only bridges one reading to the next.
struct VoiceBarsMeter: View {
    let bands: [Float]
    var tint: Color = .primary
    var reduceMotion = false
    private let spacing: CGFloat = 10
    private let barWidth: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let room = max(barWidth, proxy.size.height)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<MeterAnalyzer.barCount, id: \.self) { index in
                    let level = index < bands.count ? CGFloat(bands[index]) : 0
                    Capsule(style: .continuous)
                        .fill(tint)
                        // A circle at rest; the whole height at full voice.
                        .frame(width: barWidth, height: barWidth + level * (room - barWidth))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? .linear(duration: 0.2) : .smooth(duration: 0.12), value: bands)
        }
        .accessibilityLabel("Audio level")
        .accessibilityValue(loudness)
    }

    /// A word for VoiceOver, since the bars are not read.
    private var loudness: String {
        let mean = bands.isEmpty ? 0 : bands.reduce(0, +) / Float(bands.count)
        switch mean {
        case ..<0.05: return "Silent"
        case ..<0.3: return "Quiet"
        case ..<0.7: return "Normal"
        default: return "Loud"
        }
    }
}

#Preview("Recording") {
    Text("Library").sheet(isPresented: .constant(true)) {
        RecordView()
    }
    .environment(AppModel.simulating())
}

#Preview("Paused by a call") {
    let recorder = SimulatedRecorder()
    let model = AppModel.simulating(recorder: recorder)
    Text("Library").sheet(isPresented: .constant(true)) {
        RecordView()
    }
    .environment(model)
    .task {
        try? await Task.sleep(for: .seconds(2))
        recorder.simulate(.interrupted)
    }
}

#Preview("Failed") {
    let recorder = SimulatedRecorder(permissionGranted: true,
                                     startError: AudioRecorder.RecorderError.permissionDenied)
    Text("Library").sheet(isPresented: .constant(true)) {
        RecordView()
    }
    .environment(AppModel.simulating(recorder: recorder))
}
