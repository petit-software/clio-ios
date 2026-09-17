import Accelerate
import Foundation

/// Whether a capture has anything in it worth waking the model for.
///
/// Hold to record makes accidents cheap: a button brushed in a pocket, a
/// press that lands and lifts, a phone picked up by its edge. Every one of
/// those used to go the whole way — the app said "Transcribing", Whisper
/// was loaded, a 30-second window was padded out and inferred over, and the
/// empty result was thrown away at the end. The point of this is to decide
/// from the samples alone, in a millisecond and with nothing loaded, so the
/// app never claims to be transcribing something it is about to discard.
///
/// Three questions, cheapest first: is it long enough to hold a word, is
/// there any signal in it at all, and does a voice gate find a single frame
/// of speech. Any "no" and there is nothing here.
public enum SilenceGate {

    public enum Verdict: Sendable, Equatable {
        case speech
        /// Too few samples for a word. A syllable runs about 0.2 s.
        case tooShort
        /// Nothing above the noise floor anywhere in the clip: a dead
        /// microphone, a muted input, a file of zeros.
        case silent
        /// Signal, but no frame a voice gate calls speech: a pocket, a
        /// table knock, a room.
        case noVoice

        public var isSpeech: Bool { self == .speech }
    }

    /// Below this there is no word in it, whatever the meter said while the
    /// finger was down — and the recorder gives back fewer samples than the
    /// clock suggests, because the hardware takes a moment to come up.
    public static let minimumSeconds: Double = 0.4

    /// -45 dBFS. Speech at arm's length peaks two orders of magnitude above
    /// this; a microphone that never opened sits below it.
    public static let silentPeak: Float = 0.0056

    /// - Parameter usingVoiceActivity: run the voice gate as well as the
    ///   two signal checks. Off, a clip with sound but no speech in it goes
    ///   to the model anyway — which is what "Trim silence" being off asks
    ///   for. Hold to record turns it on regardless: discarding an accident
    ///   is not trimming, and the accident is the whole problem.
    public static func verdict(for samples: [Float],
                               sensitivity: Double,
                               usingVoiceActivity: Bool,
                               sampleRate: Double = AudioRecorder.sampleRate) -> Verdict {
        guard Double(samples.count) >= minimumSeconds * sampleRate else { return .tooShort }
        guard peak(of: samples) >= silentPeak else { return .silent }
        guard usingVoiceActivity else { return .speech }
        guard VoiceActivityTrimmer.trim(samples,
                                        sensitivity: sensitivity,
                                        sampleRate: sampleRate) != nil else { return .noVoice }
        return .speech
    }

    /// The largest absolute sample. One pass, vectorised: a half-hour clip
    /// is a few milliseconds.
    static func peak(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }
}
