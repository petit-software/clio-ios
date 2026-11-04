import Foundation
import Observation

/// Titles and summaries, after the transcript.
///
/// Runs beside the capture loop rather than inside it: the recording is in
/// the library the moment the transcript is, and the summary arrives on
/// the row a few seconds later. A summary that fails, or a phone that
/// cannot make one, changes nothing about the recording.
@MainActor
@Observable
public final class IntelligenceController {

    /// Asked of the engine once at start and again whenever the app comes
    /// to the foreground — the user may have just turned Apple
    /// Intelligence on.
    public private(set) var availability: SummaryAvailability = .unavailable(reason: "Checking…")
    public private(set) var inProgress: Set<Recording.ID> = []
    /// Why the last attempt for a recording failed, until the next one.
    public private(set) var failures: [Recording.ID: String] = [:]

    public let engine: any SummaryEngine
    public let settings: SettingsStore
    public let library: RecordingStore

    private var tasks: [Recording.ID: Task<Void, Never>] = [:]

    public init(engine: any SummaryEngine,
                settings: SettingsStore,
                library: RecordingStore) {
        self.engine = engine
        self.settings = settings
        self.library = library
        Task { await refreshAvailability() }
    }

    public func refreshAvailability() async {
        availability = await engine.availability
    }

    /// On, and the phone can do it.
    public var isEnabled: Bool {
        settings.settings.generateSummaries && availability.isAvailable
    }

    public func isSummarizing(_ id: Recording.ID) -> Bool {
        inProgress.contains(id)
    }

    /// Called after every transcription. Does nothing unless the feature
    /// is on, the phone can, and the transcript is long enough to be worth
    /// it — a five-word note's title is its five words.
    public func summarizeIfEnabled(_ id: Recording.ID) {
        guard isEnabled,
              let recording = library[id],
              recording.status == .transcribed,
              SummaryPrompt.isWorthSummarizing(recording.transcript)
        else { return }
        summarize(id)
    }

    /// The words under a recording changed — a part recorded into it, or
    /// others merged with it — so what was written about them is written
    /// again: when summaries are on, or when this one already had a summary
    /// (asked for by hand, say). The old one stays until the new one lands.
    public func resummarize(_ id: Recording.ID) {
        guard let recording = library[id],
              availability.isAvailable,
              recording.status == .transcribed,
              settings.settings.generateSummaries || recording.summary != nil,
              SummaryPrompt.isWorthSummarizing(recording.transcript)
        else { return }
        // One already running is on the old words: this one follows it,
        // and what it writes is what stays.
        if let running = tasks[id] {
            Task { [weak self] in
                await running.value
                self?.summarize(id)
            }
        } else {
            summarize(id)
        }
    }

    /// On demand, from the detail view. Replaces whatever is there.
    @discardableResult
    public func summarize(_ id: Recording.ID) -> Task<Void, Never> {
        if let running = tasks[id] { return running }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(id)
        }
        tasks[id] = task
        return task
    }

    private func perform(_ id: Recording.ID) async {
        defer {
            tasks[id] = nil
            inProgress.remove(id)
        }
        guard let recording = library[id], !recording.transcript.isEmpty else { return }
        inProgress.insert(id)
        failures[id] = nil

        // The preferences as they are now, whichever way this was asked for
        // — after the transcript, Summarize Again, a retry. The transcript
        // is read, never written: a summary is about it, not of it.
        let request = SummaryRequest(transcript: recording.transcript,
                                     language: recording.language,
                                     preferences: settings.settings.summaryPreferences)
        do {
            let result = try await engine.summarize(request)
            // Re-read: the user may have renamed or deleted it meanwhile.
            guard !Task.isCancelled, var current = library[id] else { return }
            if !result.title.isEmpty { current.generatedTitle = result.title }
            if !result.summary.isEmpty { current.summary = result.summary }
            library.update(current)
        } catch is CancellationError {
            return
        } catch {
            // The old summary and title stand: a failure writes nothing.
            failures[id] = error.localizedDescription
        }
    }
}
