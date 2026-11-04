import Foundation
import Testing
@testable import ClioMobileCore

/// End-to-end against the real Hugging Face repo and a real CoreML model.
///
/// Off by default: it downloads ~81 MB and takes a while. Run it deliberately,
/// on the host:
///
///     CLIO_INTEGRATION=1 swift test --filter Integration
///
/// It is the only thing that proves the ASR path works, so it exists rather
/// than being replaced by a mock that always agrees with us. The speech is
/// produced by macOS's own synthesizer, so the test carries no audio fixture
/// — which is also why it is host-only: there is no `say` on a phone.
private let integrationEnabled =
    ProcessInfo.processInfo.environment["CLIO_INTEGRATION"] != nil

#if os(macOS)
@Suite("Integration", .enabled(if: integrationEnabled), .serialized)
struct IntegrationTests {

    enum IntegrationError: Error { case downloadFailed(String) }

    private func makeSpokenAudio(_ phrase: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // `say` writes AIFF; AudioFiles reads anything AVAudioFile can open
        // and converts to 16 kHz mono, which is the recorder's format.
        let file = directory.appendingPathComponent("speech.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "170", "-o", file.path, phrase]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try AudioFiles.read(file)
    }

    /// Installed once and kept, so a second run does not re-download 81 MB.
    /// Cleared by a reboot like anything else in /tmp.
    private var sharedModelRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-integration-models", isDirectory: true)
    }

    @MainActor
    private func installTinyModel() async throws -> InstalledModel {
        let root = sharedModelRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = try #require(ModelCatalog.builtIn.first { $0.id == "openai_whisper-tiny" })
        let manager = ModelManager(transport: HuggingFaceTransport(), modelsDirectory: root)

        if !manager.isInstalled(model.id) {
            manager.download(model)
            let deadline = ContinuousClock.now + .seconds(600)
            while !manager.isInstalled(model.id) {
                if let failure = manager.failures[model.id] {
                    throw IntegrationError.downloadFailed(failure)
                }
                guard ContinuousClock.now < deadline else {
                    throw IntegrationError.downloadFailed("timed out")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        return try #require(manager.installed.first { $0.id == model.id })
    }

    @Test("A downloaded model transcribes real speech, entirely offline")
    func endToEnd() async throws {
        let installed = try await installTinyModel()

        // The tokenizer must be installed alongside, or the first
        // transcription silently reaches for the network.
        let tokenizer = ModelManager.tokenizerDirectory(for: installed)
            .appendingPathComponent("tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: tokenizer.path))

        let engine = WhisperKitEngine()
        try await engine.load(model: installed)
        #expect(await engine.isLoaded)
        #expect(await engine.modelID == installed.id)

        let samples = try makeSpokenAudio("The quick brown fox jumps over the lazy dog.")
        #expect(samples.count > 16_000)

        let transcript = try await engine.transcribe(
            samples: samples, options: TranscribeOptions(language: "en"))
        let text = transcript.text.lowercased()
        print("[integration] transcript: \(transcript.text)")
        #expect(text.contains("quick brown fox"))
        #expect(text.contains("lazy dog"))

        // Timings: at least one segment, inside the clip, clean of tokens.
        for segment in transcript.segments {
            print("[integration] segment \(segment.start)–\(segment.end): \(segment.text)")
        }
        #expect(!transcript.segments.isEmpty)
        #expect(transcript.segments.allSatisfy { $0.start >= 0 && $0.end <= transcript.duration + 1 })
        #expect(transcript.segments.allSatisfy { !$0.text.contains("<|") })
        #expect(transcript.segments.map(\.text).joined(separator: " ").lowercased()
            .contains("quick brown fox"))

        await engine.unload()
        #expect(await engine.isLoaded == false)
    }

    /// The whole loop, as the app runs it: simulated microphone handing back
    /// synthesized speech, the real manager, the real engine, the real store.
    @Test("The capture controller transcribes through the real engine")
    @MainActor
    func captureLoop() async throws {
        let installed = try await installTinyModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = SimulatedRecorder()
        recorder.samples = try makeSpokenAudio("Milk, eggs, and a loaf of bread.")
        let library = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                     audioDirectory: directory)
        let models = ModelManager.simulating(installed: [installed])
        var settings = Settings()
        settings.language = "en"
        let controller = CaptureController(recorder: recorder,
                                           engine: WhisperKitEngine(),
                                           models: models,
                                           settings: .simulating(settings),
                                           library: library)

        await controller.start()
        await controller.stop()

        let recording = try #require(library.recordings.first)
        print("[integration] transcript: \(recording.transcript)")
        #expect(recording.status == .transcribed)
        #expect(recording.modelID == installed.id)
        #expect(recording.transcript.lowercased().contains("bread"))
    }

    /// The bug this guards against: the last sentence of a recording spoken
    /// more softly than the rest — a voice trailing off — was cut by the
    /// trimmer before the model saw it, so the audio was whole and the
    /// transcript ended a sentence early. The clip here is two sentences of
    /// synthesized speech with the second at -20 dB, then a second of room.
    /// The trimmer must keep it, and the model must read it.
    @Test("The quiet last sentence of a recording reaches the transcript")
    func quietTailIsTranscribed() async throws {
        let installed = try await installTinyModel()
        let engine = WhisperKitEngine()
        try await engine.load(model: installed)

        let loud = try makeSpokenAudio("The meeting moved to Thursday afternoon.")
        let soft = try makeSpokenAudio("And bring the signed contract.").map { $0 * 0.1 }
        let room = [Float](repeating: 0, count: Int(1.0 * AudioRecorder.sampleRate))
        let clip = loud + soft + room

        // The gate must still call this speech, and — as the app does now —
        // the whole clip goes to the model.
        #expect(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5) != nil)
        let transcript = try await engine.transcribe(
            samples: clip, options: TranscribeOptions(language: "en"))
        print("[integration] transcript: \(transcript.text)")
        let text = transcript.text.lowercased()
        #expect(text.contains("thursday"))
        #expect(text.contains("contract"), "the quiet last sentence is in the transcript")

        // What the old trimmer did, for the record: cut at the last loud
        // frame plus 120 ms. The model then never heard the soft sentence.
        let tight = Array(clip[0..<min(clip.count, loud.count + Int(0.12 * AudioRecorder.sampleRate))])
        let before = try await engine.transcribe(
            samples: tight, options: TranscribeOptions(language: "en"))
        print("[integration] with the old cut: \(before.text)")

        await engine.unload()
    }

    /// The real language model, on this Mac. Passes trivially, with the
    /// reason printed, on a Mac without Apple Intelligence: the point is to
    /// prove the call shape and the output when it can run, not to fail a
    /// test suite over a system setting.
    @Test("Apple's on-device model writes a title and a summary")
    func foundationModels() async throws {
        let engine = SummaryEngines.apple()
        let availability = await engine.availability
        guard availability.isAvailable else {
            print("[integration] Foundation Models unavailable: \(availability.reason ?? "?")")
            return
        }

        let transcript = """
            Quick note before I forget. The plumber can come Thursday morning \
            but only before ten, so someone has to be home. The estimate for the \
            boiler was eleven hundred, which is more than we said, so I want a \
            second quote before we commit. And the balcony door still sticks in \
            the heat, ask him about that too while he is here.
            """
        let summary = try await engine.summarize(transcript, language: "en")
        print("[integration] title: \(summary.title)")
        print("[integration] summary: \(summary.summary)")
        #expect(!summary.title.isEmpty)
        #expect(summary.title.split(separator: " ").count <= 8)
        #expect(!summary.summary.isEmpty)
        #expect(summary.summary.lowercased().contains("plumber")
                || summary.summary.lowercased().contains("boiler"))

        // The same transcript as a to-do list in bullets: the preferences
        // reach the model through the shared prompt, and the answer has
        // the asked-for shape.
        let todo = try await engine.summarize(SummaryRequest(
            transcript: transcript, language: "en",
            preferences: SummaryPreferences(noteType: .todo, format: .bullets, length: .standard)))
        print("[integration] todo title: \(todo.title)")
        print("[integration] todo summary:\n\(todo.summary)")
        #expect(todo.summary.contains("- ") || todo.summary.contains("• "),
                "bullets, as asked")
    }

    /// The recordings are as likely to be Dutch as English. Either the
    /// model handles it, or the failure names the language — both are
    /// fine; a generic error is not.
    @Test("Dutch is either summarized or refused by name")
    func dutch() async throws {
        let engine = SummaryEngines.apple()
        guard await engine.availability.isAvailable else { return }

        let transcript = """
            Even een notitie voor morgen. De loodgieter kan donderdagochtend komen, \
            maar alleen voor tienen, dus er moet iemand thuis zijn. De offerte voor \
            de ketel was elfhonderd euro, meer dan afgesproken, dus ik wil eerst een \
            tweede offerte. En de balkondeur klemt nog steeds als het warm is.
            """
        do {
            let summary = try await engine.summarize(transcript, language: "nl")
            print("[integration] nl title: \(summary.title)")
            print("[integration] nl summary: \(summary.summary)")
            #expect(!summary.title.isEmpty)
            #expect(!summary.summary.isEmpty)
        } catch let error as SummaryEngineError {
            print("[integration] nl refused: \(error.localizedDescription)")
            #expect(error == .unsupportedLanguage("Dutch"))
        }
    }
}
#endif
