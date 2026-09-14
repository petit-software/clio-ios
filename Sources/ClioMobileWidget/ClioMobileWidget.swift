import ActivityKit
import ClioMobileActivity
import SwiftUI
import WidgetKit

/// The recording, on the Lock Screen and in the Dynamic Island while the
/// app is in the background. A running clock and a red dot; tapping it
/// opens the app, where the stop button is.
@main
struct ClioMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingActivity()
    }
}

struct RecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // Lock Screen and banner.
            HStack(spacing: 12) {
                RecordingDot(paused: context.state.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isPaused ? "Paused" : "Recording")
                        .font(.headline)
                    Text("Clio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RecordingClock(state: context.state)
                    .font(.title2.weight(.medium))
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        RecordingDot(paused: context.state.isPaused)
                        Text(context.state.isPaused ? "Paused" : "Recording")
                            .font(.headline)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingClock(state: context.state)
                        .font(.title3.weight(.medium))
                        .padding(.trailing, 4)
                }
            } compactLeading: {
                RecordingDot(paused: context.state.isPaused)
            } compactTrailing: {
                RecordingClock(state: context.state)
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: 52)
            } minimal: {
                RecordingDot(paused: context.state.isPaused)
            }
        }
    }
}

private struct RecordingDot: View {
    let paused: Bool

    var body: some View {
        Image(systemName: paused ? "pause.circle.fill" : "circle.fill")
            .foregroundStyle(paused ? Color.orange : Color.red)
            .font(.system(size: 14))
            .accessibilityLabel(paused ? "Paused" : "Recording")
    }
}

/// The elapsed time, counted by the system so the activity needs no
/// updates while it runs. Frozen at the moment it paused.
private struct RecordingClock: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(Duration.seconds(Date.now.timeIntervalSince(state.startedAt)),
                 format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture,
                 countsDown: false, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
