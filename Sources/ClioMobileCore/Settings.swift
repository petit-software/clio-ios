import Foundation

/// One typed struct, one JSON file.
///
/// Adapted from the Mac app's `Settings`: the hotkey, the pill, the output
/// and the input device are gone — none of them exist on a phone — and what
/// is left is what shapes a recording and its transcript.
public struct Settings: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1

    // Model
    public var activeModelID: String? = nil
    public var keepModelInMemory: Bool = true

    // Recording
    public var voiceActivityDetection: Bool = true
    public var vadSensitivity: Double = 0.5
    /// Ten minutes; the Settings stepper goes to thirty. The recorder holds
    /// this many seconds of Float32 at 16 kHz — 38 MB at ten minutes,
    /// 115 MB at thirty — while recording.
    public var maxRecordingSeconds: Double = 600
    public var hapticFeedback: Bool = true
    /// Off: tapping Record opens the recording sheet. On: recording runs
    /// while the finger is on the button and stops when it lifts — no
    /// sheet, the button itself is the recorder.
    public var holdToRecord: Bool = false
    /// Where each recording was made is saved with it.
    public var includeLocation: Bool = false

    // Transcription
    /// `nil` means auto-detect.
    public var language: String? = nil
    public var translateToEnglish: Bool = false
    /// A finished transcript goes to the clipboard on its own.
    public var autoCopyTranscript: Bool = false
    /// The first-run sheet has been seen.
    public var introShown: Bool = false
    /// Light, dark, or whatever the phone is set to.
    public var appearance: Appearance = .system
    public var customVocabulary: [String] = []
    public var wordReplacements: [WordReplacement] = []

    // Text
    public var trimTrailingPunctuation: Bool = false
    public var capitalizeFirstLetter: Bool = true

    // Intelligence (milestone 3)
    /// Titles and summaries from the on-device language model, when the
    /// phone has one. Off does nothing; on does nothing until M3.
    public var generateSummaries: Bool = true
    /// What the language model is told before it is shown a transcript.
    /// Empty means the built-in instructions — see `SummaryPrompt` — kept
    /// empty rather than filled with a copy of them, so a better default
    /// reaches anyone who has not written their own.
    public var summaryInstructions: String = ""

    public init() {}

    /// Decoded field by field, falling back to the default for anything
    /// absent or unreadable.
    ///
    /// Swift's synthesized decoder throws for a missing key even when the
    /// property has a default. Every field added to this struct would make
    /// every existing settings file undecodable, and the user would lose all
    /// of their preferences to gain one. The Mac app shipped that twice.
    /// Add new fields here, not only above.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func readOptional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        schemaVersion = read(.schemaVersion, defaults.schemaVersion)

        activeModelID = readOptional(.activeModelID, String.self)
        keepModelInMemory = read(.keepModelInMemory, defaults.keepModelInMemory)

        voiceActivityDetection = read(.voiceActivityDetection,
                                      defaults.voiceActivityDetection)
        vadSensitivity = min(1, max(0, read(.vadSensitivity, defaults.vadSensitivity)))
        maxRecordingSeconds = read(.maxRecordingSeconds, defaults.maxRecordingSeconds)
        hapticFeedback = read(.hapticFeedback, defaults.hapticFeedback)
        holdToRecord = read(.holdToRecord, defaults.holdToRecord)
        includeLocation = read(.includeLocation, defaults.includeLocation)

        language = readOptional(.language, String.self)
        translateToEnglish = read(.translateToEnglish, defaults.translateToEnglish)
        autoCopyTranscript = read(.autoCopyTranscript, defaults.autoCopyTranscript)
        introShown = read(.introShown, defaults.introShown)
        appearance = read(.appearance, defaults.appearance)
        customVocabulary = read(.customVocabulary, defaults.customVocabulary)
        wordReplacements = read(.wordReplacements, defaults.wordReplacements)

        trimTrailingPunctuation = read(.trimTrailingPunctuation,
                                       defaults.trimTrailingPunctuation)
        capitalizeFirstLetter = read(.capitalizeFirstLetter,
                                     defaults.capitalizeFirstLetter)

        generateSummaries = read(.generateSummaries, defaults.generateSummaries)
        summaryInstructions = read(.summaryInstructions, defaults.summaryInstructions)
    }
}

public struct WordReplacement: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var find: String
    public var replace: String

    public init(id: UUID = UUID(), find: String = "", replace: String = "") {
        self.id = id
        self.find = find
        self.replace = replace
    }
}

/// The maximum recording length, as the user sets it.
///
/// Stored in seconds because that is what the recorder works in, but chosen
/// in minutes: nobody sets a recording limit to the second.
/// Settings ▸ Appearance.
public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var name: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum RecordingLimit {
    public static let range: ClosedRange<Double> = 1...30

    public static func minutes(seconds: Double) -> Double {
        let whole = (seconds / 60).rounded()
        return min(range.upperBound, max(range.lowerBound, whole))
    }

    public static func seconds(minutes: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, minutes)) * 60
    }

    public static func label(seconds: Double) -> String {
        let value = Int(minutes(seconds: seconds))
        return value == 1 ? "1 minute" : "\(value) minutes"
    }
}

/// The languages the Settings picker offers.
///
/// Whisper knows ninety-nine; these are the ones worth a row. Auto-detect
/// is the default and is `nil` in `Settings.language`.
public struct TranscriptionLanguage: Identifiable, Sendable, Equatable {
    public var id: String   // ISO 639-1, what Whisper takes
    public var name: String

    public static let all: [TranscriptionLanguage] = [
        .init(id: "en", name: "English"),
        .init(id: "nl", name: "Dutch"),
        .init(id: "de", name: "German"),
        .init(id: "fr", name: "French"),
        .init(id: "es", name: "Spanish"),
        .init(id: "it", name: "Italian"),
        .init(id: "pt", name: "Portuguese"),
        .init(id: "pl", name: "Polish"),
        .init(id: "sv", name: "Swedish"),
        .init(id: "da", name: "Danish"),
        .init(id: "nb", name: "Norwegian"),
        .init(id: "ja", name: "Japanese"),
        .init(id: "zh", name: "Chinese"),
        .init(id: "ko", name: "Korean"),
        .init(id: "uk", name: "Ukrainian"),
        .init(id: "tr", name: "Turkish"),
    ]

    public static func name(for code: String?) -> String {
        guard let code else { return "Auto-detect" }
        return all.first { $0.id == code }?.name
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }
}
