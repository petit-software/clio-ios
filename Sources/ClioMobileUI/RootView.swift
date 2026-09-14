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
    @State private var activity = RecordingActivityController()
    private let initialScreen: InitialScreen

    public init(initialScreen: InitialScreen = .library) {
        self.initialScreen = initialScreen
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
            RecordingsListView(onRecord: { showingRecorder = true },
                               onSettings: { showingSettings = true })
                .navigationDestination(for: Recording.ID.self) { id in
                    RecordingDetailView(id: id)
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
        .recorderCover(isPresented: $showingRecorder) {
            RecordView { id in
                showingRecorder = false
                if let id { path = [id] }
            }
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

private extension View {
    /// The record screen takes the whole display on a phone. `fullScreenCover`
    /// does not exist on macOS, where the package is also built for tests.
    @ViewBuilder
    func recorderCover<Content: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
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

    @MainActor
    public static func initialScreen(for model: AppModel) -> InitialScreen {
        switch ProcessInfo.processInfo.environment["CLIO_SHOW"] {
        case "record": return .record
        case "settings": return .settings
        case "detail":
            if let first = model.library.recordings.first { return .detail(first.id) }
            return .library
        default: return .library
        }
    }
}
#endif
