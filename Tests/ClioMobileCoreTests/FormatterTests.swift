import Testing
@testable import ClioMobileCore

@Suite("Transcript formatter")
struct FormatterTests {

    @Test("Capitalises the first letter and trims trailing punctuation when asked")
    func basics() {
        var settings = Settings()
        settings.trimTrailingPunctuation = true
        #expect(TranscriptFormatter.format("  hello there.  ", settings: settings) == "Hello there")

        settings.trimTrailingPunctuation = false
        settings.capitalizeFirstLetter = false
        #expect(TranscriptFormatter.format("hello there.", settings: settings) == "hello there.")
    }

    @Test("Replacements are whole-word and case-insensitive")
    func replacements() {
        var settings = Settings()
        settings.wordReplacements = [WordReplacement(find: "it", replace: "IT")]
        #expect(TranscriptFormatter.format("with it, It works", settings: settings)
                == "With IT, IT works")
    }

    @Test("Empty rules and empty text are harmless")
    func edges() {
        var settings = Settings()
        settings.wordReplacements = [WordReplacement(find: "  ", replace: "x")]
        #expect(TranscriptFormatter.format("", settings: settings) == "")
        #expect(TranscriptFormatter.format("fine", settings: settings) == "Fine")
    }

    @Test("Vocabulary becomes a comma-separated prompt, or nothing")
    func prompt() {
        #expect(TranscriptFormatter.initialPrompt(from: [" Clio ", "", "WhisperKit"]) == "Clio, WhisperKit")
        #expect(TranscriptFormatter.initialPrompt(from: ["", " "]) == nil)
    }
}
