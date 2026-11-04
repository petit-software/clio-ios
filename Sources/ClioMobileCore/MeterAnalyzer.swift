import Accelerate
import Foundation

/// Turns the microphone signal into the six bars of the meter.
///
/// Copied from the Mac app, widened from five bars to six. What a good
/// voice meter does, and what this does:
///
/// - **Each bar hears a different part of the voice.** Six log-spaced bands
///   from 90 Hz to 8 kHz: the fundamental, the first formant where vowels
///   carry most of their energy, the upper formants, and the hiss of
///   consonants. The bars move differently because the sound does.
/// - **Loudness is judged on a log scale, against a moving reference.** The
///   reference tracks the recent peak and sinks slowly; every band reads
///   its level over the same span below it, with a fixed tilt so the upper
///   bands, which speech leaves quieter, are not permanently small.
/// - **Fast up, slower down.** A syllable lands within a frame; it drains
///   over about a tenth of a second.
/// - **One gesture, not six.** A share of the overall loudness is mixed into
///   every bar, so the meter breathes with the voice while the bars keep
///   their differences.
/// - **A wave, not a row of gauges.** The outer bars draw the voice a little
///   behind the middle ones, so a syllable ripples outwards.
/// - **Nothing in silence.** A gate on the overall level sends every bar to
///   its floor between words.
///
/// Called from the audio tap's thread with each hardware buffer, and only
/// from there: the ceilings and smoothers are state.
public final class MeterAnalyzer: @unchecked Sendable {
    public static let barCount = 6

    /// Band edges in Hz.
    public static let edges: [Double] = [90, 200, 450, 1000, 2200, 4500, 8000]

    /// Which band each bar draws, left to right. The loud bands — the
    /// fundamental and the first formant — sit in the middle, so the
    /// biggest bars make the biggest move; the hiss of consonants flicks
    /// the outer ones.
    public static let bandForBar: [Int] = [4, 2, 0, 1, 3, 5]

    /// The DFT length: one hardware buffer at 48 kHz, ~21 ms.
    static let length = 1024

    // MARK: Tuning

    // Tuned on the phone's meter rather than the Mac's pill: a voice at
    // arm's length sat at the top of the bars and twitched there, because
    // the reference floor was where speech is loud, the top was close over
    // it, and the attack landed a syllable in a single buffer. The floor
    // now sits a little above speech, the headroom is wider, and both time
    // constants are longer — a bar takes two or three buffers to rise and
    // comes down over a sixth of a second — so a loud word fills the bar
    // without pinning it, a quiet one still moves it, and room noise does
    // not fidget.
    public static let rangeDB: Float = 40
    public static let headroomDB: Float = 10
    /// How many buffers behind the middle each bar draws.
    static let delayBuffers: [Int] = [4, 2, 0, 0, 2, 4]
    public static let minimumReferenceDB: Float = -20
    public static let referenceDecayDBPerSecond: Float = 6
    /// Speech gets quieter with frequency, about 6 dB an octave above the
    /// first formant. Added per band so the upper bars are not always small.
    static let tiltDB: [Float] = [0, 0, 3, 7, 11, 15]
    public static let attack: Float = 0.045
    public static let release: Float = 0.16
    public static let gateDB: Float = -55
    public static let blend: Float = 0.25
    public static let gamma: Float = 1.0

    // MARK: State

    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var realIn = [Float](repeating: 0, count: length)
    private var imagIn = [Float](repeating: 0, count: length)
    private var realOut = [Float](repeating: 0, count: length)
    private var imagOut = [Float](repeating: 0, count: length)
    private var magnitudes = [Float](repeating: 0, count: length / 2)

    private var reference: Float = minimumReferenceDB
    private var smoothed = [Float](repeating: 0, count: barCount)
    private var overallSmoothed: Float = 0
    private var history: [(overall: Float, bands: [Float])] = []

    /// The bars as of the last buffer, 0…1 each.
    public private(set) var bars = [Float](repeating: 0, count: barCount)

    public init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.length), .FORWARD)!
        var window = [Float](repeating: 0, count: Self.length)
        vDSP_hann_window(&window, vDSP_Length(Self.length), Int32(vDSP_HANN_DENORM))
        self.window = window
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    public func reset() {
        reference = Self.minimumReferenceDB
        smoothed = [Float](repeating: 0, count: Self.barCount)
        overallSmoothed = 0
        history = []
        bars = [Float](repeating: 0, count: Self.barCount)
    }

    /// Feed one buffer of samples at `sampleRate`, `dt` seconds after the
    /// previous one, and get the bars.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>,
                        sampleRate: Double,
                        dt: Float) -> [Float] {
        let n = Self.length
        let count = min(samples.count, n)
        guard count > 0, sampleRate > 0, let base = samples.baseAddress else {
            return bars
        }
        let dt = max(0.001, min(dt, 0.1))

        var meanSquare: Float = 0
        vDSP_measqv(base, 1, &meanSquare, vDSP_Length(count))
        let overallDB = 10 * log10(max(meanSquare, 1e-12))

        vDSP_vmul(base, 1, window, 1, &realIn, 1, vDSP_Length(count))
        if count < n {
            realIn.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: count).update(repeating: 0, count: n - count)
            }
        }
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)
        realOut.withUnsafeMutableBufferPointer { real in
            imagOut.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = sampleRate / Double(n)
        let scale = 8 / Float(n * n)
        var bandDB = [Float](repeating: -120, count: Self.barCount)
        for band in 0..<Self.barCount {
            let lo = max(1, Int(Self.edges[band] / binHz))
            let hi = min(n / 2, Int(Self.edges[band + 1] / binHz))
            guard hi > lo else { continue }
            var sumOfSquares: Float = 0
            magnitudes.withUnsafeBufferPointer {
                vDSP_svesq($0.baseAddress!.advanced(by: lo), 1, &sumOfSquares, vDSP_Length(hi - lo))
            }
            bandDB[band] = 10 * log10(max(sumOfSquares * scale, 1e-12))
        }

        let gated = overallDB < Self.gateDB
        reference = max(Self.minimumReferenceDB,
                        max(overallDB, reference - Self.referenceDecayDBPerSecond * dt))
        let top = reference + Self.headroomDB
        let floor = top - Self.rangeDB

        let overallTarget = gated ? 0 : Self.shape((overallDB - floor) / Self.rangeDB)
        overallSmoothed = Self.follow(overallSmoothed, towards: overallTarget, dt: dt)

        for bar in 0..<Self.barCount {
            let band = Self.bandForBar[bar]
            let raw = gated ? 0 : Self.shape((bandDB[band] + Self.tiltDB[band] - floor) / Self.rangeDB)
            smoothed[bar] = Self.follow(smoothed[bar], towards: raw, dt: dt)
        }

        history.append((overallSmoothed, smoothed))
        let longest = Self.delayBuffers.max()!
        if history.count > longest + 1 { history.removeFirst(history.count - longest - 1) }

        for bar in 0..<Self.barCount {
            let index = max(0, history.count - 1 - Self.delayBuffers[bar])
            let then = history[index]
            bars[bar] = min(1, max(0, Self.blend * then.overall + (1 - Self.blend) * then.bands[bar]))
        }
        return bars
    }

    private static func shape(_ x: Float) -> Float {
        pow(min(1, max(0, x)), gamma)
    }

    private static func follow(_ current: Float, towards target: Float, dt: Float) -> Float {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}
