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
/// and the Lock Screen and Control Center control in the widget extension.
///
/// Here, in the module both the app and the widget link, so the control
/// can name it. Wherever it runs — in the app for Siri and the Action
/// button, in the extension for the control — it does the same thing:
/// opens the app on its record URL, and the root view starts recording.
///
/// It cannot start recording by itself. iOS does not let an app begin
/// capturing audio from the background, and a control's intent runs in the
/// extension, which has no microphone at all. So the honest result is
/// "opening Clio to record": the app comes forward (unlocked first, if the
/// phone was locked), the record sheet appears, and the microphone starts
/// — there is no step for the user but the unlock.
public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription("Opens Clio and starts a new recording.")
    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ClioLinks.record))
    }
}

/// The intents in this module, for the app and the widget extension to
/// list: an App Intent in a package is found by the metadata extractor
/// only when the bundle that ships it names the package.
public struct ClioMobileActivityIntents: AppIntentsPackage {}
