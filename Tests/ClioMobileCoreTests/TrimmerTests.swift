import Foundation
import Testing
@testable import ClioMobileCore

/// The trimmer against clips built to have quiet edges: a sentence that
/// trails off, a first word spoken softly. What it must never do is cut a
/// word the audio file still has.
@Suite("Voice activity trimmer edges")
struct TrimmerEdgeTests {

    private let rate = AudioRecorder.sampleRate

    /// A 440 Hz tone at the given RMS amplitude, as a stand-in for speech
    /// at that loudness. 0.1 is about -20 dBFS, a voice at arm's length;
    /// 0.012 is -38 dBFS, the end of a sentence trailing off.
    private func tone(seconds: Double, rms: Float) -> [Float] {
        let amplitude = rms * Float(2).squareRoot()
        return (0..<Int(seconds * rate)).map { i in
            amplitude * sin(2 * .pi * 440 * Float(i) / Float(rate))
        }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    @Test("A sentence that trails off keeps its last words")
    func quietTail() throws {
        // Two seconds of speech, then a second and a half under the main
        // gate but well above the room, then three seconds of nothing.
        let clip = tone(seconds: 2, rms: 0.1) + tone(seconds: 1.5, rms: 0.012) + silence(3)
        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))

        let kept = Double(result.samples.count) / rate + result.trimmedLeadingSeconds
        #expect(kept >= 3.5, "the quiet tail is speech, not silence: kept to \(kept)s")
        #expect(kept <= 3.5 + VoiceActivityTrimmer.trailingPaddingSeconds + 0.15,
                "and the pad after it is bounded")
        #expect(result.trimmedTrailingSeconds > 1.5, "the silence after the pad still goes")
    }

    @Test("A soft first word is kept too")
    func quietHead() throws {
        let clip = silence(2) + tone(seconds: 0.6, rms: 0.012) + tone(seconds: 2, rms: 0.1)
        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
        #expect(result.trimmedLeadingSeconds <= 2.0, "starts at or before the soft word")
        #expect(result.trimmedLeadingSeconds >= 2.0 - VoiceActivityTrimmer.leadingPaddingSeconds - 0.15)
    }

    @Test("A breath between the last two words does not end the sentence")
    func gapInTheTail() throws {
        let clip = tone(seconds: 2, rms: 0.1) + silence(0.4) + tone(seconds: 0.5, rms: 0.012) + silence(3)
        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
        let kept = Double(result.samples.count) / rate + result.trimmedLeadingSeconds
        #expect(kept >= 2.9, "the word after the breath is inside: \(kept)s")
    }

    @Test("Room noise alone is still trimmed away")
    func roomIsNotSpeech() throws {
        // -52 dBFS: a quiet room on a phone microphone, under both gates.
        let clip = tone(seconds: 2, rms: 0.1) + tone(seconds: 4, rms: 0.0025)
        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
        let kept = Double(result.samples.count) / rate
        #expect(kept < 2 + VoiceActivityTrimmer.trailingPaddingSeconds + 0.15,
                "only the pad is kept past the speech: \(kept)s")
    }

    @Test("Silence is nothing, and silence around speech is cut at both ends")
    func edges() throws {
        #expect(VoiceActivityTrimmer.trim(silence(3), sensitivity: 0.5) == nil)
        #expect(VoiceActivityTrimmer.trim([], sensitivity: 0.5) == nil)

        let clip = silence(2) + tone(seconds: 1, rms: 0.1) + silence(2)
        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
        #expect(abs(result.trimmedLeadingSeconds - (2 - VoiceActivityTrimmer.leadingPaddingSeconds)) < 0.11)
        #expect(abs(result.trimmedTrailingSeconds - (2 - VoiceActivityTrimmer.trailingPaddingSeconds)) < 0.11)
    }

    @Test("The edge walk steps over short gaps and stops at long ones")
    func extendWalk() {
        // Loud at 5…6; quiet speech at 2 and 8, 9; room everywhere else.
        var quiet = [Bool](repeating: false, count: 20)
        for i in [2, 5, 6, 8, 9] { quiet[i] = true }
        let edges = VoiceActivityTrimmer.extend(first: 5, last: 6, through: quiet)
        #expect(edges.first == 2, "two frames of gap is within the allowance")
        #expect(edges.last == 9)

        // A gap longer than the allowance ends the walk.
        var far = [Bool](repeating: false, count: 30)
        for i in [5, 6, 20] { far[i] = true }
        let stopped = VoiceActivityTrimmer.extend(first: 5, last: 6, through: far)
        #expect(stopped.last == 6)
    }
}
