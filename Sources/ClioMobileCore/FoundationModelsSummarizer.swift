#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device language model, iOS 26 and Apple Intelligence.
///
/// One session per request: a summary has no conversation to remember, and
/// a fresh session is what keeps one transcript from colouring the next.
/// Guided generation returns the title and summary as fields rather than
/// as prose to be parsed.
@available(iOS 26, macOS 26, *)
public actor FoundationModelsSummarizer: SummaryEngine {

    /// The two fields, and nothing about their shape: the shape is the
    /// instructions' business, so that the user's preferences — bullets,
    /// detailed, a meeting — are not quietly overruled by a guide that
    /// says "one to three sentences". They were, once.
    @Generable(description: "A title and notes for one voice recording, written as instructed.")
    struct Draft {
        @Guide(description: "The title, as the instructions describe it.")
        var title: String
        @Guide(description: "The notes, in the form and at the length the instructions ask for.")
        var summary: String
    }

    public init() {}

    public var availability: SummaryAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        }
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This phone does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Turn it on in Settings ▸ Apple Intelligence & Siri."
        case .modelNotReady:
            return "The language model is still being downloaded by iOS. Try again later."
        @unknown default:
            return "Apple Intelligence is not available right now."
        }
    }

    public func summarize(_ request: SummaryRequest) async throws -> TranscriptSummary {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw SummaryEngineError.unavailable(Self.describe(reason))
        }
        // Whisper knows the language; the model may not. Asking first gives
        // a sentence the user can act on instead of a generic failure.
        if let language = request.language, !model.supportsLocale(Locale(identifier: language)) {
            throw SummaryEngineError.unsupportedLanguage(TranscriptionLanguage.name(for: language))
        }

        // The shared prompt; the fields come back as fields, so no answer
        // form is asked for.
        let session = LanguageModelSession(
            model: model,
            instructions: SummaryPrompt.instructions(for: request.preferences, answerForm: false))
        let draft: Draft
        do {
            let response = try await session.respond(
                to: SummaryPrompt.prompt(for: request.transcript),
                generating: Draft.self,
                options: GenerationOptions(temperature: 0.3))
            draft = response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.friendly(error)
        }

        let title = SummaryPrompt.cleanTitle(draft.title)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !summary.isEmpty else { throw SummaryEngineError.empty }
        return TranscriptSummary(title: title, summary: summary)
    }

    /// The framework's own descriptions are written for developers. These
    /// are for the detail view.
    static func friendly(_ error: LanguageModelSession.GenerationError) -> Error {
        struct Message: LocalizedError {
            let errorDescription: String?
        }
        switch error {
        case .exceededContextWindowSize:
            return Message(errorDescription: "The transcript is too long for the on-device model.")
        case .unsupportedLanguageOrLocale:
            return Message(errorDescription: "The on-device model does not support this language yet.")
        case .guardrailViolation, .refusal:
            return Message(errorDescription: "The on-device model declined to summarize this recording.")
        case .rateLimited:
            return Message(errorDescription: "The on-device model is busy. Try again in a moment.")
        case .concurrentRequests:
            return Message(errorDescription: "Another summary is being written. Try again in a moment.")
        case .assetsUnavailable:
            return Message(errorDescription: "The on-device model is not on this phone yet. "
                           + "It downloads after Apple Intelligence is turned on; try again later.")
        case .decodingFailure:
            return Message(errorDescription: "The on-device model's answer could not be read. Try again.")
        case .unsupportedGuide:
            return Message(errorDescription: "The on-device model could not follow the summary format.")
        @unknown default:
            return Message(errorDescription: "The on-device model could not write a summary.")
        }
    }
}
#endif
