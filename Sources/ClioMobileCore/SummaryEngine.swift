import Foundation

/// What the language model makes of a transcript: a name for the list and
/// a few sentences for the detail view.
public struct TranscriptSummary: Sendable, Equatable {
    public var title: String
    public var summary: String

    public init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }
}

/// Whether the phone can do this at all, and if not, why — in words the
/// Settings footer can show.
public enum SummaryAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

public enum SummaryEngineError: LocalizedError, Equatable {
    case unavailable(String)
    case unsupportedLanguage(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .unsupportedLanguage(let name):
            return "The on-device model does not support \(name) yet."
        case .empty:
            return "The model returned nothing."
        }
    }
}

/// The seam Apple Foundation Models goes behind.
///
/// The same idea as `TranscriptionEngine`: the app is complete without it,
/// previews run on a stub, and a phone that cannot run the model gets a
/// reason rather than a crash.
public protocol SummaryEngine: AnyObject, Sendable {
    var availability: SummaryAvailability { get async }
    /// `instructions` is the system prompt — the user's, from Settings, or
    /// `SummaryPrompt.defaultInstructions` when they have not written one.
    func summarize(_ transcript: String, language: String?,
                   instructions: String) async throws -> TranscriptSummary
}

public extension SummaryEngine {
    /// The built-in instructions, for a caller with no settings to hand.
    func summarize(_ transcript: String, language: String?) async throws -> TranscriptSummary {
        try await summarize(transcript, language: language,
                            instructions: SummaryPrompt.defaultInstructions)
    }
}

/// What is sent to the model, kept in one place so the prompt is testable
/// without a model, and so the limits are numbers with names.
public enum SummaryPrompt {

    /// Fewer words than this and the first line of the transcript is
    /// already the best title there is; a summary would be longer than
    /// the recording.
    public static let minimumWords = 12

    /// The on-device model has a context window of about 4,000 tokens for
    /// instructions, prompt and answer together. A ten-minute recording
    /// is about 1,500 words — comfortably under — but a transcript that
    /// somehow is not gets its tail cut rather than an error.
    public static let maxCharacters = 10_000

    public static func isWorthSummarizing(_ transcript: String) -> Bool {
        wordCount(transcript) >= minimumWords
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Cut at a word boundary, with a marker so the model knows it is
    /// looking at the beginning of something longer.
    public static func clip(_ transcript: String, to limit: Int = maxCharacters) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = trimmed.prefix(limit)
        let cut = head.lastIndex(where: { $0.isWhitespace }) ?? head.endIndex
        return String(head[..<cut]) + " …"
    }

    /// What the model is told before it sees a transcript. The user can
    /// write their own in Settings ▸ Intelligence; this is what they start
    /// from and what Reset puts back.
    public static let defaultInstructions = """
        You write titles and summaries for voice memos. You are given the \
        transcript of one recording. Write in the same language as the \
        transcript. The title is at most six words, with no quotation marks \
        and no full stop at the end. The summary is one to three plain \
        sentences saying what was said, with no preamble such as "The \
        speaker says". Do not add anything that is not in the transcript.
        """

    /// The user's instructions, or the built-in ones when they have left
    /// the field alone. Stored empty rather than as a copy of the default,
    /// so a better default reaches anyone who has not written their own.
    public static func instructions(_ custom: String) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultInstructions : trimmed
    }

    public static func prompt(for transcript: String) -> String {
        "Transcript:\n\n" + clip(transcript)
    }

    /// Models put quotes and full stops on titles however firmly they are
    /// told not to. Removed here, once, rather than argued with.
    public static func cleanTitle(_ raw: String) -> String {
        var title = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "«", "»"]
        while let first = title.first, quotes.contains(first) { title.removeFirst() }
        while let last = title.last, quotes.contains(last) || last == "." { title.removeLast() }
        // Five words at most: a title, not a sentence.
        return title
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(5)
            .joined(separator: " ")
    }
}

/// Stands in for Foundation Models in previews and tests, and on the
/// simulator when the host has no Apple Intelligence.
///
/// Says so in what it returns, for the same reason the stub transcriber
/// does: a made-up summary that reads like a real one would hide a broken
/// path.
public actor StubSummaryEngine: SummaryEngine {
    private let available: SummaryAvailability
    private let latency: Duration
    private let failure: Error?

    public init(availability: SummaryAvailability = .available,
                latency: Duration = .milliseconds(300),
                failure: Error? = nil) {
        self.available = availability
        self.latency = latency
        self.failure = failure
    }

    public var availability: SummaryAvailability { available }

    /// What the last call was told, so a test can check the user's own
    /// instructions reach the model.
    public private(set) var lastInstructions: String?

    public func summarize(_ transcript: String, language: String?,
                          instructions: String) async throws -> TranscriptSummary {
        lastInstructions = instructions
        try await Task.sleep(for: latency)
        if let failure { throw failure }
        let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let title = "[Stub] " + words.prefix(3).joined(separator: " ")
        let summary = "[Clio stub] \(words.count) words"
            + (language.map { " of \($0)" } ?? "")
            + " summarised. The on-device model writes the real one."
        return TranscriptSummary(title: title, summary: summary)
    }
}

/// The engine on a phone that cannot run the model: iOS 18 and 25, where
/// the framework does not exist. Every call fails with the reason.
public actor UnavailableSummaryEngine: SummaryEngine {
    private let reason: String

    public init(reason: String = "Titles and summaries need iOS 26 and Apple Intelligence.") {
        self.reason = reason
    }

    public var availability: SummaryAvailability { .unavailable(reason: reason) }

    public func summarize(_ transcript: String, language: String?,
                          instructions: String) async throws -> TranscriptSummary {
        throw SummaryEngineError.unavailable(reason)
    }
}

public enum SummaryEngines {
    /// The real one where the framework exists, the unavailable one where
    /// it does not. Whether Apple Intelligence is actually on is a runtime
    /// question the real engine answers through `availability`.
    public static func live() -> any SummaryEngine {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return FoundationModelsSummarizer()
        }
        #endif
        return UnavailableSummaryEngine()
    }
}
