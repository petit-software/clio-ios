import Foundation
import Testing
@testable import ClioMobileCore

@Suite("Silence gate")
struct SilenceGateTests {

    /// A 440 Hz tone: signal the energy gate calls voice.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * AudioRecorder.sampleRate)).map { i in
            amplitude * sin(2 * .pi * 440 * Float(i) / Float(AudioRecorder.sampleRate))
        }
    }

    private func verdict(_ samples: [Float],
                         voiceActivity: Bool = true) -> SilenceGate.Verdict {
        SilenceGate.verdict(for: samples, sensitivity: 0.5, usingVoiceActivity: voiceActivity)
    }

    @Test("Nothing captured at all")
    func empty() {
        #expect(verdict([]) == .tooShort)
    }

    @Test("A press shorter than a word, however loud")
    func tooShort() {
        #expect(verdict(tone(seconds: 0.2, amplitude: 0.9)) == .tooShort)
        #expect(verdict(tone(seconds: SilenceGate.minimumSeconds + 0.1)) == .speech)
    }

    @Test("A clip with no signal in it")
    func silent() {
        #expect(verdict([Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))) == .silent)
        // A microphone that never opened: below -45 dBFS everywhere.
        #expect(verdict(tone(seconds: 3, amplitude: 0.001)) == .silent)
    }

    @Test("Signal, but nothing the voice gate calls speech")
    func noVoice() {
        // Loud enough to pass the peak check, too quiet in every frame for
        // the energy gate: one click in three seconds of near-nothing.
        var samples = [Float](repeating: 0, count: Int(3 * AudioRecorder.sampleRate))
        samples[1000] = 0.5
        #expect(verdict(samples) == .noVoice)
        // With the voice gate off, the same clip goes to the model.
        #expect(verdict(samples, voiceActivity: false) == .speech)
    }

    @Test("Speech goes through")
    func speech() {
        #expect(verdict(tone(seconds: 3)) == .speech)
        #expect(verdict(tone(seconds: 3), voiceActivity: false) == .speech)
    }

    @Test("Peak is the largest magnitude, sign ignored")
    func peak() {
        #expect(SilenceGate.peak(of: []) == 0)
        #expect(SilenceGate.peak(of: [0.1, -0.7, 0.3]) == 0.7)
    }
}
