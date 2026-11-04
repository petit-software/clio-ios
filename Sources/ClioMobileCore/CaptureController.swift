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
    /// 0…1, for the meter. Polled from the recorder ~60×/s while recording.
    public private(set) var level: Float = 0
    /// Six bars, 0…1 each, polled with the level. See `MeterAnalyzer`.
    public private(set) var bands: [Float] = Array(repeating: 0, count: MeterAnalyzer.barCount)
    public private(set) var elapsed: TimeInterval = 0
    /// The recording most recently added, so the UI can open it.
    public private(set) var lastRecordingID: Recording.ID?
    /// Where the next recording goes: a new part at the end of this one,
    /// or, when nil, a recording of its own. Set by the screen on show —
    /// a recording's detail sets it to that recording — and read once, at
    /// the start, so walking away mid-recording does not move it.
    public var appendTarget: Recording.ID?
    /// The target the capture in progress was started with.
    public private(set) var appendingTo: Recording.ID?

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
    /// Between the lift and the verdict: the state is still a capturing one
    /// and must not take a second stop.
    private var stopping = false
    /// The parts whose transcript is being written right now. The row is in
    /// the library before the model is asked — see `finish` — so this is
    /// what lets the list and the detail say "Transcribing…" on it rather
    /// than "Not transcribed yet".
    public private(set) var transcribingParts: Set<RecordingPart.ID> = []
    /// A rough transcript of the last half minute of a held recording,
    /// written again every couple of seconds while it runs — see
    /// `Settings.liveTranscriptPreview`. Nil when there is none: the
    /// setting is off, nothing has been said yet, or the recording is over.
    /// Provisional by nature; the saved transcript is made at stop from
    /// the whole recording and never from this.
    public private(set) var livePreview: String?
    /// How often the preview is written. Short in tests.
    public var previewInterval: Duration = .seconds(2)
    /// The preview looks this far back. Whisper's window, so one pass.
    public static let previewWindowSeconds: TimeInterval = 30
    private var previewTask: Task<Void, Never>?

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

    /// Whether any part of this recording is being transcribed right now.
    public func isTranscribing(_ recording: Recording) -> Bool {
        recording.parts.contains { transcribingParts.contains($0.id) }
    }

    public func isTranscribing(_ part: RecordingPart) -> Bool {
        transcribingParts.contains(part.id)
    }

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
        appendingTo = appendTarget.flatMap { library[$0]?.id }
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
        livePreview = nil
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
        // Hold to record only: the preview is read under the clock while
        // the finger is down, and the sheet has nowhere to show it.
        if discardingSilence { startPreview() }
    }

    // MARK: Live preview

    /// Every `previewInterval`, the last half minute through the model, and
    /// the words into `livePreview`. Reads the setting on each pass, so
    /// turning it off mid-recording stops the next pass and nothing else;
    /// the capture never waits on this. A pass that fails is skipped — the
    /// transcript that counts is the one written at stop.
    private func startPreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.previewInterval ?? .seconds(2))
                guard let self, !Task.isCancelled, self.state == .recording else { continue }
                guard self.settings.settings.liveTranscriptPreview, let model = self.activeModel else {
                    self.livePreview = nil
                    continue
                }
                let current = self.settings.settings
                let samples = self.recorder.snapshot(lastSeconds: Self.previewWindowSeconds)
                guard SilenceGate.verdict(for: samples, sensitivity: current.vadSensitivity,
                                          usingVoiceActivity: true).isSpeech else { continue }
                let options = TranscribeOptions(
                    language: current.language,
                    translateToEnglish: current.translateToEnglish,
                    initialPrompt: TranscriptFormatter.initialPrompt(from: current.customVocabulary))
                let engine = self.engine
                guard let transcript = try? await Self.preview(samples, with: engine,
                                                               model: model, options: options),
                      !Task.isCancelled, self.state == .recording
                else { continue }
                let text = TranscriptFormatter.format(transcript.text, settings: current)
                if !text.isEmpty { self.livePreview = text }
            }
        }
    }

    private nonisolated static func preview(_ samples: [Float], with engine: any TranscriptionEngine,
                                            model: InstalledModel,
                                            options: TranscribeOptions) async throws -> Transcript {
        try await engine.load(model: model)
        return try await engine.transcribe(samples: samples, options: options)
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        livePreview = nil
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
        guard state.isCapturing, !stopping else { return }
        stopping = true
        defer { stopping = false }
        stopPolling()
        stopPreview()
        // Not `.transcribing` yet: `finish` looks at what was captured
        // first, and a capture with nothing in it never gets that far. The
        // flag is what keeps a second stop out in the meantime, since the
        // state is still a capturing one until the recorder has answered.
        let result = await recorder.stop()
        elapsed = result.duration
        await finish(result)
    }

    public func cancel() async {
        switch state {
        case .starting, .recording, .interrupted, .paused:
            stopPolling()
            stopPreview()
            locationTask?.cancel()
            locationTask = nil
            await recorder.cancel()
            appendingTo = nil
            state = .idle
        case .transcribing:
            // The row and its audio stay: the part went into the library
            // before the model was asked, and a transcript that was stopped
            // is a pending one, with Transcribe Again on it. Nothing opens.
            appendingTo = nil
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
        let current = settings.settings
        // Is there a word in this at all? Answered from the samples, with
        // nothing loaded and nothing written — see `SilenceGate`. Hold to
        // record runs the voice gate whether or not trimming is on: what is
        // being caught is an accident, not a long pause.
        let verdict = SilenceGate.verdict(
            for: result.samples,
            sensitivity: current.vadSensitivity,
            usingVoiceActivity: current.voiceActivityDetection || discardSilence)

        // Nothing in it, and it was a held recording: gone as if it never
        // happened. No file, no row, and the app never said "Transcribing".
        if discardSilence, !verdict.isSpeech {
            state = .idle
            return
        }

        // There is something to transcribe. Say so now rather than after
        // the file is written: a long recording takes a moment to land.
        if verdict.isSpeech { state = .transcribing }

        let id = UUID()
        let audioURL = library.newAudioURL(for: id)
        let target = appendingTo

        // The audio is saved before anything else can go wrong. A transcript
        // that fails can be retried; a recording that was never written is
        // gone.
        do {
            try AudioFiles.write(result.samples, to: audioURL)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        var part = RecordingPart(id: id,
                                 duration: result.duration,
                                 audioFileName: audioURL.lastPathComponent,
                                 status: .pending)
        let location = await locationTask?.value
        locationTask = nil

        // Nothing in it, but this was a tap: the audio was asked for, so the
        // row lands as "Nothing was heard" without the model being woken
        // for it. Transcribe Again is there if the gate got it wrong.
        guard verdict.isSpeech else {
            part.status = .nothingHeard
            lastRecordingID = place(part, location: location, into: target)
            state = .idle
            return
        }

        // Into the library now, as a pending part, and the words follow. A
        // transcript that fails, a cancel, a screen locked for long enough
        // that iOS ends the app while the model runs: every one of those
        // used to leave a WAV on disk that no row pointed at, which is a
        // recording lost. Now each leaves the row with its audio and
        // Transcribe Again on it. The recording opens once the words are in.
        let recordingID = place(part, location: location, into: target)
        transcribingParts.insert(part.id)
        let task = Task { [weak self] in
            guard let self else { return }
            // A little more time from iOS if the screen locks meanwhile:
            // enough for a transcript that was a second from done.
            let work = BackgroundWork.begin("Transcribe")
            defer { work.end() }
            await self.transcribe(result.samples, into: &part)
            self.transcribingParts.remove(part.id)
            // Cancelled: the part stays as it was placed, pending.
            guard !Task.isCancelled else { return }
            if self.discardSilence, part.status == .nothingHeard {
                // A held capture the gate let through and the model heard
                // nothing in: gone, as if it never happened.
                self.library.removePart(part.id, from: recordingID)
                self.state = .idle
                return
            }
            self.library.replace(part, in: recordingID)
            self.lastRecordingID = recordingID
            self.state = .idle
            if target != nil {
                // More words under the same title: the summary is about
                // all of them, so it is written again.
                self.intelligence?.resummarize(recordingID)
            } else {
                self.intelligence?.summarizeIfEnabled(recordingID)
            }
        }
        transcribeTask = task
        await task.value
        transcribeTask = nil
    }

    /// Into the library: a part at the end of the target, or a recording of
    /// its own when there is no target, or it was deleted while this one
    /// was being made. Returns the recording it went into. Does not touch
    /// `lastRecordingID`: that is set when the recording is ready to open.
    private func place(_ part: RecordingPart, location: RecordingLocation?,
                       into target: Recording.ID?) -> Recording.ID {
        appendingTo = nil
        if let target, library.append(part, to: target) {
            return target
        }
        var recording = Recording(id: part.id, createdAt: part.createdAt, duration: 0,
                                  location: location)
        recording.parts = [part]
        library.add(recording)
        return recording.id
    }

    /// Transcribe an existing recording again — after a failure, or with a
    /// different model.
    public func retranscribe(_ id: Recording.ID) async {
        guard !state.isBusy, var recording = library[id] else { return }
        state = .transcribing
        let work = BackgroundWork.begin("Transcribe again")
        defer { work.end() }
        for index in recording.parts.indices {
            let partID = recording.parts[index].id
            transcribingParts.insert(partID)
            defer { transcribingParts.remove(partID) }
            do {
                let samples = try AudioFiles.read(library.audioURL(for: recording.parts[index]))
                await transcribe(samples, into: &recording.parts[index])
            } catch {
                recording.parts[index].status = .failed(error.localizedDescription)
            }
        }
        // Re-read: renamed or summarized while this ran, those stand.
        if var current = library[id] {
            for part in recording.parts {
                if let index = current.parts.firstIndex(where: { $0.id == part.id }) {
                    current.parts[index] = part
                }
            }
            recording = current
        }
        library.update(recording)
        state = .idle
        intelligence?.summarizeIfEnabled(recording.id)
    }

    /// Trim, load, transcribe, format. Writes the outcome into the recording
    /// and never throws: whatever went wrong is the recording's status.
    private func transcribe(_ captured: [Float], into recording: inout RecordingPart) async {
        let current = settings.settings

        guard let model = activeModel else {
            recording.status = .failed(Self.noModelMessage)
            return
        }

        // The model hears the whole capture, as the file keeps it. Silence
        // used to be cut off both ends first, and that lost words: Whisper
        // is sensitive to exactly where a clip starts — the same recording
        // cut 0.85 s in lost its last word and all its punctuation, cut
        // 0.5 s or 1.0 s in it did not — and it pads every clip to thirty
        // seconds anyway, so the cut bought nothing. The trimmer is only
        // asked whether there is any speech at all, which is cheap and
        // sure; segment times then index the file directly.
        let samples = captured
        if current.voiceActivityDetection,
           VoiceActivityTrimmer.trim(captured, sensitivity: current.vadSensitivity) == nil {
            recording.modelID = model.id
            recording.status = .nothingHeard
            return
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
                // Twice the old rate: the wash chases these on every frame,
                // and a level that is fresher is a wash that is closer to
                // the voice.
                try? await Task.sleep(for: .milliseconds(16))
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
