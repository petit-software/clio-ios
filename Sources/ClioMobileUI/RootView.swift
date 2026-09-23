import ClioMobileCore
import SwiftUI

/// What the app opens on. The library, unless a debug switch asks for a
/// screen that is awkward to reach by hand — see `LaunchOptions`.
public enum InitialScreen: Equatable, Sendable {
    case library
    case record
    /// The first-run sheet, over the library.
    case intro
    case settings
    case detail(Recording.ID)
}

/// The one window: the list, and the two things presented over it.
public struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Recording.ID] = []
    /// The Settings sheet, and the page it opens on. By item rather than a
    /// Bool and a separate page: `sheet(isPresented:)` evaluates its
    /// content against state as it was when the sheet went up, and the
    /// page was still nil then — every route landed on the Settings list.
    @State private var settingsSheet: SettingsSheet?
    @State private var showingRecorder = false
    @State private var showingIntro = false
    @State private var recorderDetent: PresentationDetent = .medium
    @State private var activity = RecordingActivityController()
    /// What the library screen reports back: whether it is the one on show,
    /// and whether the search field has it.
    @State private var chrome = HomeChrome()
    /// The recording whose transcript went to the clipboard on landing.
    @State private var autoCopied: Recording.ID?
    private let initialScreen: InitialScreen
    private let homeStyle: HomeStyle

    public init(initialScreen: InitialScreen = .library, homeStyle: HomeStyle = .default) {
        self.initialScreen = initialScreen
        self.homeStyle = homeStyle
        switch initialScreen {
        case .library: break
        case .record: _showingRecorder = State(initialValue: true)
        case .intro: _showingIntro = State(initialValue: true)
        case .settings: _settingsSheet = State(initialValue: SettingsSheet(page: nil))
        case .detail(let id): _path = State(initialValue: [id])
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            stack
                // One layer, not two: the effect sits on the whole stack so
                // the bar, the title, the search field and the rows go back
                // together. Which is why the wash, the button and the clock
                // are here rather than in the list — they have to stay put
                // while everything behind them recedes.
                .receded(held)
                .overlay {
                    if held {
                        Text(Format.duration(model.capture.elapsed))
                            .font(.system(size: 76, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .transition(.opacity.combined(with: .scale(scale: 1.08)))
                            .accessibilityLabel("Recording, \(Format.duration(model.capture.elapsed))")
                    }
                }
                .animation(.smooth(duration: 0.35), value: held)
                .overlay(alignment: .bottom) {
                    if homeStyle == .floating && recordsHere {
                        FloatingRecordPane(onRecord: { showingRecorder = true },
                                           showsButton: !needsModelFirst,
                                           searching: chrome.searching)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
                // Between Stop and the recording opening: the sheet is gone,
                // the hold button has been let go of, and this says what
                // the wait is. The same pill either way, at the bottom,
                // above the record button; it fades and shrinks in place.
                .overlay(alignment: .bottom) {
                    if model.capture.state == .transcribing {
                        Toast("Transcribing") { ProgressView() }
                            .padding(.bottom, ToastLayout.bottomInset(above: proxy.safeAreaInsets.bottom))
                            .transition(ToastLayout.transition)
                    }
                }
                .animation(.smooth(duration: 0.3), value: model.capture.state == .transcribing)
                // Outermost, so the wash and the button read it too.
                .environment(\.safeAreaInsets, proxy.safeAreaInsets)
        }
    }

    /// A held recording is running on the library screen: everything behind
    /// the button goes back and the clock takes the middle.
    private var held: Bool {
        homeStyle == .floating
            && recordsHere
            && model.settings.settings.holdToRecord
            && model.capture.state.isCapturing
    }

    /// The screen on show has the record button: the library, unless rows
    /// are being picked, or a recording, which it records more into.
    private var recordsHere: Bool {
        (chrome.onScreen && !chrome.selecting) || !path.isEmpty
    }

    /// Nothing installed and nothing recorded: the button is left out, and
    /// the wash stays on its own.
    private var needsModelFirst: Bool {
        model.library.recordings.isEmpty && model.models.installed.isEmpty
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            RecordingsListView(style: homeStyle,
                               chrome: $chrome,
                               onRecord: { showingRecorder = true },
                               onOpen: { path = [$0] },
                               onSettings: { settingsSheet = SettingsSheet(page: $0) })
                .navigationDestination(for: Recording.ID.self) { id in
                    RecordingDetailView(id: id, copiedOnArrival: autoCopied == id)
                }
                .toolbar {
                    // Out of the way while rows are being picked: Done has
                    // that end of the bar, and Settings is not what anyone
                    // is reaching for mid-selection.
                    if !chrome.selecting {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Settings", systemImage: "ellipsis") {
                                settingsSheet = SettingsSheet(page: nil)
                            }
                        }
                    }
                }
        }
        .sheet(item: $settingsSheet) { sheet in
            SettingsView(initialPage: sheet.page)
        }
        // The first run, and again from Settings ▸ Developer.
        .sheet(isPresented: $showingIntro, onDismiss: { model.settings.settings.introShown = true }) {
            IntroView { showingIntro = false }
        }
        .onAppear {
            if !model.settings.settings.introShown { showingIntro = true }
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
            // With auto copy on, the transcript is on the clipboard before
            // the recording is on screen, and the detail says so.
            if model.settings.settings.autoCopyTranscript,
               let transcript = model.library[id]?.transcript, !transcript.isEmpty {
                Clipboard.copy(transcript)
                autoCopied = id
            } else {
                autoCopied = nil
            }
            showingRecorder = false
            settingsSheet = nil
            path = [id]
        }
        // On a recording, the button records into it; on the library, a
        // recording of its own.
        .onChange(of: path, initial: true) { _, path in
            model.capture.appendTarget = path.last
        }
        .onChange(of: model.capture.state, initial: true) { _, state in
            activity.update(for: state, maxSeconds: model.capture.maxSeconds)
        }
        .onChange(of: AppActions.shared.pending, initial: true) { _, action in
            guard let action else { return }
            AppActions.shared.pending = nil
            switch action {
            case .showIntro:
                settingsSheet = nil
                // The Settings sheet has to be down before another goes up.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    showingIntro = true
                }
            case .record:
                settingsSheet = nil
                path = []
                showingRecorder = true
            }
        }
    }
}

private extension View {
    /// Back and away: smaller, blurred and gone, one animation over one
    /// layer, rather than a bar leaving on its own while the list shrinks.
    func receded(_ receded: Bool) -> some View {
        scaleEffect(receded ? 0.9 : 1)
            .blur(radius: receded ? 16 : 0)
            .opacity(receded ? 0 : 1)
            .allowsHitTesting(!receded)
    }
}

/// Which Settings sheet is up: the list, or one of its pages directly.
private struct SettingsSheet: Identifiable {
    var page: SettingsPage?
    var id: String { page.map(String.init(describing:)) ?? "settings" }
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
///     SIMCTL_CHILD_CLIO_SIMULATE=1 SIMCTL_CHILD_CLIO_SHOW=detail \
///         xcrun simctl launch --terminate-running-process <udid> com.bartbak.clio.ios
///
/// `simctl launch` has no `-e`: anything after the bundle id is argv, and
/// the prefix is how the environment reaches the app.
///
/// `CLIO_SIMULATE=1` runs the app on simulated dependencies — fixed
/// recordings with synthesized audio in a temporary folder, a fake
/// microphone, the stub engine, nothing else on disk — and `CLIO_SHOW` is
/// one of `record`, `settings`, `detail`. `CLIO_HOLD=1` turns on hold to
/// record. `CLIO_AUTOPLAY=1` starts playback
/// when the detail view appears, so the seek highlight can be seen without
/// a tap. The Mac app has the same kind of switches for its overlay and
/// settings, for the same reason: a screen nobody has looked at is a
/// screen that is wrong.
public enum LaunchOptions {
    @MainActor
    public static func model() -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        let simulate = environment["CLIO_SIMULATE"]
        guard simulate == "1" || simulate == "mic" else { return AppModel.live() }
        // `CLIO_STUB_LATENCY=3` makes the stub take three seconds, long
        // enough to look at the transcribing state. `CLIO_EMPTY=1` is a
        // fresh install: no recordings, no model. `CLIO_SIMULATE=mic` is
        // the real microphone with everything else simulated — an empty
        // library, a model "installed", the stub engine — so the UI test
        // records for real without depending on a download.
        let seconds = environment["CLIO_STUB_LATENCY"].flatMap(Double.init) ?? 0.3
        let empty = environment["CLIO_EMPTY"] == "1"
        let mic = simulate == "mic"
        // Seen already, unless the intro is the screen being looked at.
        var settings = Settings()
        settings.introShown = environment["CLIO_SHOW"] != "intro"
        // `CLIO_HOLD=1` starts with "Hold to record" on, so the held
        // recording — the screen receding, the clock, the wash at full
        // height — can be reached without a trip through Settings.
        settings.holdToRecord = environment["CLIO_HOLD"] == "1"
        return AppModel.simulating(
            recordings: empty || mic ? [] : PreviewData.recordings,
            // The audio store is a real folder, so a real recording's WAV
            // has somewhere to land.
            audio: true,
            settings: settings,
            models: PreviewData.models(installed: empty ? [] : [ModelManager.simulatedInstalled()]),
            recorder: mic ? AudioRecorder() : SimulatedRecorder(),
            engine: StubTranscriptionEngine(latency: .seconds(seconds)))
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
        case "intro": return .intro
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
