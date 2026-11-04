import Foundation
import Testing
@testable import ClioMobileCore

@Suite("Meter analyser")
struct MeterAnalyzerTests {

    private func tone(_ hz: Double, amplitude: Float = 0.2, sampleRate: Double = 48_000,
                      count: Int = 1024) -> [Float] {
        (0..<count).map { i in amplitude * sin(Float(2 * .pi * hz * Double(i) / sampleRate)) }
    }

    private func run(_ analyzer: MeterAnalyzer, _ samples: [Float], times: Int) -> [Float] {
        var bars: [Float] = []
        for _ in 0..<times {
            samples.withUnsafeBufferPointer {
                bars = analyzer.process($0, sampleRate: 48_000, dt: 1024 / 48_000)
            }
        }
        return bars
    }

    @Test("Silence is six bars at the floor")
    func silence() {
        let analyzer = MeterAnalyzer()
        let bars = run(analyzer, [Float](repeating: 0, count: 1024), times: 10)
        #expect(bars.count == MeterAnalyzer.barCount)
        #expect(bars.allSatisfy { $0 == 0 })
    }

    @Test("A low tone lifts the middle bars more than the outer ones")
    func lowTone() {
        let analyzer = MeterAnalyzer()
        let bars = run(analyzer, tone(300), times: 30)
        // The first-formant band sits at bar 3, the hiss band at bar 5.
        #expect(bars[3] > 0.3)
        #expect(bars[3] > bars[5])
        #expect(bars[3] > bars[0])
    }

    @Test("A hiss lifts an outer bar; the meter falls back to the floor after")
    func hissThenSilence() {
        let analyzer = MeterAnalyzer()
        let hiss = run(analyzer, tone(6000), times: 30)
        #expect(hiss[5] > 0.2)
        let after = run(analyzer, [Float](repeating: 0, count: 1024), times: 40)
        #expect(after.allSatisfy { $0 < 0.05 })
    }
}

@Suite("Meter analyser, steadiness")
struct MeterSteadinessTests {

    private func tone(_ hz: Double, amplitude: Float, count: Int = 1024) -> [Float] {
        (0..<count).map { i in amplitude * sin(Float(2 * .pi * hz * Double(i) / 48_000)) }
    }

    private func step(_ analyzer: MeterAnalyzer, _ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer {
            analyzer.process($0, sampleRate: 48_000, dt: 1024 / 48_000)
        }
    }

    @Test("A voice at arm's length fills the bars without pinning them")
    func normalSpeechIsNotMaximal() {
        // -20 dBFS RMS, sustained: the loud end of ordinary speech.
        let analyzer = MeterAnalyzer()
        var bars: [Float] = []
        for _ in 0..<40 { bars = step(analyzer, tone(300, amplitude: 0.14)) }
        #expect(bars[3] > 0.45, "it is clearly there")
        #expect(bars[3] < 0.97, "and not stuck at the top: \(bars[3])")
    }

    @Test("A syllable takes more than one buffer to land, and drains over several")
    func smoothedInTime() {
        let analyzer = MeterAnalyzer()
        for _ in 0..<10 { _ = step(analyzer, [Float](repeating: 0, count: 1024)) }
        let first = step(analyzer, tone(300, amplitude: 0.14))
        var settled = first
        for _ in 0..<30 { settled = step(analyzer, tone(300, amplitude: 0.14)) }
        #expect(first[3] < settled[3] * 0.7, "the first buffer is not the whole rise: \(first[3]) of \(settled[3])")

        let afterOne = step(analyzer, [Float](repeating: 0, count: 1024))
        #expect(afterOne[3] > settled[3] * 0.5, "one silent buffer does not empty the bar")
        var gone = afterOne
        for _ in 0..<40 { gone = step(analyzer, [Float](repeating: 0, count: 1024)) }
        #expect(gone.allSatisfy { $0 < 0.05 })
    }

    @Test("Loud input is louder than quiet input, and neither jitters frame to frame")
    func ordered() {
        let analyzer = MeterAnalyzer()
        var quiet: [Float] = []
        for _ in 0..<40 { quiet = step(analyzer, tone(300, amplitude: 0.02)) }   // -37 dBFS
        let quietLevel = quiet[3]
        let shout = MeterAnalyzer()
        var loud: [Float] = []
        var previous: [Float]?
        var biggestJump: Float = 0
        for _ in 0..<40 {
            loud = step(shout, tone(300, amplitude: 0.5))                          // -9 dBFS
            if let previous { biggestJump = max(biggestJump, abs(loud[3] - previous[3])) }
            previous = loud
        }
        #expect(quietLevel > 0.1, "quiet speech still moves the meter: \(quietLevel)")
        #expect(loud[3] > quietLevel)
        #expect(loud[3] <= 1)
        // Once up, a steady signal is a steady bar.
        var last = loud[3]
        var wobble: Float = 0
        for _ in 0..<20 {
            let now = step(shout, tone(300, amplitude: 0.5))[3]
            wobble = max(wobble, abs(now - last))
            last = now
        }
        #expect(wobble < 0.02, "no frame-to-frame jitter on a steady tone: \(wobble)")
    }
}
