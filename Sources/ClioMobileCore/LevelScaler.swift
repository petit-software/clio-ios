import Foundation

/// Turns the raw RMS of the last audio buffer into the 0…1 the meter draws.
///
/// Speech is quiet in absolute terms — a conversational voice into a phone
/// microphone sits around -30 to -20 dBFS, with the gaps between words near
/// -50 — so a linear map of the whole -60…0 range puts every word in one
/// narrow band a third of the way up. The window here is narrower: silence
/// at the bottom, and a ceiling that rises to the loudest thing heard so far
/// and sinks back afterwards. Copied from the Mac app, where it was tuned
/// against real recordings.
public struct LevelScaler: Sendable, Equatable {
    public static let silenceDB: Float = -50
    public static let minimumCeilingDB: Float = -15
    public static let decayDBPerSecond: Float = 10

    public private(set) var ceilingDB: Float = LevelScaler.minimumCeilingDB

    public init() {}

    /// The level for a buffer of the given RMS, `dt` seconds after the last.
    public mutating func level(rms: Float, dt: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        ceilingDB = max(Self.minimumCeilingDB,
                        max(db, ceilingDB - Self.decayDBPerSecond * dt))
        let span = ceilingDB - Self.silenceDB
        return min(1, max(0, (db - Self.silenceDB) / span))
    }
}
