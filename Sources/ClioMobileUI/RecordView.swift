import ClioMobileCore
import SwiftUI

/// The record sheet: what is happening, the clock, the meter, pause and
/// stop. A plain system sheet at medium height — the presentation Settings
/// and the intro use — on the system background with system buttons, in
/// whichever appearance the phone is in. Recording starts as the sheet
/// appears; Stop closes it, and the transcript is written behind the list.
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
    /// Called when the sheet should go: cancelled, closed after a failure,
    /// or the recording stopped. The root opens a recording that lands.
    private let onClose: () -> Void

    init(startsAutomatically: Bool = true, onClose: @escaping () -> Void = {}) {
        self.startsAutomatically = startsAutomatically
        self.onClose = onClose
    }

    var body: some View {
        let capture = model.capture
        NavigationStack {
            VStack(spacing: 20) {
                status(capture)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                clock(capture)
                VoiceBarsMeter(bands: capture.bands, reduceMotion: reduceMotion)
                    .frame(height: 64)
                    .padding(.horizontal, 32)
                    .opacity(capture.state == .recording ? 1 : 0.35)
                    .animation(.default, value: capture.state == .recording)
                Spacer(minLength: 0)
                controls(capture)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .navigationTitle(title(capture))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if capture.state.isCapturing {
                            confirmingDiscard = true
                        } else {
                            Task { await close(cancelling: true) }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // A swipe down must not throw a recording away. Cancel asks first.
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

    @ViewBuilder
    private func status(_ capture: CaptureController) -> some View {
        switch capture.state {
        case .starting:
            Label("Starting…", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Label {
                Text("Recording")
            } icon: {
                RecordingDot(pulsing: !reduceMotion)
            }
        case .paused:
            Label("Paused", systemImage: "pause.fill")
                .foregroundStyle(.secondary)
        case .interrupted:
            Label("Paused. Another app has the microphone.", systemImage: "pause.fill")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .idle, .transcribing:
            Label("Recording", systemImage: "mic")
                .hidden()
        }
    }

    private func clock(_ capture: CaptureController) -> some View {
        let seconds = Int(capture.elapsed)
        return VStack(spacing: 6) {
            Text(Format.duration(capture.elapsed))
                .font(.system(size: clockSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(seconds)))
                .animation(reduceMotion ? nil : .default, value: seconds)
            Text("Stops at \(RecordingLimit.label(seconds: capture.maxSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
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

    private func title(_ capture: CaptureController) -> String {
        switch capture.state {
        case .failed: return "Recording"
        default: return capture.appendingTo == nil ? "New Recording" : "Adding to Recording"
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ capture: CaptureController) -> some View {
        switch capture.state {
        case .failed:
            HStack(spacing: 12) {
                Button("Close") { Task { await close(cancelling: false) } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Try Again") {
                    capture.dismissFailure()
                    Task { await begin() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        default:
            let paused = capture.state == .paused
            HStack(spacing: 12) {
                Button(paused ? "Resume" : "Pause",
                       systemImage: paused ? "play.fill" : "pause.fill") {
                    Task { paused ? await capture.resume() : await capture.pause() }
                }
                .buttonStyle(.bordered)
                .disabled(!(capture.state == .recording || paused))

                Button("Stop", systemImage: "stop.fill") {
                    Task { await stop() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(!capture.state.isCapturing)
                .accessibilityLabel("Stop recording")
            }
            .controlSize(.large)
        }
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

private extension View {
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
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
