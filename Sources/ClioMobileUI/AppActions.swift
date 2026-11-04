import AppIntents
import ClioMobileActivity
import Foundation
import Observation

/// Things asked of the app from outside a view: Siri, Shortcuts, the
/// Action button. The intent sets one; the root view carries it out and
/// clears it. Observable so the root reacts, one slot so a second ask
/// before the first is handled just replaces it.
@MainActor
@Observable
public final class AppActions {
    public static let shared = AppActions()

    public enum Action: Sendable, Equatable {
        case record
        /// Settings ▸ Developer: the first-run sheet again.
        case showIntro
    }

    public var pending: Action?

    private init() {}
}

/// What Siri and Spotlight offer without setup. The phrases must name the
/// app, which is what `applicationName` stands for. The intent itself is
/// `StartRecordingIntent` in ClioMobileActivity, shared with the widget's
/// control; this provider has to live in the app.
public struct ClioShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Start a \(.applicationName) recording",
                "New \(.applicationName) recording",
            ],
            shortTitle: "Record",
            systemImageName: "mic.fill")
    }
}
