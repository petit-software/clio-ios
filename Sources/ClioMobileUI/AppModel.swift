import ClioMobileCore
import ClioMobileSummary
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
    /// Whisper models.
    public let models: ModelManager
    /// Language models for titles and summaries, downloaded.
    public let languageModels: ModelManager
    /// The engine in front of Apple's model and a downloaded one.
    public let summaries: SummaryRouter
    public let intelligence: IntelligenceController
    public let capture: CaptureController

    public init(settings: SettingsStore,
                library: RecordingStore,
                models: ModelManager,
                languageModels: ModelManager,
                recorder: any AudioCapturing,
                engine: any TranscriptionEngine,
                summarizer: any SummaryEngine,
                localSummarizer: (any LocalSummaryEngine)?,
                locations: any LocationProviding = StubLocationProvider()) {
        self.settings = settings
        self.library = library
        self.models = models
        self.languageModels = languageModels
        self.summaries = SummaryRouter(apple: summarizer, local: localSummarizer,
                                       settings: settings, languageModels: languageModels)
        self.intelligence = IntelligenceController(engine: summaries,
                                                   settings: settings,
                                                   library: library)
        self.capture = CaptureController(recorder: recorder,
                                         engine: engine,
                                         models: models,
                                         settings: settings,
                                         library: library,
                                         intelligence: intelligence,
                                         locations: locations)
        // A language model arrived or went: the choice follows, and the
        // Settings footer with it.
        languageModels.onInstalledChanged = { [weak self] in
            guard let self else { return }
            Task { await self.intelligence.refreshAvailability() }
        }
    }

    /// The real thing: WhisperKit on whatever is in the models folder,
    /// Apple's language model where the phone has one, and MLX on a
    /// downloaded one where it does not — or where the user prefers it.
    public static func live() -> AppModel {
        try? AppPaths.ensureDirectories()
        return AppModel(settings: SettingsStore(),
                        library: RecordingStore(),
                        models: ModelManager(),
                        languageModels: .languageModels(),
                        recorder: AudioRecorder(),
                        engine: WhisperKitEngine(),
                        summarizer: SummaryEngines.apple(),
                        localSummarizer: MLXSummaryEngine(),
                        locations: CoreLocationProvider())
    }

    public static func simulating(
        recordings: [Recording] = PreviewData.recordings,
        audio: Bool = false,
        settings: Settings = Settings(),
        models: ModelManager = PreviewData.models(),
        languageModels: ModelManager = .simulating(layout: .languageModel),
        recorder: any AudioCapturing = SimulatedRecorder(),
        engine: any TranscriptionEngine = StubTranscriptionEngine(latency: .milliseconds(300)),
        summarizer: any SummaryEngine = StubSummaryEngine(latency: .seconds(1)),
        localSummarizer: (any LocalSummaryEngine)? = StubLocalSummaryEngine()
    ) -> AppModel {
        AppModel(settings: .simulating(settings),
                 library: audio ? .simulatingWithAudio(recordings) : .simulating(recordings),
                 models: models,
                 languageModels: languageModels,
                 recorder: recorder,
                 engine: engine,
                 summarizer: summarizer,
                 localSummarizer: localSummarizer)
    }

    /// The user picked which model writes summaries. Takes effect on the
    /// next one; the router confirms the pick can run.
    public func select(summaryModel choice: SummaryModelChoice) {
        guard settings.settings.summaryModel != choice else { return }
        settings.settings.summaryModel = choice
        Task { await intelligence.refreshAvailability() }
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
        languageModels.refreshInstalled()
        capture.warmUp()
        Task { await intelligence.refreshAvailability() }
    }
}
