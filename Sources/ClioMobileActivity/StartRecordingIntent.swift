import AppIntents
import Foundation

/// Where the app can be sent from outside: one URL, one scheme, read by
/// the root view. Registered in the app's Info.plist (`CFBundleURLTypes`).
public enum ClioLinks {
    public static let scheme = "clio"
    /// Open the app and start recording.
    public static let record = URL(string: "clio://record")!

    public static func isRecord(_ url: URL) -> Bool {
        url.scheme == scheme && url.host() == "record"
    }
}

/// "Record with Clio." From Siri, Shortcuts, Spotlight and the Action
/// button. `openAppWhenRun`: the system brings the app forward first and
/// runs `perform` inside it, where the app has registered a handler that
/// starts the recording. It cannot start recording by itself from the
/// background; iOS does not allow an app to begin capturing audio there.
///
/// It once answered with `OpenURLIntent(clio://record)` instead, the same
/// as the control below. Inside the app that is a second launch of an app
/// already open, and Shortcuts refused it with "launch is prohibited"
/// after Clio had come forward, so no recording started. The URL is for
/// the extension, which has nothing else.
public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription("Opens Clio and starts a new recording.")
    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordRequests.handler?()
        return .result()
    }
}

/// The widget's control: "Record" on the Lock Screen, in Control Center
/// and on the Action button's control list. It runs in the extension,
/// which has no microphone and no view of the app, so it opens the app on
/// its record URL and the root view starts recording as the app comes
/// forward (unlocked first, if the phone was locked). Not offered in
/// Shortcuts: `StartRecordingIntent` is the one for that.
public struct RecordControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Clio to Record"
    public static let description = IntentDescription("Opens Clio and starts a new recording.")
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ClioLinks.record))
    }
}

/// How `StartRecordingIntent` reaches the app it runs in. The app sets
/// the handler at launch; in the widget extension there is none, and the
/// intent is not used there.
@MainActor
public enum RecordRequests {
    public static var handler: (@MainActor () -> Void)?
}

/// The intents in this module, for the app and the widget extension to
/// list: an App Intent in a package is found by the metadata extractor
/// only when the bundle that ships it names the package.
public struct ClioMobileActivityIntents: AppIntentsPackage {}
