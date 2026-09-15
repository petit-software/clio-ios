import ClioMobileCore
import SwiftUI

/// The dark surface the recording sheet is drawn on, and what sits on it.
/// Copied from Scribia's capture surface so the two apps' recorders look
/// like the same thing.
enum RecordSurface {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.075)
    static let inertFill = Color(red: 0.158, green: 0.165, blue: 0.186)
    static let destructive = Color(red: 1.0, green: 0.231, blue: 0.188)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.3)
    static let actionHeight: CGFloat = 52
    static let motion: Double = 0.22
}

/// The record sheet: a countdown, then the clock and the meter, pause,
/// stop, start again. Presented at medium height; pulled up to large it
/// gives the clock and the meter more room.
///
/// Adapted from Scribia's `RecordingView`. The recorder there is the
/// sheet's own model; here it is the shared `CaptureController`, so the
/// sheet shows whatever state the controller is in and the rest of the
/// app — the Live Activity, the list — follows the same state.
struct RecordView: View {
    private enum Phase: Equatable {
        case countdown(Int)
        case live
    }

    @Environment(AppModel.self) private var model
    @Binding private var presentationDetent: PresentationDetent
    @State private var phase: Phase = .countdown(3)
    @State private var countdownTask: Task<Void, Never>?
    @State private var confirmingDiscard = false
    private let startsAutomatically: Bool
    /// Called when the sheet should go: cancelled, closed after a failure,
    /// or the recording has landed. The root also opens a recording that
    /// lands, so this only closes.
    private let onClose: () -> Void

    init(presentationDetent: Binding<PresentationDetent> = .constant(.medium),
         startsAutomatically: Bool = true,
         onClose: @escaping () -> Void = {}) {
        _presentationDetent = presentationDetent
        self.startsAutomatically = startsAutomatically
        self.onClose = onClose
    }

    var body: some View {
        let capture = model.capture
        VStack(spacing: 16) {
            // The header is drawn here, not as a toolbar principal item:
            // with the bar's background hidden, iOS 26 does not draw one.
            Text(headerTitle(capture))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RecordSurface.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            if isExpanded { Spacer(minLength: 0) }
            primaryStatus(capture)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecordSurface.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: RecordSurface.motion, extraBounce: 0), value: isExpanded)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if capture.state.isCapturing {
                        confirmingDiscard = true
                    } else {
                        Task { await close(cancelling: true) }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                }
                .tint(RecordSurface.primary)
                .accessibilityLabel("Close")
            }
        }
        .toolbarBackgroundHidden()
        .navigationTitle("")
        .inlineTitle()
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                Task { await close(cancelling: true) }
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The audio so far will be deleted and not saved.")
        }
        .safeAreaInset(edge: .bottom) {
            controls(capture)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .onAppear {
            if startsAutomatically { beginCountdown() }
        }
        .onDisappear { countdownTask?.cancel() }
        .onChange(of: capture.state) { _, state in
            // The recording landed (the root opens it) or the user closed
            // a failure: either way the sheet is done.
            if state == .idle, capture.lastRecordingID != nil, phase == .live { onClose() }
        }
    }

    // MARK: Status

    @ViewBuilder
    private func primaryStatus(_ capture: CaptureController) -> some View {
        switch phase {
        case .countdown(let remaining):
            VStack(spacing: 8) {
                Text("Recording in")
                    .font(.system(size: 18))
                    .foregroundStyle(RecordSurface.secondary)
                Text(String(format: "%02d", remaining))
                    .font(.system(size: 72, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(RecordSurface.primary)
                    .contentTransition(.numericText(value: Double(remaining)))
                    .animation(.smooth(duration: RecordSurface.motion, extraBounce: 0), value: remaining)
                    .accessibilityLabel("Recording starts in \(remaining)")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 144)

        case .live:
            switch capture.state {
            case .transcribing:
                VStack(spacing: 12) {
                    ProgressView().tint(RecordSurface.primary)
                    Text("Transcribing…")
                        .font(.system(size: 18))
                        .foregroundStyle(RecordSurface.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 144)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(RecordSurface.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
            default:
                let seconds = Int(capture.elapsed)
                VStack(spacing: 16) {
                    Text(Format.duration(capture.elapsed))
                        .font(.system(size: isExpanded ? 84 : 56, weight: .bold, design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(RecordSurface.primary)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: Double(seconds)))
                        .animation(.smooth(duration: RecordSurface.motion, extraBounce: 0), value: seconds)

                    VoiceBarsMeter(bands: capture.bands, tint: RecordSurface.primary)
                        .frame(height: isExpanded ? 120 : 72)
                        .padding(.vertical, isExpanded ? 16 : 8)
                        .opacity(capture.state == .recording ? 1 : 0.4)

                    if capture.state == .interrupted {
                        Text("Another app has the microphone.")
                            .font(.footnote)
                            .foregroundStyle(RecordSurface.secondary)
                    }
                }
            }
        }
    }

    private func headerTitle(_ capture: CaptureController) -> String {
        switch (phase, capture.state) {
        case (.countdown, _): return ""
        case (_, .paused), (_, .interrupted): return "Paused"
        case (_, .transcribing): return "Transcribing"
        case (_, .failed): return "Recording"
        default: return "Recording"
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ capture: CaptureController) -> some View {
        switch (phase, capture.state) {
        case (.countdown, _):
            liveControls(capture, disabled: true)
        case (.live, .transcribing):
            Button("Cancel") { Task { await close(cancelling: true) } }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RecordSurface.primary)
                .frame(maxWidth: .infinity, minHeight: RecordSurface.actionHeight)
                .background(RecordSurface.inertFill, in: Capsule(style: .continuous))
                .buttonStyle(.plain)
        case (.live, .failed):
            HStack(spacing: 12) {
                Button("Close") { Task { await close(cancelling: false) } }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(RecordSurface.primary)
                    .frame(maxWidth: .infinity, minHeight: RecordSurface.actionHeight)
                    .background(RecordSurface.inertFill, in: Capsule(style: .continuous))
                    .buttonStyle(.plain)
                Button("Try Again") {
                    capture.dismissFailure()
                    beginCountdown()
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RecordSurface.primary)
                .frame(maxWidth: .infinity, minHeight: RecordSurface.actionHeight)
                .background(RecordSurface.destructive, in: Capsule(style: .continuous))
                .buttonStyle(.plain)
            }
        default:
            liveControls(capture, disabled: false)
        }
    }

    /// Every control here is `actionHeight` tall and draws its own fill, so
    /// the rendered height matches the number rather than a button style's
    /// insets.
    private func liveControls(_ capture: CaptureController, disabled: Bool) -> some View {
        let canPause = capture.state == .recording || capture.state == .paused
        let canStop = capture.state.isCapturing
        return HStack(spacing: 12) {
            iconButton(capture.state == .paused ? "play.fill" : "pause.fill",
                       label: capture.state == .paused ? "Resume" : "Pause",
                       disabled: disabled || !canPause) {
                Task {
                    capture.state == .paused ? await capture.resume() : await capture.pause()
                }
            }

            Button {
                Task { await stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(RecordSurface.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: RecordSurface.actionHeight)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .background(disabled || !canStop ? RecordSurface.inertFill : RecordSurface.destructive,
                        in: Capsule(style: .continuous))
            .disabled(disabled || !canStop)
            .accessibilityLabel("Stop recording")

            iconButton("arrow.counterclockwise", label: "Start again",
                       disabled: disabled || !canStop) {
                Task {
                    await capture.cancel()
                    beginCountdown()
                }
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(disabled ? RecordSurface.tertiary : RecordSurface.primary)
                .frame(maxWidth: .infinity, minHeight: RecordSurface.actionHeight)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RecordSurface.inertFill, in: Capsule(style: .continuous))
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private var isExpanded: Bool { presentationDetent == .large }

    private func beginCountdown() {
        countdownTask?.cancel()
        phase = .countdown(3)
        countdownTask = Task {
            for remaining in [2, 1] {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: RecordSurface.motion, extraBounce: 0)) {
                    phase = .countdown(remaining)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await model.capture.start()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: RecordSurface.motion, extraBounce: 0)) {
                phase = .live
            }
            if model.capture.state == .recording {
                haptic(Haptics.recordStarted)
            } else if case .failed = model.capture.state {
                haptic(Haptics.failure)
            }
        }
    }

    private func stop() async {
        haptic(Haptics.recordStopped)
        await model.capture.stop()
    }

    private func close(cancelling: Bool) async {
        countdownTask?.cancel()
        if cancelling { await model.capture.cancel() } else { model.capture.dismissFailure() }
        onClose()
    }

    private func haptic(_ play: @MainActor () -> Void) {
        guard model.settings.settings.hapticFeedback else { return }
        play()
    }
}

private extension View {
    /// A principal toolbar item only shows in the inline layout.
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The sheet paints its own surface; the bar's glass would sit on top.
    @ViewBuilder
    func toolbarBackgroundHidden() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

/// Six bars that stay where they are and react to the voice: circles at
/// rest, each one rising with the part of the voice it hears. No timeline,
/// nothing scrolls; the meter is a face, not a chart.
struct VoiceBarsMeter: View {
    let bands: [Float]
    var tint: Color = .primary
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
            .animation(.smooth(duration: 0.08), value: bands)
        }
        .accessibilityLabel("Audio level")
    }
}

#Preview("Countdown") {
    NavigationStack {
        RecordView(startsAutomatically: false)
    }
    .environment(AppModel.simulating())
}

#Preview("Recording") {
    let model = AppModel.simulating()
    NavigationStack {
        RecordView()
    }
    .environment(model)
}

#Preview("Paused by a call") {
    let recorder = SimulatedRecorder()
    let model = AppModel.simulating(recorder: recorder)
    NavigationStack {
        RecordView()
    }
    .environment(model)
    .task {
        try? await Task.sleep(for: .seconds(4))
        recorder.simulate(.interrupted)
    }
}

#Preview("Failed") {
    let recorder = SimulatedRecorder(permissionGranted: true,
                                     startError: AudioRecorder.RecorderError.permissionDenied)
    NavigationStack {
        RecordView()
    }
    .environment(AppModel.simulating(recorder: recorder))
}
