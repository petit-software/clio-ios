import Foundation
import Testing
@testable import ClioMobileCore

/// The whole loop on a simulated microphone and the stub engine: this is
/// what proves the state machine, not the views.
@Suite("Capture controller")
struct CaptureTests {

    /// The stub engine on a simulated install of the default model, so the
    /// loop has a model to "load" without anything on disk.
    @MainActor
    private func makeController(recorder: SimulatedRecorder = SimulatedRecorder(),
                                settings: Settings = Settings(),
                                installed: [InstalledModel] = [ModelManager.simulatedInstalled()],
                                engine: StubTranscriptionEngine = StubTranscriptionEngine(latency: .milliseconds(10)))
        throws -> (CaptureController, RecordingStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                     audioDirectory: directory)
        let controller = CaptureController(recorder: recorder,
                                           engine: engine,
                                           models: .simulating(installed: installed),
                                           settings: .simulating(settings),
                                           library: library)
        return (controller, library, directory)
    }

    @Test("Record, stop, transcribe: a recording lands in the library with its audio")
    @MainActor
    func happyPath() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 2
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        #expect(controller.state == .recording)

        await controller.stop()
        #expect(controller.state == .idle)
        #expect(recorder.stopCount == 1)

        let recording = try #require(library.recordings.first)
        #expect(controller.lastRecordingID == recording.id)
        #expect(recording.status == .transcribed)
        #expect(recording.transcript.contains("[Clio stub]"))
        #expect(recording.modelID == "stub", "what the engine says it ran")
        #expect(await controller.engine.isLoaded, "loaded on the way, and kept by default")
        #expect(abs(recording.duration - 2) < 0.01)

        let audio = library.audioURL(for: recording)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let samples = try AudioFiles.read(audio)
        #expect(samples.count == Int(2 * AudioRecorder.sampleRate))
    }

    @Test("Segments are stored, shifted by the silence trimmed off the front")
    @MainActor
    func segmentsAreOffset() async throws {
        // One second of silence, then two seconds of tone: the trimmer cuts
        // most of the first second, and the segments move by that much.
        let silence = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate))
        let tone = (0..<Int(2 * AudioRecorder.sampleRate)).map { i in
            0.1 * sin(2 * .pi * 440 * Float(i) / Float(AudioRecorder.sampleRate))
        }
        let recorder = SimulatedRecorder()
        recorder.samples = silence + tone
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        let recording = try #require(library.recordings.first)
        #expect(recording.segments.count == 2)
        let first = try #require(recording.segments.first)
        #expect(first.start > 0.7 && first.start < 1.0, "shifted by the trimmed lead")
        #expect(recording.transcript == recording.segments.map(\.text).joined(separator: " "))
        #expect(recording.transcript.hasPrefix("[Clio stub]"))

        // The index carries them.
        let reloaded = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                      audioDirectory: directory)
        #expect(reloaded[recording.id]?.segments == recording.segments)
    }

    @Test("Cancel while recording throws it away")
    @MainActor
    func cancelWhileRecording() async throws {
        let recorder = SimulatedRecorder()
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.cancel()
        #expect(controller.state == .idle)
        #expect(recorder.cancelCount == 1)
        #expect(library.recordings.isEmpty)
    }

    @Test("A microphone that will not start is a failure the user can see")
    @MainActor
    func startFailure() async throws {
        let recorder = SimulatedRecorder(startError: AudioRecorder.RecorderError.permissionDenied)
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        guard case .failed(let message) = controller.state else {
            Issue.record("expected .failed, got \(controller.state)")
            return
        }
        #expect(message.contains("microphone"))
        #expect(library.recordings.isEmpty)

        controller.dismissFailure()
        #expect(controller.state == .idle)
    }

    @Test("Nothing captured is saved as nothing heard, not transcribed")
    @MainActor
    func nothingHeard() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 0
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        let recording = try #require(library.recordings.first)
        #expect(recording.status == .nothingHeard)
    }

    @Test("Formatting settings apply to what the engine returns")
    @MainActor
    func formatting() async throws {
        var settings = Settings()
        settings.wordReplacements = [WordReplacement(find: "stub", replace: "STUB")]
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 1
        let (controller, library, directory) = try makeController(recorder: recorder, settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        let recording = try #require(library.recordings.first)
        #expect(recording.transcript.hasPrefix("[Clio STUB]"))
    }

    @Test("Hitting the cap stops the recording on its own")
    @MainActor
    func reachesLimit() async throws {
        var settings = Settings()
        settings.maxRecordingSeconds = 60
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 61
        let (controller, library, directory) = try makeController(recorder: recorder, settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        // The poller notices on its first pass.
        for _ in 0..<50 where controller.state != .idle {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.state == .idle)
        let recording = try #require(library.recordings.first)
        #expect(abs(recording.duration - 60) < 0.01, "capped, not 61")
    }

    @Test("Re-transcribing a failed recording reads the audio back from disk")
    @MainActor
    func retranscribe() async throws {
        let (controller, library, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recording = Recording(duration: 1, status: .failed("no model"))
        let samples = [Float](repeating: 0.1, count: Int(AudioRecorder.sampleRate))
        try AudioFiles.write(samples, to: library.audioURL(for: recording))
        library.add(recording)

        await controller.retranscribe(recording.id)
        let updated = try #require(library[recording.id])
        #expect(updated.status == .transcribed)
        #expect(updated.transcript.contains("16000 samples"))
    }
    @Test("No model installed: the audio is kept and the recording says why")
    @MainActor
    func noModel() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 1
        let (controller, library, directory) = try makeController(recorder: recorder, installed: [])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(controller.activeModel == nil)
        await controller.start()
        await controller.stop()

        let recording = try #require(library.recordings.first)
        #expect(recording.status == .failed(CaptureController.noModelMessage))
        #expect(FileManager.default.fileExists(atPath: library.audioURL(for: recording).path))
        #expect(controller.state == .idle, "not a failure of the controller; the recording exists")
    }

    @Test("Hold to record: a capture with no speech in it leaves nothing behind")
    @MainActor
    func silenceIsDiscardedWhenAsked() async throws {
        let recorder = SimulatedRecorder()
        recorder.samples = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start(discardingSilence: true)
        await controller.stop()
        #expect(library.recordings.isEmpty)
        #expect(controller.lastRecordingID == nil, "nothing opens")
        #expect(controller.state == .idle)
        let wavs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
        #expect(wavs.isEmpty, "the audio file is gone too")

        // And with nothing captured at all.
        let empty = SimulatedRecorder()
        empty.simulatedElapsed = 0
        let (controller2, library2, directory2) = try makeController(recorder: empty)
        defer { try? FileManager.default.removeItem(at: directory2) }
        await controller2.start(discardingSilence: true)
        await controller2.stop()
        #expect(library2.recordings.isEmpty)
    }

    @Test("Silence with trimming on is nothing heard, and the engine is not asked")
    @MainActor
    func silenceIsTrimmedToNothing() async throws {
        let recorder = SimulatedRecorder()
        recorder.samples = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        let recording = try #require(library.recordings.first)
        #expect(recording.status == .nothingHeard)
        #expect(abs(recording.duration - 3) < 0.01, "the recording keeps its real length")
    }

    @Test("Trimming off hands the whole clip to the engine")
    @MainActor
    func trimmingOff() async throws {
        var settings = Settings()
        settings.voiceActivityDetection = false
        let recorder = SimulatedRecorder()
        // The tone, not digital silence: a clip with no signal in it never
        // reaches the engine now, whatever trimming is set to — see
        // `silenceNeverReachesTheEngine`. What this checks is that with
        // trimming off nothing is cut off the ends.
        recorder.simulatedElapsed = 3
        let (controller, library, directory) = try makeController(recorder: recorder, settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        let recording = try #require(library.recordings.first)
        #expect(recording.status == .transcribed)
        #expect(recording.transcript.contains("48000 samples"))
    }

    @Test("A clip with no signal in it never reaches the engine, trimming or not")
    @MainActor
    func silenceNeverReachesTheEngine() async throws {
        for trimming in [true, false] {
            var settings = Settings()
            settings.voiceActivityDetection = trimming
            let recorder = SimulatedRecorder()
            recorder.samples = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
            let (controller, library, directory) =
                try makeController(recorder: recorder, settings: settings)
            defer { try? FileManager.default.removeItem(at: directory) }

            await controller.start()
            await controller.stop()
            let recording = try #require(library.recordings.first)
            #expect(recording.status == .nothingHeard,
                    "trimming \(trimming ? "on" : "off")")
            #expect(recording.transcript.isEmpty)
        }
    }

    @Test("A press too short to hold a word leaves nothing behind")
    @MainActor
    func brushOfTheButtonIsDiscarded() async throws {
        let recorder = SimulatedRecorder()
        // Loud, and real speech if it were longer — but a fifth of a second
        // of it, which is what a button brushed in a pocket gives back.
        recorder.samples = (0..<Int(0.2 * AudioRecorder.sampleRate)).map { i in
            0.3 * sin(2 * .pi * 440 * Float(i) / Float(AudioRecorder.sampleRate))
        }
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start(discardingSilence: true)
        await controller.stop()
        #expect(library.recordings.isEmpty)
        #expect(controller.lastRecordingID == nil)
        #expect(controller.state == .idle)
    }

    @Test("The app never says it is transcribing a capture it is about to throw away")
    @MainActor
    func silentHoldNeverSaysTranscribing() async throws {
        let recorder = SimulatedRecorder()
        recorder.samples = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
        let (controller, _, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Every state the controller passes through, not only where it
        // lands: "Transcribing" showing for a frame is the bug.
        let seen = StateLog()
        seen.follow(controller)
        await controller.start(discardingSilence: true)
        await controller.stop()

        #expect(seen.states.contains(.recording), "the log is following")
        #expect(!seen.states.contains(.transcribing))
        #expect(controller.state == .idle)
    }

    /// Records every value `state` takes, by re-arming observation from
    /// inside the change handler.
    @MainActor
    final class StateLog {
        private(set) var states: [CaptureState] = []

        func follow(_ controller: CaptureController) {
            withObservationTracking {
                states.append(controller.state)
            } onChange: {
                Task { @MainActor [weak self] in self?.follow(controller) }
            }
        }
    }

    @Test("Keep in memory off unloads the model after each transcription")
    @MainActor
    func unloadsWhenNotKept() async throws {
        var settings = Settings()
        settings.keepModelInMemory = false
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 1
        let (controller, _, directory) = try makeController(recorder: recorder, settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        #expect(await controller.engine.isLoaded == false)

        controller.warmUp()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await controller.engine.isLoaded == false, "warm-up respects the setting too")
    }

    @Test("A call pauses the recording and it resumes when the call ends")
    @MainActor
    func interruptionResumes() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 2
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        recorder.simulate(.interrupted)
        try await settle()
        #expect(controller.state == .interrupted)
        #expect(controller.state.isBusy)

        recorder.simulate(.interruptionEnded(resumed: true))
        try await settle()
        #expect(controller.state == .recording)

        await controller.stop()
        #expect(library.recordings.count == 1)
    }

    @Test("A call the recorder cannot come back from ends the recording with what it has")
    @MainActor
    func interruptionEnds() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 2
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        recorder.simulate(.interrupted)
        try await settle()
        recorder.simulate(.interruptionEnded(resumed: false))
        try await settle(until: { controller.state == .idle })

        #expect(recorder.stopCount == 1)
        let recording = try #require(library.recordings.first)
        #expect(recording.status == .transcribed)
        #expect(abs(recording.duration - 2) < 0.01)
    }

    @Test("Stopping while paused works, and so does cancelling")
    @MainActor
    func stopWhileInterrupted() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 1
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        recorder.simulate(.interrupted)
        try await settle()
        await controller.stop()
        #expect(library.recordings.count == 1)

        await controller.start()
        recorder.simulate(.interrupted)
        try await settle()
        await controller.cancel()
        #expect(controller.state == .idle)
        #expect(recorder.cancelCount == 1)
        #expect(library.recordings.count == 1)
    }

    @Test("Pause holds the clock and the recording; resume carries on; stop works from either")
    @MainActor
    func pauseAndResume() async throws {
        let recorder = SimulatedRecorder()
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        try await Task.sleep(for: .milliseconds(120))
        await controller.pause()
        #expect(controller.state == .paused)
        #expect(controller.state.isCapturing)
        #expect(recorder.pauseCount == 1)
        let frozen = recorder.elapsed
        try await Task.sleep(for: .milliseconds(120))
        #expect(abs(recorder.elapsed - frozen) < 0.01, "the clock stops while paused")

        await controller.resume()
        #expect(controller.state == .recording)
        try await Task.sleep(for: .milliseconds(60))
        #expect(recorder.elapsed > frozen)

        await controller.pause()
        await controller.stop()
        #expect(controller.state == .idle)
        #expect(library.recordings.count == 1, "stop from paused saves")

        await controller.start()
        await controller.pause()
        await controller.cancel()
        #expect(controller.state == .idle)
        #expect(library.recordings.count == 1, "cancel from paused discards")
    }

    @Test("Losing the microphone mid-recording keeps what was captured")
    @MainActor
    func microphoneLost() async throws {
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 3
        let (controller, library, directory) = try makeController(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        recorder.simulate(.lost("headset gone"))
        try await settle(until: { controller.state == .idle })
        let recording = try #require(library.recordings.first)
        #expect(abs(recording.duration - 3) < 0.01)

        // An event with nothing running is ignored.
        recorder.simulate(.interrupted)
        try await settle()
        #expect(controller.state == .idle)
    }

    /// Events arrive through a hop to the main actor; give it a turn.
    @MainActor
    private func settle(until condition: () -> Bool = { true }) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if condition() { return }
        }
    }

    @Test("The stored selection follows what is installed")
    @MainActor
    func reconcilesActiveModel() async throws {
        var settings = Settings()
        settings.activeModelID = "gone"
        let tiny = ModelManager.simulatedInstalled("openai_whisper-tiny")
        let (controller, _, directory) = try makeController(settings: settings, installed: [tiny])
        defer { try? FileManager.default.removeItem(at: directory) }

        // A selection that is not installed is replaced on construction.
        #expect(controller.settings.settings.activeModelID == "openai_whisper-tiny")
        #expect(controller.activeModel == tiny)

        // Nothing installed at all clears it.
        let (empty, _, directory2) = try makeController(settings: settings, installed: [])
        defer { try? FileManager.default.removeItem(at: directory2) }
        #expect(empty.settings.settings.activeModelID == nil)
    }
}

@Suite("Audio files")
struct AudioFileTests {

    @Test("A WAV round-trips its samples at 16 kHz mono")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.wav")

        let samples = (0..<16_000).map { i in
            0.5 * sin(2 * .pi * 440 * Float(i) / 16_000)
        }
        try AudioFiles.write(samples, to: url)
        let back = try AudioFiles.read(url)

        #expect(back.count == samples.count)
        // 16-bit quantisation: within one step.
        let worst = zip(samples, back).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1.0 / 32_000)
    }

    @Test("The level scaler maps silence to the floor and speech into the window")
    func levelScaler() {
        var scaler = LevelScaler()
        #expect(scaler.level(rms: 0, dt: 0.1) == 0)
        let speech = scaler.level(rms: 0.1, dt: 0.1)    // -20 dBFS
        #expect(speech > 0.7 && speech <= 1)
        let quiet = scaler.level(rms: 0.003, dt: 0.1)   // -50 dBFS
        #expect(quiet < 0.05)
    }
}
