import Foundation
import Testing
@testable import ClioMobileCore

@Suite("Recording store")
struct RecordingStoreTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Add, rename, delete — and the index survives a reload")
    @MainActor
    func lifecycle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("recordings.json")

        let store = RecordingStore(indexURL: index, audioDirectory: directory)
        let older = Recording(createdAt: Date(timeIntervalSinceNow: -100), duration: 10,
                              transcript: "older")
        let newer = Recording(createdAt: Date(), duration: 20, transcript: "newer")
        try Data([0, 1, 2]).write(to: store.audioURL(for: older))

        store.add(older)
        store.add(newer)
        #expect(store.recordings.map(\.transcript) == ["newer", "older"], "newest first")

        store.rename(older.id, to: "Named")
        #expect(store[older.id]?.title == "Named")

        let reloaded = RecordingStore(indexURL: index, audioDirectory: directory)
        #expect(reloaded.recordings == store.recordings)

        reloaded.delete(older.id)
        #expect(reloaded.recordings.count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: older).path),
                "the audio file goes with the entry")
    }

    @Test("Audio bytes are summed from the files that exist")
    @MainActor
    func audioBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                   audioDirectory: directory)
        let a = Recording(duration: 1)
        let b = Recording(duration: 1)
        try Data(repeating: 0, count: 100).write(to: store.audioURL(for: a))
        store.add(a)
        store.add(b)
        #expect(store.audioBytes == 100)
    }

    @Test("A recording decodes with missing optional fields")
    func tolerantDecoding() throws {
        let id = UUID()
        let json = #"{"id": "\#(id.uuidString)", "audioFileName": "x.wav", "duration": 3.5}"#
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.duration == 3.5)
        #expect(decoded.status == .transcribed)
        #expect(decoded.title == "")
    }

    @Test("A recording without an id is not a recording")
    func missingID() {
        let json = #"{"audioFileName": "x.wav"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        }
    }

    @Test("Status round-trips, including the failure message")
    func statusCodable() throws {
        for status in [TranscriptStatus.transcribed, .nothingHeard, .pending, .failed("no model")] {
            let recording = Recording(duration: 1, status: status)
            let data = try JSONEncoder().encode(recording)
            let decoded = try JSONDecoder().decode(Recording.self, from: data)
            #expect(decoded.status == status)
        }
    }

    @Test("The display title is the user's, else the first words, else the date")
    func displayTitle() {
        let named = Recording(duration: 1, title: "Standup", transcript: "words here")
        #expect(named.displayTitle == "Standup")

        let derived = Recording(duration: 1, transcript: "Remember to move the dentist appointment, to Thursday.")
        #expect(derived.displayTitle == derived.createdAt.formatted(date: .abbreviated, time: .shortened),
                "a transcript alone does not name a recording")

        let empty = Recording(createdAt: Date(timeIntervalSince1970: 0), duration: 1)
        #expect(!empty.displayTitle.isEmpty)
    }
}
