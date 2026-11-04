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

    /// Newest first. The demo set while demo mode is on, the library
    /// otherwise.
    public var recordings: [Recording] {
        get { demo ?? stored }
        set {
            if demo != nil { demo = newValue } else { stored = newValue }
        }
    }
    /// The user's own, on disk.
    private var stored: [Recording] = []
    /// Sample recordings standing in for the user's, in memory only. Every
    /// change made while it is set lands here and is gone with it; the
    /// index on disk is not written.
    private var demo: [Recording]?
    /// Set when the last write failed, so About can show it.
    public private(set) var lastSaveError: String?

    private let indexURL: URL
    private let audioDirectory: URL

    public init(indexURL: URL = AppPaths.libraryFile,
                audioDirectory: URL = AppPaths.recordingsDirectory) {
        self.indexURL = indexURL
        self.audioDirectory = audioDirectory
        self.stored = Self.load(from: indexURL)
    }

    /// Demo mode on: the sample set stands in for the library. Off: the
    /// library is back as it was, untouched.
    public func useDemo(_ sample: [Recording]?) {
        demo = sample?.sorted { $0.createdAt > $1.createdAt }
    }

    public var isDemo: Bool { demo != nil }

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
        for part in recordings.flatMap(\.parts) where part.duration > 0 {
            let url = store.audioURL(for: part)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? AudioFiles.write(AudioFiles.tone(seconds: part.duration), to: url)
        }
        return store
    }

    /// A recording with a synthesized tone for audio, so it plays and
    /// seeks like a real one. For the Developer page's sample data.
    public func addSample(_ recording: Recording) throws {
        for part in recording.parts {
            try AudioFiles.write(AudioFiles.tone(seconds: part.duration),
                                 to: audioURL(for: part))
        }
        add(recording)
    }

    public subscript(id: Recording.ID) -> Recording? {
        recordings.first { $0.id == id }
    }

    /// The first part's audio. For a recording of one part, its audio.
    public func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.audioFileName)
    }

    public func audioURL(for part: RecordingPart) -> URL {
        audioDirectory.appendingPathComponent(part.audioFileName)
    }

    /// Every part's audio, oldest first.
    public func audioURLs(for recording: Recording) -> [URL] {
        recording.parts.map(audioURL(for:))
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
        if demo == nil {
            for url in audioURLs(for: recording) { try? FileManager.default.removeItem(at: url) }
        }
        recordings.removeAll { $0.id == id }
        save()
    }

    public func delete(_ recording: Recording) { delete(recording.id) }

    public func deleteAll() {
        if demo == nil {
            for url in recordings.flatMap(audioURLs(for:)) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        recordings = []
        save()
    }

    /// Bytes of audio on disk, for About.
    public var audioBytes: Int64 {
        recordings.reduce(0) { $0 + audioBytes(of: $1) }
    }

    public func audioBytes(of recording: Recording) -> Int64 {
        audioURLs(for: recording).reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return total + Int64(size ?? 0)
        }
    }

    // MARK: Parts

    /// A new part at the end of a recording: recorded again from inside it.
    /// False if the recording has gone in the meantime, and the part's audio
    /// has nowhere to belong.
    @discardableResult
    public func append(_ part: RecordingPart, to id: Recording.ID) -> Bool {
        guard var recording = self[id] else { return false }
        recording.parts.append(part)
        update(recording)
        return true
    }

    /// A part's words landed, or changed: the part with that id is written
    /// over. Nothing happens if the recording has gone in the meantime —
    /// its audio went with it.
    public func replace(_ part: RecordingPart, in id: Recording.ID) {
        guard var recording = self[id],
              let index = recording.parts.firstIndex(where: { $0.id == part.id })
        else { return }
        recording.parts[index] = part
        update(recording)
    }

    /// A part out again, audio and all. The only part takes the recording
    /// with it.
    public func removePart(_ partID: RecordingPart.ID, from id: Recording.ID) {
        guard var recording = self[id],
              let index = recording.parts.firstIndex(where: { $0.id == partID })
        else { return }
        if demo == nil { try? FileManager.default.removeItem(at: audioURL(for: recording.parts[index])) }
        if recording.parts.count == 1 {
            recordings.removeAll { $0.id == id }
            save()
            return
        }
        recording.parts.remove(at: index)
        update(recording)
    }

    /// Several recordings as one, under the oldest's id. Nothing is deleted
    /// from disk: every file is a part of the merged recording now. Returns
    /// the merged recording's id.
    @discardableResult
    public func merge(_ ids: some Collection<Recording.ID>) -> Recording.ID? {
        let chosen = recordings.filter { ids.contains($0.id) }
        guard chosen.count > 1, let merged = Recording.merging(chosen) else { return nil }
        let absorbed = Set(chosen.map(\.id)).subtracting([merged.id])
        recordings.removeAll { absorbed.contains($0.id) }
        update(merged)
        return merged.id
    }

    /// Each part its own recording again. The audio stays where it is.
    /// Returns the ids, oldest first.
    @discardableResult
    public func split(_ id: Recording.ID) -> [Recording.ID] {
        guard let recording = self[id], recording.parts.count > 1 else { return [] }
        let singles = recording.splitting()
        recordings.removeAll { $0.id == id }
        recordings.append(contentsOf: singles)
        recordings.sort { $0.createdAt > $1.createdAt }
        save()
        return singles.map(\.id)
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
        // Nothing of the demo set is written.
        guard demo == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try data.write(to: indexURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}
