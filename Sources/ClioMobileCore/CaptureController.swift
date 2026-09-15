import Foundation
import Observation

/// The state machine for one recording.
///
/// ```
/// idle ──record──▶ recording ──stop──▶ transcribing ──▶ idle (+ a Recording in the store)
///   ▲                  │  ▲                 │
///   │           call   │  │ call ended      │
///   │                  ▼  │                 │
///   │              interrupted ──stop───────┤
///   └───── cancel ─────┴──── cancel ────────┘
/// ```
public enum CaptureState: Sendable, Equatable {
    case idle
    case starting
    case recording
    /// A call, Siri, or another app has the microphone. Nothing is being
    /// captured; the recording resumes when they let go, or stops here.
    case interrupted
    /// The user pressed pause. Resumes on their say-so.
    case paused
    case transcribing
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .starting, .recording, .interrupted, .paused, .transcribing: return true
        case .idle, .failed: return false
        }
    }

    /// Recording, or paused mid-recording: the stop button applies.
    public var isCapturing: Bool {
        self == .recording || self == .interrupted || self == .paused
    }

    public var label: String {
        switch self {
        case .idle: return ""
        case .starting: return "Starting…"
        case .recording: return "Listening"
        case .interrupted, .paused: return "Paused"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return message
        }
    }
}

/// Drives a recording from the tap on the button to the row in the list.
///
/// Owns nothing it cannot be handed: the recorder, the engine, the model
/// manager and the stores are injected, which is what lets the tests run
/// the whole loop on a simulated microphone and the stub engine, and lets
/// previews show every state without touching hardware.
@MainActor
@Observable
public final class CaptureController {

    public private(set) var state: CaptureState = .idle
    /// 0…1, for the meter. Polled from the recorder ~30×/s while recording.
    public private(set) var level: Float = 0
    /// Six bars, 0…1 each, polled with the level. See `MeterAnalyzer`.
    public private(set) var bands: [Float] = Array(repeating: 0, count: MeterAnalyzer.barCount)
    public private(set) var elapsed: TimeInterval = 0
    /// The recording most recently added, so the UI can open it.
    public private(set) var lastRecordingID: Recording.ID?

    public let recorder: any AudioCapturing
    public let engine: any TranscriptionEngine
    public let models: ModelManager
    public let settings: SettingsStore
    public let library: RecordingStore
    /// Told about every transcript that lands, so a title and summary can
    /// follow. Optional: the loop is complete without it.
    public let intelligence: IntelligenceController?
    /// Asked for a fix when a recording starts and the setting is on.
    public let locations: any LocationProviding

    private var pollTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var locationTask: Task<RecordingLocation?, Never>?
    /// For the capture in progress: a result with no speech in it is
    /// thrown away rather than saved as "nothing heard". Hold to record
    /// asks for this — a brush of the button must not leave a row behind.
    private var discardSilence = false

    public init(recorder: any AudioCapturing,
                engine: any TranscriptionEngine,
                models: ModelManager,
                settings: SettingsStore,
                library: RecordingStore,
                intelligence: IntelligenceController? = nil,
                locations: any LocationProviding = StubLocationProvider()) {
        self.recorder = recorder
        self.engine = engine
        self.models = models
        self.settings = settings
        self.library = library
        self.intelligence = intelligence
        self.locations = locations
        models.onInstalledChanged = { [weak self] in self?.reconcileActiveModel() }
        reconcileActiveModel()
        recorder.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in await self?.handle(event) }
        }
    }

    // MARK: System events

    /// The microphone was taken away, or given back. See `CaptureEvent`.
    private func handle(_ event: CaptureEvent) async {
        switch (event, state) {
        case (.interrupted, .recording):
            state = .interrupted
        case (.interruptionEnded(resumed: true), .interrupted):
            state = .recording
        case (.interruptionEnded(resumed: false), .interrupted),
             (.lost, .recording), (.lost, .interrupted):
            // What was captured is kept and transcribed; there will be no
            // more.
            await stop()
        default:
            break
        }
    }

    public var maxSeconds: Double { settings.settings.maxRecordingSeconds }

    // MARK: Model

    /// What a recording with no model to transcribe it is marked with. The
    /// audio is kept; "Transcribe Again" picks it up once one is installed.
    public static let noModelMessage =
        "No model installed. Download one in Settings ▸ Model."

    /// The model transcription will use. Nil means nothing is installed.
    public var activeModel: InstalledModel? {
        models.installedModel(id: settings.settings.activeModelID)
            ?? models.installed.first
    }

    /// Keep the stored selection pointing at a model that is actually there.
    ///
    /// `activeModel` already falls back to the first installed model, so
    /// transcription would work with no selection stored — but Settings
    /// reads the stored value and would show nothing selected. This writes
    /// the fallback down so the two agree, and covers the selection going
    /// stale when the active model is deleted.
    public func reconcileActiveModel() {
        let stored = settings.settings.activeModelID
        if let stored, models.isInstalled(stored) { return }
        let replacement = models.installed.first?.id
        guard replacement != stored else { return }
        settings.settings.activeModelID = replacement
    }

    /// Load the active model now, if the user wants it resident.
    ///
    /// Called when the app becomes active. A cold load is what dominates
    /// the wait after "stop"; this moves it to a moment nobody is waiting.
    /// Failures are swallowed on purpose — the transcription path loads
    /// again and reports properly.
    public func warmUp() {
        guard settings.settings.keepModelInMemory, let model = activeModel else { return }
        Task { [engine] in try? await engine.load(model: model) }
    }

    /// Drop the model from memory. Selecting a different one calls this so
    /// the next transcription loads the new selection rather than reusing
    /// the old.
    public func unloadModel() async {
        await engine.unload()
    }

    // MARK: Record

    public func start(discardingSilence: Bool = false) async {
        guard !state.isBusy else { return }
        discardSilence = discardingSilence
        state = .starting
        level = 0
        elapsed = 0
        do {
            try await recorder.start(maxSeconds: maxSeconds)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // A cancel can land while the hardware was starting.
        guard state == .starting else { return }
        state = .recording
        // The fix is fetched while the user talks, so it is there by the
        // time the recording is; a slow one is waited for at the end.
        if settings.settings.includeLocation {
            let locations = self.locations
            locationTask = Task { await locations.currentLocation() }
        }
        startPolling()

        // Warm the model while the user is still talking, whether or not it
        // is kept resident afterwards: the load overlaps with the recording
        // instead of following it.
        if let model = activeModel {
            Task { [engine] in try? await engine.load(model: model) }
        }
    }

    /// Hold the recording where it is. The elapsed time stops with it.
    public func pause() async {
        guard state == .recording else { return }
        await recorder.pause()
        state = .paused
    }

    public func resume() async {
        guard state == .paused else { return }
        do {
            try await recorder.resume()
            state = .recording
        } catch {
            // What was captured is kept and transcribed.
            await stop()
        }
    }

    public func stop() async {
        guard state.isCapturing else { return }
        stopPolling()
        state = .transcribing
        let result = await recorder.stop()
        elapsed = result.duration
        await finish(result)
    }

    public func cancel() async {
        switch state {
        case .starting, .recording, .interrupted, .paused:
            stopPolling()
            locationTask?.cancel()
            locationTask = nil
            await recorder.cancel()
            state = .idle
        case .transcribing:
            transcribeTask?.cancel()
            transcribeTask = nil
            state = .idle
        case .idle, .failed:
            state = .idle
        }
        level = 0
        elapsed = 0
    }

    /// Clears a failure so the button is a record button again.
    public func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: Transcribe

    private func finish(_ result: CaptureResult) async {
        let id = UUID()
        let audioURL = library.newAudioURL(for: id)

        // The audio is saved before anything else can go wrong. A transcript
        // that fails can be retried; a recording that was never written is
        // gone.
        do {
            try AudioFiles.write(result.samples, to: audioURL)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        var recording = Recording(id: id,
                                  duration: result.duration,
                                  audioFileName: audioURL.lastPathComponent,
                                  status: .pending)
        recording.location = await locationTask?.value
        locationTask = nil

        guard !result.samples.isEmpty else {
            recording.status = .nothingHeard
            if discardSilence {
                discard(audioURL)
            } else {
                library.add(recording)
                lastRecordingID = id
            }
            state = .idle
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.transcribe(result.samples, into: &recording)
            guard !Task.isCancelled else { return }
            if self.discardSilence, recording.status == .nothingHeard {
                self.discard(audioURL)
                self.state = .idle
                return
            }
            self.library.add(recording)
            self.lastRecordingID = recording.id
            self.state = .idle
            self.intelligence?.summarizeIfEnabled(recording.id)
        }
        transcribeTask = task
        await task.value
        transcribeTask = nil
    }

    /// A capture with nothing in it, gone as if it never happened.
    private func discard(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL)
    }

    /// Transcribe an existing recording again — after a failure, or with a
    /// different model.
    public func retranscribe(_ id: Recording.ID) async {
        guard !state.isBusy, var recording = library[id] else { return }
        state = .transcribing
        do {
            let samples = try AudioFiles.read(library.audioURL(for: recording))
            await transcribe(samples, into: &recording)
        } catch {
            recording.status = .failed(error.localizedDescription)
        }
        library.update(recording)
        state = .idle
        intelligence?.summarizeIfEnabled(recording.id)
    }

    /// Trim, load, transcribe, format. Writes the outcome into the recording
    /// and never throws: whatever went wrong is the recording's status.
    private func transcribe(_ captured: [Float], into recording: inout Recording) async {
        let current = settings.settings

        guard let model = activeModel else {
            recording.status = .failed(Self.noModelMessage)
            return
        }

        // Trim silence before handing it over. Whisper pads every clip to a
        // 30-second window, and hallucinates words over silence; cutting the
        // quiet at either end is both a speed and a quality fix.
        var samples = captured
        // Segment times come back relative to what the engine heard; the
        // file on disk still has the silence in front.
        var leadingOffset: TimeInterval = 0
        if current.voiceActivityDetection {
            guard let trimmed = VoiceActivityTrimmer.trim(
                captured, sensitivity: current.vadSensitivity) else {
                recording.modelID = model.id
                recording.status = .nothingHeard
                return
            }
            samples = trimmed.samples
            leadingOffset = trimmed.trimmedLeadingSeconds
        }

        let options = TranscribeOptions(
            language: current.language,
            translateToEnglish: current.translateToEnglish,
            initialPrompt: TranscriptFormatter.initialPrompt(from: current.customVocabulary))
        let engine = self.engine

        do {
            try await engine.load(model: model)
            let transcript = try await engine.transcribe(samples: samples, options: options)
            let segments = TranscriptFormatter.format(transcript.segments, settings: current)
                .map { $0.offset(by: leadingOffset) }
            // With timings, the text is the segments joined, so the two
            // never disagree about a word.
            let text = segments.isEmpty
                ? TranscriptFormatter.format(transcript.text, settings: current)
                : segments.map(\.text).joined(separator: " ")
            recording.transcript = text
            recording.segments = segments
            recording.language = transcript.language
            recording.status = text.isEmpty ? .nothingHeard : .transcribed
        } catch is CancellationError {
            return
        } catch {
            recording.status = .failed(error.localizedDescription)
        }
        recording.modelID = await engine.modelID ?? model.id

        // Off means off: a phone has less memory to spare than a Mac, and
        // the user asked for it back between recordings.
        if !current.keepModelInMemory {
            await engine.unload()
        }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.level = self.recorder.level
                self.bands = self.recorder.bands
                self.elapsed = self.recorder.elapsed
                if self.recorder.reachedLimit {
                    await self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        level = 0
        bands = Array(repeating: 0, count: MeterAnalyzer.barCount)
    }
}
