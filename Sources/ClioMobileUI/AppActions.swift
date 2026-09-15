import AppIntents
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

/// "Record with Clio." Opens the app straight onto the record screen, so
/// the Action button can start a memo without a tap in between.
public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription("Starts a new recording in Clio.")
    public static let openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppActions.shared.pending = .record
        return .result()
    }
}

/// What Siri and Spotlight offer without setup. The phrases must name the
/// app, which is what `applicationName` stands for.
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
