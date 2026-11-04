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

        let instructions = SummaryPrompt.instructions(for: request.preferences, answerForm: true)
        let prompt = SummaryPrompt.prompt(for: request.transcript)
        let text: String
        do {
            text = try await container.perform { context in
                let input = try await context.processor.prepare(
                    input: UserInput(
                        chat: [.system(instructions), .user(prompt)],
                        // Qwen3 thinks aloud unless told not to; other
                        // templates ignore the key.
                        additionalContext: ["enable_thinking": false]))
                let parameters = GenerateParameters(maxTokens: Self.maxTokens,
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
            throw Self.friendly(error)
        }
        try Task.checkCancellation()

        let summary = SummaryPrompt.parse(Self.strippingThinking(text))
        guard !summary.title.isEmpty || !summary.summary.isEmpty else {
            throw SummaryEngineError.empty
        }
        return summary
        #endif
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
        let configuration = ModelConfiguration(directory: model.url)
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { _ in }
            container = loaded
            loadedID = model.id
            return loaded
        } catch {
            throw Self.friendly(error)
        }
    }

    /// `<think>…</think>`, which Qwen3 may still emit, and anything else in
    /// angle-bracket tags.
    static func strippingThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "</?think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
