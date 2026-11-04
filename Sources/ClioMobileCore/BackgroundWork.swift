import Foundation
#if os(iOS)
import UIKit
#endif

/// A few more seconds from iOS after the screen locks.
///
/// A transcript is written after the microphone has stopped, and from
/// then on the app is an ordinary app: lock the phone and it is suspended
/// within seconds, mid-word. Asking for a background task buys the
/// standard grace — tens of seconds, iOS decides — which covers a short
/// recording outright and lets a long one get further. What it does not
/// buy is forever; that is why the row is in the library before the model
/// is asked, so a suspension or a kill costs the words, not the audio.
///
/// On the host build there is no UIKit, and nothing to ask.
enum BackgroundWork {
    struct Token {
        #if os(iOS)
        fileprivate let identifier: UIBackgroundTaskIdentifier
        #endif

        @MainActor
        func end() {
            #if os(iOS)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            #endif
        }
    }

    @MainActor
    static func begin(_ name: String) -> Token {
        #if os(iOS)
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name)
        return Token(identifier: identifier)
        #else
        return Token()
        #endif
    }
}
