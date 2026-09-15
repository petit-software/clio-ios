import ClioMobileCore
import ClioMobileUI
import SwiftUI

#if os(iOS)
import UIKit

/// One reason to exist: iOS relaunches the app when a background model
/// download finishes while it was not running, and delivers that here.
/// Touching the shared downloader reconnects its session, its delegate
/// moves the file into place, and the completion is called when done.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        let handler: @Sendable () -> Void = { MainActor.assumeIsolated(completionHandler) }
        BackgroundDownloader.shared.backgroundEventsCompletion = handler
    }
}
#endif

@main
struct ClioMobileApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model: AppModel
    private let initialScreen: InitialScreen
    private let homeStyle: HomeStyle
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        let model = LaunchOptions.model()
        initialScreen = LaunchOptions.initialScreen(for: model)
        homeStyle = LaunchOptions.homeStyle
        #else
        let model = AppModel.live()
        initialScreen = .library
        homeStyle = .default
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialScreen: initialScreen, homeStyle: homeStyle)
                .environment(model)
                .preferredColorScheme(model.settings.settings.appearance.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Rescan the models folder and, if the model is meant to
                // stay resident, load it now rather than after "stop".
                model.becameActive()
            case .background:
                // The settings store debounces its writes; going to the
                // background is where a pending one would otherwise be lost.
                model.settings.flush()
            default:
                break
            }
        }
    }
}
