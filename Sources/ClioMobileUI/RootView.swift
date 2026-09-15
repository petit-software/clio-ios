import ClioMobileCore
import SwiftUI

/// What the app opens on. The library, unless a debug switch asks for a
/// screen that is awkward to reach by hand — see `LaunchOptions`.
public enum InitialScreen: Equatable, Sendable {
    case library
    case record
    case settings
    case detail(Recording.ID)
}

/// The one window: the list, and the two things presented over it.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Recording.ID] = []
    @State private var showingSettings = false
    @State private var showingRecorder = false
    @State private var recorderDetent: PresentationDetent = .medium
    @State private var activity = RecordingActivityController()
    /// Shared by a row and its detail, so the detail zooms out of the row.
    @Namespace private var zoom
    private let initialScreen: InitialScreen
    private let homeStyle: HomeStyle

    public init(initialScreen: InitialScreen = .library, homeStyle: HomeStyle = .default) {
        self.initialScreen = initialScreen
        self.homeStyle = homeStyle
        switch initialScreen {
        case .library: break
        case .record: _showingRecorder = State(initialValue: true)
        case .settings: _showingSettings = State(initialValue: true)
        case .detail(let id): _path = State(initialValue: [id])
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            stack.environment(\.safeAreaInsets, proxy.safeAreaInsets)
        }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            RecordingsListView(style: homeStyle,
                               zoom: zoom,
                               onRecord: { showingRecorder = true },
                               onSettings: { showingSettings = true })
                .navigationDestination(for: Recording.ID.self) { id in
                    RecordingDetailView(id: id)
                        .navigationTransition(.zoom(sourceID: id, in: zoom))
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingRecorder, onDismiss: { recorderDetent = .medium }) {
            NavigationStack {
                RecordView(presentationDetent: $recorderDetent) {
                    showingRecorder = false
                }
            }
            .presentationDetents([.medium, .large], selection: $recorderDetent)
            .presentationBackground(RecordSurface.background)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .onChange(of: model.capture.lastRecordingID) { _, id in
            // A recording landed — from the sheet or from holding the
            // button. Either way, it opens.
            guard let id else { return }
            showingRecorder = false
            showingSettings = false
            path = [id]
        }
        .onChange(of: model.capture.state, initial: true) { _, state in
            activity.update(for: state, maxSeconds: model.capture.maxSeconds)
        }
        .onChange(of: AppActions.shared.pending, initial: true) { _, action in
            guard let action else { return }
            AppActions.shared.pending = nil
            switch action {
            case .record:
                showingSettings = false
                path = []
                showingRecorder = true
            }
        }
    }
}

#Preview("Library") {
    RootView().environment(AppModel.simulating())
}

#Preview("Empty") {
    RootView().environment(AppModel.simulating(recordings: []))
}

#if DEBUG
/// Debug switches, read from the environment at launch, so any screen can
/// be put on a simulator without tapping through to it:
///
///     xcrun simctl launch --terminate-running-process <udid> com.bartbak.clio.ios \
///         -e CLIO_SIMULATE=1 -e CLIO_SHOW=detail
///
/// `CLIO_SIMULATE=1` runs the app on simulated dependencies — fixed
/// recordings with synthesized audio in a temporary folder, a fake
/// microphone, the stub engine, nothing else on disk — and `CLIO_SHOW` is
/// one of `record`, `settings`, `detail`. `CLIO_AUTOPLAY=1` starts playback
/// when the detail view appears, so the seek highlight can be seen without
/// a tap. The Mac app has the same kind of switches for its overlay and
/// settings, for the same reason: a screen nobody has looked at is a
/// screen that is wrong.
public enum LaunchOptions {
    @MainActor
    public static func model() -> AppModel {
        ProcessInfo.processInfo.environment["CLIO_SIMULATE"] == "1"
            ? AppModel.simulating(audio: true)
            : AppModel.live()
    }

    public static var autoplay: Bool {
        ProcessInfo.processInfo.environment["CLIO_AUTOPLAY"] == "1"
    }

    /// `CLIO_HOME=pane` or `floating`; the default otherwise.
    public static var homeStyle: HomeStyle {
        ProcessInfo.processInfo.environment["CLIO_HOME"].flatMap(HomeStyle.init(rawValue:))
            ?? .default
    }

    @MainActor
    public static func initialScreen(for model: AppModel) -> InitialScreen {
        switch ProcessInfo.processInfo.environment["CLIO_SHOW"] {
        case "record": return .record
        case "hold":
            // Hold to record, mid-hold: the wash swelling with the voice.
            model.settings.settings.holdToRecord = true
            Task { await model.capture.start() }
            return .library
        case "settings": return .settings
        case "detail":
            if let first = model.library.recordings.first { return .detail(first.id) }
            return .library
        default: return .library
        }
    }
}
#endif
