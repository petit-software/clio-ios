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

/// "Record with Clio." From Siri, Shortcuts, Spotlight, the Action button,
/// and the widget's control on the Lock Screen and in Control Center.
/// `openAppWhenRun`: the system brings the app forward first and runs
/// `perform` inside it, where the app has registered a handler that
/// starts the recording. The intent cannot start recording by itself from
/// the background, and the extension has no microphone; iOS does not
/// allow capture there anyway.
///
/// Two answers were tried and failed. `OpenURLIntent(clio://record)` from
/// the app, for Shortcuts, was a second launch of an open app and was
/// refused with "launch is prohibited". The same URL from the extension,
/// for the control, did nothing: a control's open-URL result honours only
/// universal links, never a custom scheme. The flag covers both.
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

/// How `StartRecordingIntent` reaches the app it runs in. The app sets
/// the handler at launch. In the widget extension there is none; the
/// intent's flag has the app opened and `perform` run there instead.
@MainActor
public enum RecordRequests {
    public static var handler: (@MainActor () -> Void)?
}

/// The intents in this module, for the app and the widget extension to
/// list: an App Intent in a package is found by the metadata extractor
/// only when the bundle that ships it names the package.
public struct ClioMobileActivityIntents: AppIntentsPackage {}
