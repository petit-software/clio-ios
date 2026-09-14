import Foundation

/// The post-processing between "Whisper said this" and "this is the
/// transcript". Pure, so it can be tested directly. Copied from the Mac app.
public enum TranscriptFormatter {

    public static func format(_ text: String, settings: Settings) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        result = applyReplacements(result, settings.wordReplacements)

        if settings.trimTrailingPunctuation {
            while let last = result.last, last == "." || last == "," {
                result.removeLast()
            }
        }

        if settings.capitalizeFirstLetter, let first = result.first {
            result.replaceSubrange(result.startIndex...result.startIndex,
                                   with: String(first).uppercased())
        }

        return result
    }

    /// The same rules over a transcript that comes in pieces: replacements
    /// in every piece, the capital on the first, the trailing punctuation
    /// off the last. The joined text is what `format(_:settings:)` would
    /// have made of the whole, give or take whitespace.
    public static func format(_ segments: [TranscriptSegment],
                              settings: Settings) -> [TranscriptSegment] {
        var result = segments.compactMap { segment -> TranscriptSegment? in
            var copy = segment
            copy.text = applyReplacements(
                segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                settings.wordReplacements)
            return copy.text.isEmpty ? nil : copy
        }
        guard !result.isEmpty else { return result }

        if settings.trimTrailingPunctuation {
            var last = result[result.count - 1].text
            while let end = last.last, end == "." || end == "," { last.removeLast() }
            result[result.count - 1].text = last
            if last.isEmpty { result.removeLast() }
        }
        guard !result.isEmpty else { return result }

        if settings.capitalizeFirstLetter, let first = result[0].text.first {
            result[0].text.replaceSubrange(result[0].text.startIndex...result[0].text.startIndex,
                                           with: String(first).uppercased())
        }
        return result
    }

    /// `<|0.00|>`, `<|en|>`, `<|transcribe|>` and their kind, which Whisper
    /// emits inside segment text and nobody wants to read.
    public static func strippingSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole-word, case-insensitive. Substring replacement would turn a rule
    /// like "it" → "IT" into a mess inside words such as "with".
    static func applyReplacements(_ text: String,
                                  _ replacements: [WordReplacement]) -> String {
        var result = text
        for rule in replacements {
            let find = rule.find.trimmingCharacters(in: .whitespaces)
            guard !find.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: find))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive])
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replace))
        }
        return result
    }

    /// Custom vocabulary becomes Whisper's `initialPrompt` — the cheapest
    /// way to make it spell names and jargon correctly.
    public static func initialPrompt(from vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }
}
