import Foundation
import Observation

/// The library: an index of recordings and the audio files beside it.
///
/// The index is one JSON file, written whole and atomically on every change.
/// Recordings are made one at a time by a person, so there is no write
/// pressure to speak of, and one file that is either complete or absent is
/// the simplest thing that survives a crash.
@MainActor
@Observable
public final class RecordingStore {

    /// Newest first.
    public private(set) var recordings: [Recording] = []
    /// Set when the last write failed, so About can show it.
    public private(set) var lastSaveError: String?

    private let indexURL: URL
    private let audioDirectory: URL

    public init(indexURL: URL = AppPaths.libraryFile,
                audioDirectory: URL = AppPaths.recordingsDirectory) {
        self.indexURL = indexURL
        self.audioDirectory = audioDirectory
        self.recordings = Self.load(from: indexURL)
    }

    /// For previews and tests: fixed contents, nothing on disk.
    public static func simulating(_ recordings: [Recording] = []) -> RecordingStore {
        let root = URL(fileURLWithPath: "/nonexistent-preview")
        let store = RecordingStore(indexURL: root.appendingPathComponent("recordings.json"),
                                   audioDirectory: root)
        store.recordings = recordings.sorted { $0.createdAt > $1.createdAt }
        return store
    }

    /// The same, with audio that plays: a tone per recording, as long as the
    /// recording says it is, in a temporary folder. For looking at playback
    /// and tap-to-seek on a simulator without a microphone. The index is
    /// still never written.
    public static func simulatingWithAudio(_ recordings: [Recording] = []) -> RecordingStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-simulated-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecordingStore(indexURL: root.appendingPathComponent("never-written.json"),
                                   audioDirectory: root)
        store.recordings = recordings.sorted { $0.createdAt > $1.createdAt }
        for recording in recordings where recording.duration > 0 {
            let url = store.audioURL(for: recording)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? AudioFiles.write(AudioFiles.tone(seconds: recording.duration), to: url)
        }
        return store
    }

    /// A recording with a synthesized tone for audio, so it plays and
    /// seeks like a real one. For the Developer page's sample data.
    public func addSample(_ recording: Recording) throws {
        try AudioFiles.write(AudioFiles.tone(seconds: recording.duration),
                             to: audioURL(for: recording))
        add(recording)
    }

    public subscript(id: Recording.ID) -> Recording? {
        recordings.first { $0.id == id }
    }

    /// Where a new recording's audio should be written, before it is added.
    public func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.audioFileName)
    }

    public func newAudioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).wav")
    }

    public func add(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.insert(recording, at: 0)
        recordings.sort { $0.createdAt > $1.createdAt }
        save()
    }

    public func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id })
        else { return }
        recordings[index] = recording
        save()
    }

    public func rename(_ id: Recording.ID, to title: String) {
        guard var recording = self[id] else { return }
        recording.title = title
        update(recording)
    }

    /// Removes the entry and its audio. The file goes first: an entry
    /// without a file is a broken row, a file without an entry is a leak,
    /// and of the two the leak is the one nobody sees.
    public func delete(_ id: Recording.ID) {
        guard let recording = self[id] else { return }
        try? FileManager.default.removeItem(at: audioURL(for: recording))
        recordings.removeAll { $0.id == id }
        save()
    }

    public func delete(_ recording: Recording) { delete(recording.id) }

    public func deleteAll() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: audioURL(for: recording))
        }
        recordings = []
        save()
    }

    /// Bytes of audio on disk, for About.
    public var audioBytes: Int64 {
        recordings.reduce(0) { total, recording in
            let size = (try? audioURL(for: recording)
                .resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return total + Int64(size ?? 0)
        }
    }

    // MARK: Persistence

    private static func load(from url: URL) -> [Recording] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([Recording].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recordings)
            try data.write(to: indexURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}
