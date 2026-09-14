import ClioMobileCore
import SwiftUI

/// The record screen: elapsed time, the meter, the cap, stop or cancel.
///
/// Presented full screen and starts the microphone as soon as it appears.
/// When the transcript is in, it hands the new recording's id back and the
/// root opens it.
struct RecordView: View {
    @Environment(AppModel.self) private var model
    /// Called once, with the recording's id, or nil if cancelled.
    var onFinished: (Recording.ID?) -> Void

    var body: some View {
        let capture = model.capture
        VStack(spacing: 32) {
            Spacer()

            Text(Format.duration(capture.elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("Elapsed \(Format.duration(capture.elapsed))")

            LevelMeter(level: capture.level, active: capture.state.isCapturing)
                .frame(height: 96)
                .padding(.horizontal, 32)

            statusLine(capture)

            Spacer()

            controls(capture)
                .padding(.bottom, 48)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(capture.state.isBusy)
        .task { await start() }
        .onChange(of: capture.state) { _, state in
            if state == .idle, let id = capture.lastRecordingID {
                onFinished(id)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ capture: CaptureController) -> some View {
        switch capture.state {
        case .starting:
            Label("Starting the microphone…", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            VStack(spacing: 6) {
                Label("Listening", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("Up to \(RecordingLimit.label(seconds: capture.maxSeconds))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .interrupted:
            VStack(spacing: 6) {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Text("Another app has the microphone. Recording resumes when it lets go, "
                     + "or stop now to keep what you have.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Transcribing…")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func controls(_ capture: CaptureController) -> some View {
        switch capture.state {
        case .starting, .recording, .interrupted:
            HStack(spacing: 48) {
                Button("Cancel", systemImage: "xmark") {
                    Task { await cancel() }
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 56, height: 56)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)

                Button {
                    Task { await stop() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 34))
                        .frame(width: 88, height: 88)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
                .disabled(!capture.state.isCapturing)
                .accessibilityLabel("Stop recording")

                // Keeps the stop button centred.
                Color.clear.frame(width: 56, height: 56)
            }
        case .transcribing:
            Button("Cancel", role: .cancel) {
                Task { await cancel() }
            }
            .buttonStyle(.bordered)
        case .failed:
            HStack(spacing: 16) {
                Button("Close") {
                    capture.dismissFailure()
                    onFinished(nil)
                }
                .buttonStyle(.bordered)
                Button("Try Again") {
                    capture.dismissFailure()
                    Task { await start() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .idle:
            EmptyView()
        }
    }

    private func start() async {
        await model.capture.start()
        if model.capture.state == .recording {
            haptic(Haptics.recordStarted)
        } else if case .failed = model.capture.state {
            haptic(Haptics.failure)
        }
    }

    private func stop() async {
        haptic(Haptics.recordStopped)
        await model.capture.stop()
    }

    /// Settings ▸ Recording ▸ Haptic feedback.
    private func haptic(_ play: @MainActor () -> Void) {
        guard model.settings.settings.hapticFeedback else { return }
        play()
    }

    private func cancel() async {
        await model.capture.cancel()
        onFinished(nil)
    }
}

/// A row of bars that follow the level. One number in, so the bars share
/// one envelope and differ only in their height — no per-band analysis
/// yet; see docs/plan.md, "Open".
struct LevelMeter: View {
    var level: Float
    var active: Bool
    private let bars = 21

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(active ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: height(at: index))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        // A bell across the row, so the middle bars lead and the ends
        // follow, as a voice meter is expected to look.
        let center = Double(bars - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1 - 0.7 * distance * distance
        let floor: CGFloat = 8
        return floor + CGFloat(Double(level) * envelope) * 80
    }
}

#Preview("Recording") {
    RecordView(onFinished: { _ in })
        .environment(AppModel.simulating())
}

#Preview("Paused by a call") {
    let recorder = SimulatedRecorder()
    let model = AppModel.simulating(recorder: recorder)
    RecordView(onFinished: { _ in })
        .environment(model)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            recorder.simulate(.interrupted)
        }
}

#Preview("Failed") {
    let recorder = SimulatedRecorder(permissionGranted: true,
                                     startError: AudioRecorder.RecorderError.permissionDenied)
    RecordView(onFinished: { _ in })
        .environment(AppModel.simulating(recorder: recorder))
}
