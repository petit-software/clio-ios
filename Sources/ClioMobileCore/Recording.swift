import Foundation

/// One recording in the library: one or more stretches of audio on disk,
/// stacked in the order they were made, and what Whisper made of each.
///
/// Most recordings are one part. More are added by recording again from
/// inside one, or by merging several from the list; each keeps its own
/// audio and its own transcript, and the title and summary cover them all.
public struct Recording: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    /// From the on-device language model (milestone 3). Nil until made,
    /// and on phones that cannot make one.
    public var summary: String?
    /// Also from the model. Shown when the user has not named the
    /// recording; never overwrites a name they typed.
    public var generatedTitle: String?
    /// Where it was made, when Settings ▸ Recording asks for it.
    public var location: RecordingLocation?
    /// Oldest first. Never empty.
    public var parts: [RecordingPart]

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
        self.title = title
        self.summary = summary
        self.generatedTitle = generatedTitle
        self.location = location
        self.parts = [RecordingPart(id: id,
                                    createdAt: createdAt,
                                    duration: duration,
                                    transcript: transcript,
                                    language: language,
                                    modelID: modelID,
                                    segments: segments,
                                    audioFileName: audioFileName ?? "\(id.uuidString).wav",
                                    status: status)]
    }

    /// Field by field, like `Settings`. A recording index that will not
    /// decode is every recording the user has, gone from the list at once.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Two fields have no sensible default. Without them the entry is
        // not a recording, and the decoder's own error is the right one.
        id = try container.decode(UUID.self, forKey: .id)
        let audioFileName = try container.decode(String.self, forKey: .audioFileName)

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func readOptional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        createdAt = read(.createdAt, Date())
        title = read(.title, "")
        summary = readOptional(.summary, String.self)
        generatedTitle = readOptional(.generatedTitle, String.self)
        location = readOptional(.location, RecordingLocation.self)

        // Written before there were parts, the entry is its one part.
        let stored = read(.parts, [RecordingPart]())
        parts = stored.isEmpty
            ? [RecordingPart(id: id,
                             createdAt: createdAt,
                             duration: read(.duration, 0),
                             transcript: read(.transcript, ""),
                             language: readOptional(.language, String.self),
                             modelID: readOptional(.modelID, String.self),
                             segments: read(.segments, []),
                             audioFileName: audioFileName,
                             status: read(.status, .transcribed))]
            : stored
    }

    /// The parts, and beside them the flat fields a build from before parts
    /// reads — so going back a version shows the first part's audio and all
    /// of the text, rather than an empty list.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(generatedTitle, forKey: .generatedTitle)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(parts, forKey: .parts)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encode(duration, forKey: .duration)
        try container.encode(transcript, forKey: .transcript)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(parts.count == 1 ? segments : [], forKey: .segments)
        try container.encode(status, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, summary, generatedTitle, location, parts
        case audioFileName, duration, transcript, language, modelID, segments, status
    }

    // MARK: Across the parts
    //
    // Read across every part. Set, they write the first — which for a
    // recording of one part, nearly all of them, is the recording.

    /// All of it, end to end.
    public var duration: TimeInterval {
        get { parts.reduce(0) { $0 + $1.duration } }
        set { parts[0].duration = newValue }
    }

    /// Every part's text, a paragraph each. What is searched, summarized,
    /// shared and copied.
    public var transcript: String {
        get {
            parts.map(\.transcript)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        set { parts[0].transcript = newValue }
    }

    /// What the model heard the language as, ISO 639-1: the first part's
    /// that has one.
    public var language: String? {
        get { parts.lazy.compactMap(\.language).first }
        set { parts[0].language = newValue }
    }

    /// Which model produced the transcript — so a later, better model can
    /// be offered as "re-transcribe" and the About numbers add up. The
    /// newest part's.
    public var modelID: String? {
        get { parts.lazy.compactMap(\.modelID).last }
        set { parts[0].modelID = newValue }
    }

    /// The transcript with times, for tap-to-seek, when there is one part.
    /// Times belong to a part's own audio, so across several there is no
    /// one list that means anything; each part has its own.
    public var segments: [TranscriptSegment] {
        get { parts.count == 1 ? parts[0].segments : [] }
        set { parts[0].segments = newValue }
    }

    /// The first part's audio file.
    public var audioFileName: String {
        get { parts[0].audioFileName }
        set { parts[0].audioFileName = newValue }
    }

    /// Transcribed if any part has words in it; otherwise the first part
    /// still waiting or failed; otherwise nothing was heard in any of them.
    public var status: TranscriptStatus {
        get {
            if parts.count == 1 { return parts[0].status }
            if parts.contains(where: { $0.status == .transcribed }) { return .transcribed }
            if let waiting = parts.first(where: { $0.status.needsTranscription }) {
                return waiting.status
            }
            return .nothingHeard
        }
        set { parts[0].status = newValue }
    }

    /// Several recordings as one: every part, oldest first, under the
    /// oldest one's id, date, name and place. The oldest's summary and
    /// generated title stand until the language model writes them again
    /// over the whole.
    public static func merging(_ recordings: [Recording]) -> Recording? {
        let ordered = recordings.sorted { $0.createdAt < $1.createdAt }
        guard var merged = ordered.first else { return nil }
        guard ordered.count > 1 else { return merged }
        merged.parts = ordered.flatMap(\.parts)
        // A name the user typed on the first is kept; failing that, the
        // first name typed on any of them.
        if merged.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.title = ordered.first {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.title ?? ""
        }
        merged.location = merged.location ?? ordered.lazy.compactMap(\.location).first
        return merged
    }

    /// The other way: each part a recording of its own, with its own date.
    /// The first keeps this one's id, name and place, so it stays where it
    /// was in the list and anything pointing at it still finds it.
    public func splitting() -> [Recording] {
        guard parts.count > 1 else { return [self] }
        return parts.enumerated().map { index, part in
            var single = self
            single.parts = [part]
            single.summary = nil
            single.generatedTitle = nil
            if index > 0 {
                single.id = part.id == id ? UUID() : part.id
                single.createdAt = part.createdAt
                single.title = ""
            }
            return single
        }
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

/// One stretch of audio in a recording and its transcript. A recording
/// made in one go is one of these; recording again inside it, or merging
/// others into it, adds more.
public struct RecordingPart: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: TimeInterval
    public var transcript: String
    public var language: String?
    public var modelID: String?
    /// Times relative to this part's own audio file.
    public var segments: [TranscriptSegment]
    /// Inside `AppPaths.recordingsDirectory`, relative for the reason
    /// `Recording` gives.
    public var audioFileName: String
    public var status: TranscriptStatus

    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                duration: TimeInterval,
                transcript: String = "",
                language: String? = nil,
                modelID: String? = nil,
                segments: [TranscriptSegment] = [],
                audioFileName: String? = nil,
                status: TranscriptStatus = .pending) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.transcript = transcript
        self.language = language
        self.modelID = modelID
        self.segments = segments
        self.audioFileName = audioFileName ?? "\(id.uuidString).wav"
        self.status = status
    }

    /// Tolerant, like `Recording`: one bad field is a default, not a lost
    /// library.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = read(.id, UUID())
        createdAt = read(.createdAt, Date())
        duration = read(.duration, 0)
        transcript = read(.transcript, "")
        language = (try? container.decodeIfPresent(String.self, forKey: .language)) ?? nil
        modelID = (try? container.decodeIfPresent(String.self, forKey: .modelID)) ?? nil
        segments = read(.segments, [])
        status = read(.status, .transcribed)
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
