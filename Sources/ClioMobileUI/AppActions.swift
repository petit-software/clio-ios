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
