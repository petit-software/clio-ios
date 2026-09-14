import Foundation
import WhisperKit

/// The real engine.
///
/// WhisperKit runs the encoder on the Apple Neural Engine, which is the reason
/// this app is native rather than a whisper.cpp wrapper. Copied from the Mac
/// app, where it has been transcribing dictation for a while.
///
/// Configured with `download: false` and an explicit `modelFolder`: models are
/// installed by our own ModelManager, and WhisperKit reaching for the network
/// on its own would quietly break the offline guarantee.
public actor WhisperKitEngine: TranscriptionEngine {

    public enum EngineError: LocalizedError {
        case notLoaded
        case modelFolderMissing(String)

        public var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "The transcription model is not loaded yet."
            case .modelFolderMissing(let path):
                return "The model folder is missing at \(path)."
            }
        }
    }

    private var pipe: WhisperKit?
    private var loadedModelID: String?

    public init() {}

    public var isLoaded: Bool { pipe != nil }

    public var modelID: String? { loadedModelID }

    public func load(model: InstalledModel) async throws {
        // Loading the same model twice costs seconds for nothing; this is what
        // makes warming the model while the user is still talking worth doing.
        if loadedModelID == model.id, pipe != nil { return }

        guard FileManager.default.fileExists(atPath: model.url.path) else {
            throw EngineError.modelFolderMissing(model.url.path)
        }

        if pipe != nil { await unload() }

        let config = WhisperKitConfig(
            modelFolder: model.url.path,
            tokenizerFolder: ModelManager.tokenizerDirectory(for: model),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false)

        pipe = try await WhisperKit(config)
        loadedModelID = model.id
    }

    public func unload() async {
        await pipe?.unloadModels()
        pipe = nil
        loadedModelID = nil
    }

    public func transcribe(samples: [Float],
                           options: TranscribeOptions) async throws -> Transcript {
        guard let pipe else { throw EngineError.notLoaded }

        var decoding = DecodingOptions()
        decoding.task = options.translateToEnglish ? .translate : .transcribe
        decoding.language = options.language
        decoding.detectLanguage = options.language == nil
        // The special tokens Whisper emits are noise in a transcript.
        // skipSpecialTokens strips them from the text.
        decoding.skipSpecialTokens = true

        // withoutTimestamps stays FALSE, deliberately. Whisper transcribes in
        // 30-second windows and uses the timestamp tokens it emits to work out
        // where the next window resumes; suppressing them leaves it unable to
        // advance, so anything past the first window is silently dropped.
        // The Mac app shipped that once and measured it: 154 characters of a
        // 60-second clip with it on, 993 with it off. Recordings here are up
        // to ten minutes, so this matters more, not less.
        decoding.withoutTimestamps = false

        if let prompt = options.initialPrompt,
           let tokenizer = pipe.tokenizer {
            // Leading space because Whisper's vocabulary is space-prefixed.
            let tokens = tokenizer.encode(text: " " + prompt)
            if !tokens.isEmpty {
                decoding.promptTokens = tokens
                decoding.usePrefillPrompt = true
            }
        }

        let results = try await pipe.transcribe(audioArray: samples,
                                                decodeOptions: decoding)

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Segment text carries the timestamp and task tokens the whole-text
        // path strips; they are stripped here the same way.
        let segments = results.flatMap(\.segments).compactMap { segment -> TranscriptSegment? in
            let clean = TranscriptFormatter.strippingSpecialTokens(segment.text)
            guard !clean.isEmpty, segment.end > segment.start else { return nil }
            return TranscriptSegment(start: TimeInterval(segment.start),
                                     end: TimeInterval(segment.end),
                                     text: clean)
        }

        // Silence is a legitimate outcome, not an error — the controller turns
        // an empty transcript into "nothing heard".
        return Transcript(
            text: text,
            language: results.first?.language ?? options.language,
            duration: Double(samples.count) / AudioRecorder.sampleRate,
            segments: segments)
    }
}
