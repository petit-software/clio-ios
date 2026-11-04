import Foundation

/// One stretch of speech with the seconds it occupies in the audio.
///
/// What makes the transcript navigable: tap a sentence, hear it. Times are
/// relative to the audio the engine was given; the controller shifts them
/// to the stored file when silence was trimmed off the front.
public struct TranscriptSegment: Codable, Sendable, Equatable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    public func offset(by seconds: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start + seconds, end: end + seconds, text: text)
    }
}

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var duration: TimeInterval
    /// Empty when the engine has no timings; the text is still the transcript.
    public var segments: [TranscriptSegment]

    public init(text: String, language: String? = nil, duration: TimeInterval = 0,
                segments: [TranscriptSegment] = []) {
        self.text = text
        self.language = language
        self.duration = duration
        self.segments = segments
    }
}

public struct TranscribeOptions: Sendable {
    public var language: String?      // nil = auto-detect
    public var translateToEnglish: Bool
    public var initialPrompt: String? // seed with custom vocabulary

    public init(language: String? = nil,
                translateToEnglish: Bool = false,
                initialPrompt: String? = nil) {
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.initialPrompt = initialPrompt
    }
}

public struct InstalledModel: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var sizeBytes: Int64
    public var url: URL

    public init(id: String, displayName: String, sizeBytes: Int64, url: URL) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.url = url
    }
}

/// The seam WhisperKit goes behind.
///
/// Milestone 2 adds `WhisperKitEngine`; nothing above this protocol changes
/// when it does, which is the point of introducing it now.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// What the engine calls itself, stored on each recording it produces.
    var modelID: String? { get async }
    var isLoaded: Bool { get async }
    func load(model: InstalledModel) async throws
    func unload() async
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript
}

/// Stands in for WhisperKit in previews, tests and `CLIO_SIMULATE=1`.
///
/// It returns an obviously fake transcript on purpose — placeholder text
/// that reads like real speech would make a broken ASR path look like a
/// working one. The rest of the loop (record → store → list → detail) is
/// real and can be exercised end to end against this.
public actor StubTranscriptionEngine: TranscriptionEngine {
    private var loaded = false
    private let latency: Duration
    /// Thrown by every transcription, for a test of what a failure leaves
    /// behind.
    private let failure: (any Error)?

    public init(latency: Duration = .milliseconds(600), failure: (any Error)? = nil) {
        self.latency = latency
        self.failure = failure
    }

    public var modelID: String? { "stub" }
    public var isLoaded: Bool { loaded }

    public func load(model: InstalledModel) async throws {
        guard !loaded else { return }
        try? await Task.sleep(for: .milliseconds(200))
        loaded = true
    }

    public func unload() async {
        loaded = false
    }

    public func transcribe(samples: [Float],
                           options: TranscribeOptions) async throws -> Transcript {
        try await Task.sleep(for: latency)
        if let failure { throw failure }
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let first = String(format: "[Clio stub] captured %.1fs of audio (%d samples).",
                           seconds, samples.count)
        let second = "Real transcription needs a downloaded model."
        // Two segments over the clip, so tap-to-seek has something to seek.
        let segments = [
            TranscriptSegment(start: 0, end: seconds / 2, text: first),
            TranscriptSegment(start: seconds / 2, end: seconds, text: second),
        ]
        return Transcript(text: first + " " + second, language: options.language,
                          duration: seconds, segments: segments)
    }
}
