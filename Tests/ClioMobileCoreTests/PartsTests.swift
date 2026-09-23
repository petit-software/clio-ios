import Foundation
import Testing
@testable import ClioMobileCore

/// A recording of several parts: recorded into, merged, split — with every
/// file and every word still where it was.
@Suite("Recording parts")
struct PartsTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("An entry from before parts decodes as one part, and says the same things")
    func legacyDecodes() throws {
        let id = UUID()
        let json = #"""
        {"id":"\#(id.uuidString)","audioFileName":"old.wav","duration":4,
         "transcript":"Hello there.","language":"en","status":{"transcribed":{}},
         "segments":[{"start":0,"end":2,"text":"Hello there."}]}
        """#
        let recording = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(recording.parts.count == 1)
        #expect(recording.audioFileName == "old.wav")
        #expect(recording.transcript == "Hello there.")
        #expect(recording.duration == 4)
        #expect(recording.segments.count == 1)
        #expect(recording.parts[0].id == id, "the first part keeps the recording's id")

        // Round trip, and the flat fields are still written for an older build.
        let data = try JSONEncoder().encode(recording)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["audioFileName"] as? String == "old.wav")
        #expect(object["transcript"] as? String == "Hello there.")
        #expect(try JSONDecoder().decode(Recording.self, from: data) == recording)
    }

    @Test("Merge: one recording under the oldest, every part in order, no file deleted")
    @MainActor
    func mergeAndSplit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("r.json")
        let store = RecordingStore(indexURL: index, audioDirectory: directory)

        let first = Recording(createdAt: Date(timeIntervalSinceNow: -300), duration: 3,
                              title: "Standup", transcript: "One.")
        let second = Recording(createdAt: Date(timeIntervalSinceNow: -200), duration: 4,
                               transcript: "Two.", summary: "Old summary")
        let third = Recording(createdAt: Date(timeIntervalSinceNow: -100), duration: 5,
                              transcript: "Three.")
        for recording in [first, second, third] {
            try Data([1]).write(to: store.audioURL(for: recording))
            store.add(recording)
        }

        let merged = try #require(store.merge([third.id, first.id, second.id]))
        #expect(merged == first.id)
        #expect(store.recordings.count == 1)
        let recording = try #require(store[merged])
        #expect(recording.parts.map(\.transcript) == ["One.", "Two.", "Three."])
        #expect(recording.transcript == "One.\n\nTwo.\n\nThree.")
        #expect(recording.duration == 12)
        #expect(recording.title == "Standup")
        #expect(recording.segments.isEmpty, "times belong to each part's own file")
        for url in store.audioURLs(for: recording) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let reloaded = RecordingStore(indexURL: index, audioDirectory: directory)
        #expect(reloaded[merged] == recording)

        // Split puts them back under their own ids and dates.
        let ids = store.split(merged)
        #expect(ids == [first.id, second.id, third.id])
        #expect(store.recordings.map(\.transcript) == ["Three.", "Two.", "One."])
        #expect(store[first.id]?.title == "Standup")
        #expect(store[second.id]?.title == "")

        // Deleting a merged recording takes every part's file with it.
        let again = try #require(store.merge(ids))
        let urls = store.audioURLs(for: try #require(store[again]))
        store.delete(again)
        for url in urls {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Recording from inside a recording adds a part to it, not a row")
    @MainActor
    func appendFromDetail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                     audioDirectory: directory)
        let recorder = SimulatedRecorder()
        recorder.simulatedElapsed = 2
        let controller = CaptureController(
            recorder: recorder,
            engine: StubTranscriptionEngine(latency: .milliseconds(10)),
            models: .simulating(installed: [ModelManager.simulatedInstalled()]),
            settings: .simulating(Settings()),
            library: library)

        await controller.start()
        await controller.stop()
        let original = try #require(library.recordings.first)

        controller.appendTarget = original.id
        await controller.start()
        // Walking away mid-recording does not move it.
        controller.appendTarget = nil
        await controller.stop()

        #expect(library.recordings.count == 1)
        let recording = try #require(library[original.id])
        #expect(recording.parts.count == 2)
        #expect(controller.lastRecordingID == original.id)
        #expect(abs(recording.duration - 4) < 0.01)
        #expect(recording.parts.allSatisfy { $0.status == .transcribed })
        #expect(recording.parts[0].audioFileName != recording.parts[1].audioFileName)
        for url in library.audioURLs(for: recording) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // Transcribe Again runs over every part.
        await controller.retranscribe(original.id)
        #expect(library[original.id]?.parts.count == 2)
        #expect(library[original.id]?.status == .transcribed)

        // A target deleted mid-recording: the part becomes a recording.
        controller.appendTarget = original.id
        await controller.start()
        library.delete(original.id)
        await controller.stop()
        #expect(library.recordings.count == 1)
        #expect(library.recordings.first?.parts.count == 1)
    }
}
