import Foundation
import Testing
@testable import ClioMobileCore

private let longTranscript = """
    The migration ran clean on staging this morning. Two flaky tests in the \
    payment suite, both timing related, and nobody has looked at the onboarding \
    copy yet, so that is on me for tomorrow before the review.
    """

@Suite("Summary prompt")
struct SummaryPromptTests {

    @Test("Short transcripts are not worth a summary")
    func minimumWords() {
        #expect(SummaryPrompt.isWorthSummarizing("Buy milk and eggs.") == false)
        #expect(SummaryPrompt.isWorthSummarizing(longTranscript))
    }

    @Test("Clipping cuts at a word and marks the cut")
    func clipping() {
        let text = String(repeating: "word ", count: 100)
        let clipped = SummaryPrompt.clip(text, to: 50)
        #expect(clipped.count <= 52)
        #expect(clipped.hasSuffix(" …"))
        #expect(clipped.contains("wor …") == false, "not mid-word")
        #expect(SummaryPrompt.clip("short") == "short")
    }

    @Test("Titles lose their quotes and full stop")
    func cleanTitle() {
        #expect(SummaryPrompt.cleanTitle("“Dentist and the invoice.”") == "Dentist and the invoice")
        #expect(SummaryPrompt.cleanTitle("  Standup   notes\n") == "Standup notes")
        #expect(SummaryPrompt.cleanTitle("One two three four five six seven") == "One two three four five")
        #expect(SummaryPrompt.cleanTitle("'Idee voor de tuin'") == "Idee voor de tuin")
    }
}

@Suite("Recording titles")
struct RecordingTitleTests {

    @Test("The user's name wins, then the generated one, then the first words")
    func displayTitleOrder() {
        var recording = Recording(duration: 1, transcript: "Remember to call the plumber tomorrow")
        #expect(recording.displayTitle == recording.createdAt.formatted(date: .abbreviated, time: .shortened),
                "no name and none generated: the date, not the transcript's first words")
        recording.generatedTitle = "Call the plumber"
        #expect(recording.displayTitle == "Call the plumber")
        recording.title = "Plumber"
        #expect(recording.displayTitle == "Plumber")
    }

    @Test("A generated title survives the index and is optional in it")
    func generatedTitleRoundTrip() throws {
        var recording = Recording(duration: 1, transcript: "x")
        recording.generatedTitle = "Generated"
        let data = try JSONEncoder().encode(recording)
        let back = try JSONDecoder().decode(Recording.self, from: data)
        #expect(back.generatedTitle == "Generated")

        let old = """
            {"id":"\(UUID().uuidString)","audioFileName":"a.wav","transcript":"hello there"}
            """
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(old.utf8))
        #expect(decoded.generatedTitle == nil)
        #expect(decoded.segments.isEmpty, "a recording from before segments still decodes")
        #expect(decoded.displayTitle == decoded.createdAt.formatted(date: .abbreviated, time: .shortened),
                "without a generated title the date names it, not the transcript")
    }
}

@Suite("Intelligence controller")
struct IntelligenceTests {

    @MainActor
    private func make(settings: Settings = Settings(),
                      engine: StubSummaryEngine = StubSummaryEngine(latency: .milliseconds(10)),
                      recordings: [Recording] = []) async -> (IntelligenceController, RecordingStore) {
        let library = RecordingStore.simulating(recordings)
        let controller = IntelligenceController(engine: engine,
                                                settings: .simulating(settings),
                                                library: library)
        await controller.refreshAvailability()
        return (controller, library)
    }

    @Test("A long transcript gets a title and a summary after transcription")
    @MainActor
    func summarizesAfterTranscription() async throws {
        let recording = Recording(duration: 30, transcript: longTranscript, language: "en")
        let (controller, library) = await make(recordings: [recording])
        #expect(controller.isEnabled)

        controller.summarizeIfEnabled(recording.id)
        await controller.summarize(recording.id).value

        let updated = try #require(library[recording.id])
        #expect(updated.generatedTitle == "[Stub] The migration ran")
        #expect(updated.summary?.contains("of en summarised") == true)
        #expect(updated.displayTitle == "[Stub] The migration ran")
        #expect(controller.isSummarizing(recording.id) == false)
    }

    @Test("A short transcript is left alone")
    @MainActor
    func skipsShort() async throws {
        let recording = Recording(duration: 3, transcript: "Buy milk and eggs.")
        let (controller, library) = await make(recordings: [recording])
        controller.summarizeIfEnabled(recording.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(library[recording.id]?.summary == nil)
    }

    @Test("Off in settings, or unavailable on the phone, does nothing")
    @MainActor
    func respectsSettingAndAvailability() async throws {
        let recording = Recording(duration: 30, transcript: longTranscript)
        var off = Settings()
        off.generateSummaries = false
        let (disabled, library1) = await make(settings: off, recordings: [recording])
        #expect(disabled.isEnabled == false)
        disabled.summarizeIfEnabled(recording.id)

        let engine = StubSummaryEngine(availability: .unavailable(reason: "No Apple Intelligence."))
        let (unavailable, library2) = await make(engine: engine, recordings: [recording])
        #expect(unavailable.isEnabled == false)
        #expect(unavailable.availability.reason == "No Apple Intelligence.")
        unavailable.summarizeIfEnabled(recording.id)

        try await Task.sleep(for: .milliseconds(50))
        #expect(library1[recording.id]?.summary == nil)
        #expect(library2[recording.id]?.summary == nil)
    }

    @Test("A failure is reported on the recording, and cleared by the next try")
    @MainActor
    func failureIsVisible() async throws {
        let recording = Recording(duration: 30, transcript: longTranscript)
        let engine = StubSummaryEngine(latency: .milliseconds(10),
                                       failure: SummaryEngineError.unsupportedLanguage("Dutch"))
        let (controller, library) = await make(engine: engine, recordings: [recording])

        await controller.summarize(recording.id).value
        #expect(controller.failures[recording.id] == "The on-device model does not support Dutch yet.")
        #expect(library[recording.id]?.summary == nil)
    }

    @Test("Summarizing on demand replaces the old summary and keeps the user's title")
    @MainActor
    func regenerateKeepsUserTitle() async throws {
        var recording = Recording(duration: 30, title: "Mine", transcript: longTranscript,
                                  summary: "old")
        recording.generatedTitle = "old title"
        let (controller, library) = await make(recordings: [recording])

        await controller.summarize(recording.id).value
        let updated = try #require(library[recording.id])
        #expect(updated.summary != "old")
        #expect(updated.generatedTitle == "[Stub] The migration ran")
        #expect(updated.title == "Mine")
        #expect(updated.displayTitle == "Mine")
    }

    @Test("The capture loop hands a finished transcript to intelligence")
    @MainActor
    func captureHandsOff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                     audioDirectory: directory)
        let settings = SettingsStore.simulating(Settings())
        let intelligence = IntelligenceController(
            engine: StubSummaryEngine(latency: .milliseconds(10)), settings: settings, library: library)
        await intelligence.refreshAvailability()

        // The stub transcript is long enough to summarize.
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 2
        let capture = CaptureController(recorder: recorder,
                                        engine: StubTranscriptionEngine(latency: .milliseconds(10)),
                                        models: .simulating(installed: [ModelManager.simulatedInstalled()]),
                                        settings: settings,
                                        library: library,
                                        intelligence: intelligence)
        await capture.start()
        await capture.stop()
        let id = try #require(capture.lastRecordingID)
        await intelligence.summarize(id).value

        let recording = try #require(library[id])
        #expect(recording.summary?.hasPrefix("[Clio stub]") == true)
        #expect(recording.generatedTitle?.hasPrefix("[Stub]") == true)
    }
}
