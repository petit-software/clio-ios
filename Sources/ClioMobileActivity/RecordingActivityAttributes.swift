#if os(iOS)
import ActivityKit
import Foundation

/// What the Live Activity knows about a recording in progress.
///
/// Its own tiny module because both the app and the widget extension
/// need the type, and the extension must not drag WhisperKit in with it.
public struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// When capture started, for the running clock.
        public var startedAt: Date
        /// A call or another app has the microphone.
        public var isPaused: Bool

        public init(startedAt: Date, isPaused: Bool = false) {
            self.startedAt = startedAt
            self.isPaused = isPaused
        }
    }

    /// The cap, so the clock can count within it.
    public var maxSeconds: Double

    public init(maxSeconds: Double) {
        self.maxSeconds = maxSeconds
    }
}
#endif
