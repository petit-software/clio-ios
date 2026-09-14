import ClioMobileUI
import SwiftUI

@main
struct ClioMobileApp: App {
    @State private var model: AppModel
    private let initialScreen: InitialScreen
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        let model = LaunchOptions.model()
        initialScreen = LaunchOptions.initialScreen(for: model)
        #else
        let model = AppModel.live()
        initialScreen = .library
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialScreen: initialScreen)
                .environment(model)
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
