import Foundation

/// What kind of note a recording is, as the user has told Settings. Each
/// type is one extra line of the shared prompt — see `SummaryPrompt` — so
/// a meeting's summary separates decisions from open questions and a list
/// of ideas is kept as the ideas it was.
public enum NoteType: String, Codable, CaseIterable, Sendable {
    case general
    case meeting
    case ideas
    case todo
    case journal

    public var name: String {
        switch self {
        case .general: "Notes"
        case .meeting: "Meeting"
        case .ideas: "Ideas"
        case .todo: "To-dos"
        case .journal: "Journal"
        }
    }
}

/// The shape of the summary.
public enum SummaryFormat: String, Codable, CaseIterable, Sendable {
    case paragraphs
    case bullets
    case numbered

    public var name: String {
        switch self {
        case .paragraphs: "Paragraphs"
        case .bullets: "Bullet points"
        case .numbered: "Numbered list"
        }
    }
}

/// How much of the transcript the summary keeps.
public enum SummaryLength: String, Codable, CaseIterable, Sendable {
    case brief
    case standard
    case detailed

    public var name: String {
        switch self {
        case .brief: "Brief"
        case .standard: "Standard"
        case .detailed: "Detailed"
        }
    }
}

/// Everything the user has said about how summaries should read, in one
/// place, so a new preference is a field here and a line in the prompt and
/// nothing else. Stored inside `Settings`; decoded field by field like it,
/// for the same reason.
public struct SummaryPreferences: Codable, Equatable, Sendable {
    public var noteType: NoteType = .general
    public var format: SummaryFormat = .paragraphs
    public var length: SummaryLength = .standard
    /// The user's own instructions, added after the built-in rules. They
    /// refine what the model writes; they never replace the rules, so a
    /// summary cannot be talked out of staying faithful to the transcript.
    /// Empty is the common case.
    public var instructions: String = ""

    public init(noteType: NoteType = .general,
                format: SummaryFormat = .paragraphs,
                length: SummaryLength = .standard,
                instructions: String = "") {
        self.noteType = noteType
        self.format = format
        self.length = length
        self.instructions = instructions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SummaryPreferences()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        noteType = read(.noteType, defaults.noteType)
        format = read(.format, defaults.format)
        length = read(.length, defaults.length)
        instructions = read(.instructions, defaults.instructions)
    }

    /// The user's additions, trimmed; nil when they have written none.
    public var trimmedInstructions: String? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
