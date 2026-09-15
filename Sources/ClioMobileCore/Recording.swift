import Foundation

/// One recording in the library: the audio file on disk and what Whisper
/// made of it.
public struct Recording: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: TimeInterval
    public var title: String
    public var transcript: String
    /// What the model heard the language as, ISO 639-1.
    public var language: String?
    /// Which model produced the transcript — so a later, better model can
    /// be offered as "re-transcribe" and the About numbers add up.
    public var modelID: String?
    /// From the on-device language model (milestone 3). Nil until made,
    /// and on phones that cannot make one.
    public var summary: String?
    /// Also from the model. Shown when the user has not named the
    /// recording; never overwrites a name they typed.
    public var generatedTitle: String?
    /// The transcript with times, for tap-to-seek. Empty for recordings
    /// made before there were any, and the transcript text still stands.
    public var segments: [TranscriptSegment]
    /// The file name inside `AppPaths.recordingsDirectory`. Relative on
    /// purpose: the sandbox container moves between installs and backups,
    /// so an absolute path stored today is wrong tomorrow.
    public var audioFileName: String
    public var status: TranscriptStatus
    /// Where it was made, when Settings ▸ Recording asks for it.
    public var location: RecordingLocation?

    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                duration: TimeInterval,
                title: String = "",
                transcript: String = "",
                language: String? = nil,
                modelID: String? = nil,
                summary: String? = nil,
                generatedTitle: String? = nil,
                segments: [TranscriptSegment] = [],
                audioFileName: String? = nil,
                status: TranscriptStatus = .transcribed,
                location: RecordingLocation? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.title = title
        self.transcript = transcript
        self.language = language
        self.modelID = modelID
        self.summary = summary
        self.generatedTitle = generatedTitle
        self.segments = segments
        self.audioFileName = audioFileName ?? "\(id.uuidString).wav"
        self.status = status
        self.location = location
    }

    /// Field by field, like `Settings`. A recording index that will not
    /// decode is every recording the user has, gone from the list at once.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Two fields have no sensible default. Without them the entry is
        // not a recording, and the decoder's own error is the right one.
        id = try container.decode(UUID.self, forKey: .id)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func readOptional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        createdAt = read(.createdAt, Date())
        duration = read(.duration, 0)
        title = read(.title, "")
        transcript = read(.transcript, "")
        language = readOptional(.language, String.self)
        modelID = readOptional(.modelID, String.self)
        summary = readOptional(.summary, String.self)
        generatedTitle = readOptional(.generatedTitle, String.self)
        segments = read(.segments, [])
        status = read(.status, .transcribed)
        location = readOptional(.location, RecordingLocation.self)
    }

    /// What the list shows.
    ///
    /// The user's own name first; then the one the language model wrote;
    /// then the first few words of the transcript, because "Recording 14"
    /// tells nobody which one it was. Falls back to the date.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generated.isEmpty { return generated }
        // No name typed and none generated: the date and time, not the
        // first words of the transcript, which read as a title and are not.
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }


    /// One line for the list row: the transcript collapsed, or what
    /// happened instead.
    public var snippet: String {
        switch status {
        case .transcribed:
            let collapsed = transcript
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "No transcript" : collapsed
        case .nothingHeard:
            return "Nothing was heard"
        case .pending:
            return "Not transcribed yet"
        case .failed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

public enum TranscriptStatus: Codable, Equatable, Hashable, Sendable {
    case transcribed
    /// The recording was fine; nobody said anything in it.
    case nothingHeard
    /// Saved without a transcript — the engine was not ready, or the user
    /// chose to keep the audio after a failure. Re-transcribe later.
    case pending
    case failed(String)

    public var needsTranscription: Bool {
        switch self {
        case .transcribed, .nothingHeard: return false
        case .pending, .failed: return true
        }
    }
}
