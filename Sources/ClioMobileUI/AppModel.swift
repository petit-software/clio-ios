import ClioMobileCore
import Foundation
import Observation

/// The wiring: every store and service the views reach for, built once.
///
/// `live()` is what the app runs on. `simulating(...)` is what previews and
/// UI tests run on — fixed recordings, a fake microphone, the stub engine,
/// a pretend install, nothing on disk — so a preview shows what it claims
/// regardless of the machine rendering it.
@MainActor
@Observable
public final class AppModel {
    public let settings: SettingsStore
    public let library: RecordingStore
    public let models: ModelManager
    public let intelligence: IntelligenceController
    public let capture: CaptureController

    public init(settings: SettingsStore,
                library: RecordingStore,
                models: ModelManager,
                recorder: any AudioCapturing,
                engine: any TranscriptionEngine,
                summarizer: any SummaryEngine,
                locations: any LocationProviding = StubLocationProvider()) {
        self.settings = settings
        self.library = library
        self.models = models
        self.intelligence = IntelligenceController(engine: summarizer,
                                                   settings: settings,
                                                   library: library)
        self.capture = CaptureController(recorder: recorder,
                                         engine: engine,
                                         models: models,
                                         settings: settings,
                                         library: library,
                                         intelligence: intelligence,
                                         locations: locations)
    }

    /// The real thing: WhisperKit on whatever is in the models folder, and
    /// Apple's language model where the phone has one.
    public static func live() -> AppModel {
        try? AppPaths.ensureDirectories()
        return AppModel(settings: SettingsStore(),
                        library: RecordingStore(),
                        models: ModelManager(),
                        recorder: AudioRecorder(),
                        engine: WhisperKitEngine(),
                        summarizer: SummaryEngines.live(),
                        locations: CoreLocationProvider())
    }

    public static func simulating(
        recordings: [Recording] = PreviewData.recordings,
        audio: Bool = false,
        settings: Settings = Settings(),
        models: ModelManager = PreviewData.models(),
        recorder: any AudioCapturing = SimulatedRecorder(),
        engine: any TranscriptionEngine = StubTranscriptionEngine(latency: .milliseconds(300)),
        summarizer: any SummaryEngine = StubSummaryEngine(latency: .seconds(1))
    ) -> AppModel {
        AppModel(settings: .simulating(settings),
                 library: audio ? .simulatingWithAudio(recordings) : .simulating(recordings),
                 models: models,
                 recorder: recorder,
                 engine: engine,
                 summarizer: summarizer)
    }

    /// The user picked a model. Stored, and the resident one is dropped so
    /// the next transcription loads the pick rather than the old one.
    public func select(model id: String) {
        guard settings.settings.activeModelID != id else { return }
        settings.settings.activeModelID = id
        Task { await capture.unloadModel() }
    }

    /// The app came to the foreground: rescan the models folder (a download
    /// may have finished while the app was suspended), warm the model if
    /// it is meant to be resident, and ask again whether Apple Intelligence
    /// is on — the user may have just come back from turning it on.
    public func becameActive() {
        models.refreshInstalled()
        capture.warmUp()
        Task { await intelligence.refreshAvailability() }
    }
}
