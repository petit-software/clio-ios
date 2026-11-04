import Foundation
import WhisperKit

/// Finds the speech in a clip, and the silence around it.
///
/// Not applied to what the model hears any more: Whisper pads every clip
/// to a thirty-second window regardless, and it turned out to be sensitive
/// to exactly where a clip starts — a recording cut 0.85 s in lost its last
/// word, cut 0.5 s or 1.0 s in it did not — so the capture goes to the
/// model whole and segment times index the file as it is. What this still
/// does is answer `SilenceGate`'s question — is there a word in here at
/// all — and it is kept exact at the edges for that.
///
/// Copied from the Mac app. WhisperKit already ships an
/// energy VAD, which means no extra dependency and no ~2 MB model to bundle —
/// so that is what this uses. Silero would slot in behind the same function if
/// noisy rooms ever prove the energy gate is not enough.
///
/// The edges are found in two passes. The main threshold says where the
/// speech is; a second, lower one says where it fades out. A sentence
/// trails off — the last words of "…and that's about it" sit ten decibels
/// under the ones before them — and a single gate cut them off along with
/// the silence after them: the audio file was whole, the transcript ended a
/// sentence early. So the edge is walked outward from the last loud frame
/// through every frame that is still quieter speech rather than room, and
/// a generous pad is kept after it. Trailing silence costs nothing inside
/// a window Whisper pads to thirty seconds anyway.
public enum VoiceActivityTrimmer {

    public struct Result: Sendable, Equatable {
        public var samples: [Float]
        public var trimmedLeadingSeconds: Double
        public var trimmedTrailingSeconds: Double

        public var totalTrimmedSeconds: Double {
            trimmedLeadingSeconds + trimmedTrailingSeconds
        }
    }

    /// Kept before the first frame of speech, so the gate cannot clip a
    /// soft consonant at the start of an utterance.
    static let leadingPaddingSeconds: Double = 0.25

    /// Kept after the last frame of speech. A second, deliberately: the
    /// final word of a recording is the one the gate is likeliest to
    /// misjudge, and a second of room at the end costs the model nothing.
    static let trailingPaddingSeconds: Double = 1.0

    /// The quiet-speech threshold, as a fraction of the main one: about
    /// nine decibels lower. Frames between the two are the tail of a
    /// sentence, not the room.
    static let edgeThresholdFraction: Float = 0.35

    /// How many frames of near-silence the edge may step over while
    /// looking for more quiet speech: half a second, a breath between the
    /// last two words.
    static let edgeGapFrames = 5

    /// One VAD frame, in seconds.
    static let frameSeconds: Float = 0.1

    /// Returns nil when the clip contains no speech at all — the caller turns
    /// that into "nothing heard" rather than paying for a transcription that
    /// will come back empty.
    public static func trim(_ samples: [Float],
                            sensitivity: Double,
                            sampleRate: Double = AudioRecorder.sampleRate) -> Result? {
        guard !samples.isEmpty else { return nil }

        let threshold = energyThreshold(for: sensitivity)
        let loud = EnergyVAD(sampleRate: Int(sampleRate),
                             frameLength: frameSeconds,
                             frameOverlap: 0.0,
                             energyThreshold: threshold)
        let activity = loud.voiceActivity(in: samples)
        guard let firstLoud = activity.firstIndex(of: true),
              let lastLoud = activity.lastIndex(of: true)
        else { return nil }

        // The same frames against the lower gate: where the speech fades
        // rather than where it is.
        let quiet = EnergyVAD(sampleRate: Int(sampleRate),
                              frameLength: frameSeconds,
                              frameOverlap: 0.0,
                              energyThreshold: threshold * edgeThresholdFraction)
            .voiceActivity(in: samples)

        let (firstFrame, lastFrame) = extend(first: firstLoud, last: lastLoud, through: quiet)

        let frame = loud.frameLengthSamples
        let leadPad = Int(leadingPaddingSeconds * sampleRate)
        let tailPad = Int(trailingPaddingSeconds * sampleRate)

        let start = max(0, firstFrame * frame - leadPad)
        let end = min(samples.count, (lastFrame + 1) * frame + tailPad)
        guard start < end else { return nil }

        return Result(
            samples: Array(samples[start..<end]),
            trimmedLeadingSeconds: Double(start) / sampleRate,
            trimmedTrailingSeconds: Double(samples.count - end) / sampleRate)
    }

    /// Walk the edges outward from the loud frames through the quiet ones,
    /// stepping over gaps of up to `edgeGapFrames`. Pure, for the tests.
    static func extend(first: Int, last: Int, through quiet: [Bool]) -> (first: Int, last: Int) {
        var firstFrame = first
        var gap = 0
        var index = first - 1
        while index >= 0, gap <= edgeGapFrames {
            if quiet[index] { firstFrame = index; gap = 0 } else { gap += 1 }
            index -= 1
        }

        var lastFrame = last
        gap = 0
        index = last + 1
        while index < quiet.count, gap <= edgeGapFrames {
            if quiet[index] { lastFrame = index; gap = 0 } else { gap += 1 }
            index += 1
        }
        return (firstFrame, lastFrame)
    }

    /// Maps the 0…1 slider onto an energy threshold.
    ///
    /// Inverted: a *more* sensitive setting must detect quieter speech, which
    /// means a *lower* threshold. Midpoint lands near WhisperKit's own 0.02
    /// default so the middle of the slider is the tuned value.
    static func energyThreshold(for sensitivity: Double) -> Float {
        let clamped = min(1, max(0, sensitivity))
        return Float(0.05 - clamped * 0.048)
    }
}
