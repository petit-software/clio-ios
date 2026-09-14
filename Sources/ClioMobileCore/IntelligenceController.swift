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

        do {
            let result = try await engine.summarize(recording.transcript,
                                                    language: recording.language)
            // Re-read: the user may have renamed or deleted it meanwhile.
            guard !Task.isCancelled, var current = library[id] else { return }
            current.generatedTitle = result.title.isEmpty ? nil : result.title
            current.summary = result.summary.isEmpty ? nil : result.summary
            library.update(current)
        } catch is CancellationError {
            return
        } catch {
            failures[id] = error.localizedDescription
        }
    }
}
