import ClioMobileCore
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A downloaded language model, run on the phone's GPU by MLX, for titles
/// and summaries where Apple's model is not there — or by choice.
///
/// Loads the model from the folder `ModelManager` installed it in and
/// nowhere else: `ModelConfiguration(directory:)`, so MLX never reaches
/// for Hugging Face on its own, which would quietly break the offline
/// promise. The prompt is `SummaryPrompt`'s, with the answer form, since a
/// text model gives text back; the answer is taken apart by
/// `SummaryPrompt.parse`.
///
/// Two answers, not one: the notes first, then a title for them. The
/// smallest model copied the placeholder of a two-part form as its title
/// or skipped the line; asked one thing at a time it manages both. The
/// second call is a short prompt and five words, a fraction of the first.
///
/// The model is loaded for each summary and released after: a gigabyte
/// of weights is not kept resident on a phone with four. The GPU buffer
/// cache is capped small for the same reason.
public actor MLXSummaryEngine: LocalSummaryEngine {

    private var container: ModelContainer?
    private var loadedID: String?

    public init() {}

    public nonisolated var deviceSupport: LanguageModelSupport.Verdict {
        LanguageModelSupport.device()
    }

    /// How many tokens the model may write. A detailed summary of a long
    /// recording is a few hundred; this is the backstop against a model
    /// that will not stop.
    static let maxTokens = 700

    public func summarize(_ request: SummaryRequest, using model: InstalledModel) async throws -> TranscriptSummary {
        #if targetEnvironment(simulator)
        throw SummaryEngineError.unavailable("Downloaded models do not run on the simulator.")
        #else
        if case .unsupported(let reason) = deviceSupport {
            throw SummaryEngineError.unavailable(reason)
        }
        let container = try await load(model)
        defer { Task { await self.unload() } }

        // The notes. Any "Title:" line the model adds of its own accord is
        // taken off by `parse`.
        let notesText = try await Self.generate(
            in: container,
            instructions: SummaryPrompt.instructions(for: request.preferences, answerForm: false),
            prompt: SummaryPrompt.prompt(for: request.transcript),
            maxTokens: Self.maxTokens)
        try Task.checkCancellation()
        var summary = SummaryPrompt.parse(notesText)
        guard !summary.summary.isEmpty else { throw SummaryEngineError.empty }

        // Then the title, for those notes.
        if summary.title.isEmpty {
            let titleText = try await Self.generate(
                in: container,
                instructions: SummaryPrompt.titleInstructions,
                prompt: SummaryPrompt.titlePrompt(forNotes: summary.summary,
                                                  transcript: request.transcript),
                maxTokens: 24)
            summary.title = SummaryPrompt.cleanTitle(titleText)
        }
        return summary
        #endif
    }

    /// One answer from the loaded model, thinking stripped.
    private static func generate(in container: ModelContainer, instructions: String,
                                 prompt: String, maxTokens: Int) async throws -> String {
        let text: String
        do {
            text = try await container.perform { context in
                let input = try await context.processor.prepare(
                    input: UserInput(
                        chat: [.system(instructions), .user(prompt)],
                        // Qwen3 thinks aloud unless told not to; other
                        // templates ignore the key.
                        additionalContext: ["enable_thinking": false]))
                let parameters = GenerateParameters(maxTokens: maxTokens,
                                                    temperature: 0.3, topP: 0.9,
                                                    repetitionPenalty: 1.1)
                let result: GenerateResult = try MLXLMCommon.generate(
                    input: input, parameters: parameters, context: context
                ) { (_: [Int]) -> GenerateDisposition in
                    Task.isCancelled ? .stop : .more
                }
                return result.output
            }
        } catch {
            throw friendly(error)
        }
        return strippingThinking(text)
    }

    public func unload() async {
        container = nil
        loadedID = nil
        MLX.GPU.clearCache()
    }

    private func load(_ model: InstalledModel) async throws -> ModelContainer {
        if let container, loadedID == model.id { return container }
        await unload()
        guard FileManager.default.fileExists(atPath: model.url.appendingPathComponent("config.json").path) else {
            throw SummaryEngineError.unavailable("\(model.displayName) is missing from this phone. Download it again.")
        }
        // Buffers MLX keeps for reuse: twenty megabytes, as its iOS notes
        // suggest, rather than the default of most of the GPU's working set.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        // Gemma ends its turn with a token its tokenizer config does not
        // list as end-of-sequence; without naming it the model runs on into
        // noise until the token cap. Harmless for a model that never emits it.
        let configuration = ModelConfiguration(directory: model.url,
                                               extraEOSTokens: ["<end_of_turn>", "<|im_end|>"])
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { _ in }
            container = loaded
            loadedID = model.id
            return loaded
        } catch {
            throw Self.friendly(error)
        }
    }

    /// `<think>…</think>`, which Qwen3 may still emit, and a turn marker
    /// that slipped through as text.
    static func strippingThinking(_ text: String) -> String {
        var clean = text
            .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</?think>", with: "", options: .regularExpression)
        // Anything after a stray end-of-turn is the model talking to itself.
        if let marker = clean.range(of: "<end_of_turn>") ?? clean.range(of: "<|im_end|>") {
            clean = String(clean[..<marker.lowerBound])
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// MLX's errors are for developers. A sentence for the detail view.
    static func friendly(_ error: Error) -> Error {
        if error is CancellationError || error is SummaryEngineError { return error }
        struct Message: LocalizedError { let errorDescription: String? }
        let text = String(describing: error).lowercased()
        if text.contains("memory") || text.contains("alloc") {
            return Message(errorDescription: "The phone ran out of memory for the model. Try a smaller one.")
        }
        return Message(errorDescription: "The downloaded model could not write a summary: \(error.localizedDescription)")
    }
}
