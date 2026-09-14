import ClioMobileCore
import Foundation

#if os(iOS)
import ActivityKit
import ClioMobileActivity
#endif

/// Starts and ends the Live Activity as the capture state moves.
///
/// One activity at a time, ended the moment capture stops — a Lock Screen
/// that still says "Recording" after the app has stopped listening is a
/// lie, and a bad one. Where ActivityKit does not exist (the host build
/// for tests) every call is a no-op.
@MainActor
final class RecordingActivityController {
    private var startedAt: Date?

    #if os(iOS)
    private var activity: Activity<RecordingActivityAttributes>?
    #endif

    func update(for state: CaptureState, maxSeconds: Double) {
        switch state {
        case .recording:
            startedAt == nil ? start(maxSeconds: maxSeconds) : setPaused(false)
        case .interrupted:
            setPaused(true)
        case .idle, .starting, .transcribing, .failed:
            end()
        }
    }

    private func start(maxSeconds: Double) {
        let now = Date()
        startedAt = now
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = RecordingActivityAttributes(maxSeconds: maxSeconds)
        let content = ActivityContent(
            state: RecordingActivityAttributes.ContentState(startedAt: now),
            staleDate: now.addingTimeInterval(maxSeconds + 60))
        activity = try? Activity.request(attributes: attributes, content: content)
        #endif
    }

    private func setPaused(_ paused: Bool) {
        #if os(iOS)
        guard let current = activity, let startedAt else { return }
        let state = RecordingActivityAttributes.ContentState(startedAt: startedAt, isPaused: paused)
        // `Activity` is not Sendable and its async methods run off-actor.
        // Only this class ever holds it, and only on the main actor, so
        // handing it to the call is safe; the compiler cannot see that.
        nonisolated(unsafe) let activity = current
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        #endif
    }

    private func end() {
        guard startedAt != nil else { return }
        startedAt = nil
        #if os(iOS)
        guard let current = activity else { return }
        self.activity = nil
        nonisolated(unsafe) let activity = current
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
