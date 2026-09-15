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
