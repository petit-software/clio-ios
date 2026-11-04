import AVFoundation
import Foundation

/// What a capture returns when it stops.
public struct CaptureResult: Sendable, Equatable {
    /// 16 kHz mono Float32 — the format Whisper wants.
    public var samples: [Float]
    /// True if the cap was reached and capture stopped itself.
    public var reachedLimit: Bool

    public init(samples: [Float], reachedLimit: Bool) {
        self.samples = samples
        self.reachedLimit = reachedLimit
    }

    public var duration: TimeInterval {
        Double(samples.count) / AudioRecorder.sampleRate
    }
}

/// Something that happened to the microphone while a capture was running.
public enum CaptureEvent: Sendable, Equatable {
    /// The system took the microphone: a phone call, Siri, another app.
    /// Capture is paused; nothing is lost, nothing is added.
    case interrupted
    /// The interruption is over. `resumed` says whether capture picked up
    /// again; if not, what was captured so far is all there will be.
    case interruptionEnded(resumed: Bool)
    /// The route changed (headphones unplugged, a headset went away) and
    /// the engine could not be restarted on the new one.
    case lost(String)
}

/// The microphone, behind a protocol so the state machine can be tested
/// on a simulated one and previews never touch audio hardware.
public protocol AudioCapturing: AnyObject, Sendable {
    /// Ask for the microphone. True if granted, now or earlier.
    func requestPermission() async -> Bool
    /// Called from an arbitrary thread when the system interferes with a
    /// running capture. The controller turns these into states.
    var onEvent: (@Sendable (CaptureEvent) -> Void)? { get set }
    /// Start capturing. Returns once the hardware is running.
    func start(maxSeconds: Double) async throws
    /// Hold the buffer where it is; the engine stops listening. `resume`
    /// picks up in the same buffer.
    func pause() async
    func resume() async throws
    /// Stop and hand back everything captured.
    func stop() async -> CaptureResult
    /// Stop and throw it away.
    func cancel() async
    /// The current 0…1 level. Polled by the controller ~30×/s.
    var level: Float { get }
    /// Six bars, 0…1 each, from `MeterAnalyzer`. Polled with the level.
    var bands: [Float] { get }
    /// Seconds captured so far.
    var elapsed: TimeInterval { get }
    /// True once the cap has been hit; the controller then stops.
    var reachedLimit: Bool { get }
    /// The last `seconds` of what has been captured so far, as a copy, for
    /// a transcript preview while the recording runs. Capture goes on.
    func snapshot(lastSeconds seconds: TimeInterval) -> [Float]
}

/// Mic capture at 16 kHz mono Float32.
///
/// The engine's tap runs on a realtime audio thread. Two rules follow from
/// that and drive this file: never touch an actor from the callback (the
/// level is written under a lock and polled), and keep the work in it
/// small (convert, measure, append).
///
/// Adapted from the Mac app's recorder, minus device selection — iOS
/// routes input itself. Its two hard-won rules are kept: the tap takes
/// `format: nil` and the converter is built from the buffers that actually
/// arrive, and every engine call that can raise goes through
/// `ObjCException.catching`.
public final class AudioRecorder: AudioCapturing, @unchecked Sendable {

    public enum RecorderError: LocalizedError {
        case permissionDenied
        case formatUnavailable
        case engineFailed(String)
        case fileFailed(String)

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Clio needs the microphone. Allow it in Settings."
            case .formatUnavailable:
                return "The microphone did not report a usable audio format."
            case .engineFailed(let message):
                return "Audio engine failed to start: \(message)"
            case .fileFailed(let message):
                return "Could not save the recording: \(message)"
            }
        }
    }

    public static let sampleRate: Double = 16_000

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false)!

    private var engine = AVAudioEngine()
    private let lock = NSLock()

    // Guarded by `lock`.
    private var buffer: [Float] = []
    private var writeIndex = 0
    private var didReachLimit = false
    private var scaler = LevelScaler()
    private var currentLevel: Float = 0
    private var currentBands = [Float](repeating: 0, count: MeterAnalyzer.barCount)
    private var isRunning = false
    // Touched only by the tap thread.
    private let meter = MeterAnalyzer()

    // Touched only by the tap thread.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    // Guarded by `lock`.
    private var eventHandler: (@Sendable (CaptureEvent) -> Void)?
    private var isInterrupted = false
    private var observers: [any NSObjectProtocol] = []

    public init() {}

    public var onEvent: (@Sendable (CaptureEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    // MARK: Permission

    public func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: break
        @unknown default: break
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Lifecycle

    public func start(maxSeconds: Double) async throws {
        guard await requestPermission() else { throw RecorderError.permissionDenied }

        let capacity = Int(maxSeconds * Self.sampleRate)
        lock.withLock {
            buffer = [Float](repeating: 0, count: capacity)
            writeIndex = 0
            didReachLimit = false
            scaler = LevelScaler()
            currentLevel = 0
            currentBands = [Float](repeating: 0, count: MeterAnalyzer.barCount)
        }
        meter.reset()

        try configureSession()

        // The engine takes a few hundred milliseconds to reach the hardware.
        // Off the main actor, so the record screen is already up while it does.
        try await Task.detached(priority: .userInitiated) { [self] in
            do {
                try installTap(on: engine.inputNode)
            } catch {
                // Once: a fresh engine, the same tap.
                try installTapOnFreshEngine()
            }
            engine.prepare()
            var startError: (any Error)?
            let raised = ObjCException.catching {
                do { try engine.start() } catch { startError = error }
            }
            if let reason = raised ?? startError?.localizedDescription {
                _ = ObjCException.catching { engine.inputNode.removeTap(onBus: 0) }
                throw RecorderError.engineFailed(reason)
            }
            guard engine.isRunning else {
                _ = ObjCException.catching { engine.inputNode.removeTap(onBus: 0) }
                throw RecorderError.engineFailed("the engine did not start")
            }
        }.value

        lock.withLock {
            isRunning = true
            isInterrupted = false
        }
        observeSystem()
    }

    /// The engine is paused, not stopped: the tap stays, the buffer keeps
    /// its place, and `resume` is one `start()` away. Route changes and
    /// interruptions while paused are left alone — `isInterrupted` covers
    /// both — and resume restarts the engine on whatever is there then.
    public func pause() async {
        let shouldPause = lock.withLock {
            guard isRunning, !isInterrupted else { return false }
            isInterrupted = true
            currentLevel = 0
            return true
        }
        guard shouldPause else { return }
        _ = ObjCException.catching { self.engine.pause() }
    }

    public func resume() async throws {
        let shouldResume = lock.withLock { isRunning && isInterrupted }
        guard shouldResume else { return }
        guard restartEngine() else {
            throw RecorderError.engineFailed("could not resume")
        }
        lock.withLock { isInterrupted = false }
    }

    public func stop() async -> CaptureResult {
        teardown()
        return lock.withLock {
            let samples = Array(buffer[0..<writeIndex])
            let reached = didReachLimit
            buffer = []
            writeIndex = 0
            return CaptureResult(samples: samples, reachedLimit: reached)
        }
    }

    public func cancel() async {
        teardown()
        lock.withLock {
            buffer = []
            writeIndex = 0
        }
    }

    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return currentLevel
    }

    public var bands: [Float] {
        lock.lock(); defer { lock.unlock() }
        return currentBands
    }

    public var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(writeIndex) / Self.sampleRate
    }

    public var reachedLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return didReachLimit
    }

    /// A copy of the tail of the buffer, taken under the lock. The tap
    /// appends a thousand samples at a time, so holding it for a copy of
    /// half a minute — two megabytes — is nothing it notices.
    public func snapshot(lastSeconds seconds: TimeInterval) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let count = min(writeIndex, Int(max(0, seconds) * Self.sampleRate))
        guard count > 0 else { return [] }
        return Array(buffer[(writeIndex - count)..<writeIndex])
    }

    // MARK: Engine

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // spokenAudio: voice processing tuned for a person talking, and
            // it keeps playback of the recording afterwards on the same
            // session. Bluetooth so a headset's microphone is used when one
            // is connected — a phone across the room is not a recording.
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        #endif
    }

    /// The tap takes no format of its own. On a Bluetooth headset the
    /// hardware format changes as the recording starts; a tap installed for
    /// the old format raises an NSException from inside the engine. With
    /// `format: nil` the tap follows the hardware and the converter is built
    /// from the buffers themselves.
    private func installTap(on input: AVAudioInputNode) throws {
        _ = ObjCException.catching { input.removeTap(onBus: 0) }

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw RecorderError.formatUnavailable
        }

        if let reason = ObjCException.catching({
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] pcmBuffer, _ in
                self?.append(pcmBuffer)
            }
        }) {
            throw RecorderError.engineFailed("The audio engine refused to listen: \(reason)")
        }
    }

    private func installTapOnFreshEngine() throws {
        _ = ObjCException.catching { self.engine.stop() }
        engine = AVAudioEngine()
        converter = nil
        converterInput = nil
        try installTap(on: engine.inputNode)
    }

    private func teardown() {
        lock.lock()
        let wasRunning = isRunning
        let observers = self.observers
        self.observers = []
        lock.unlock()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if wasRunning {
            // The tap first, and only then the flag: a buffer that is in
            // the callback as Stop is pressed is the last twenty
            // milliseconds of what was said, and `append` drops anything
            // that arrives once `isRunning` is down. `removeTap` returns
            // when no more callbacks will come.
            _ = ObjCException.catching { self.engine.inputNode.removeTap(onBus: 0) }
            _ = ObjCException.catching { self.engine.stop() }
        }
        lock.lock()
        isRunning = false
        isInterrupted = false
        currentLevel = 0
        currentBands = [Float](repeating: 0, count: MeterAnalyzer.barCount)
        lock.unlock()
        guard wasRunning else { return }
        converter = nil
        converterInput = nil
        #if os(iOS)
        // Left active: the detail view plays the recording back on the same
        // session, and deactivating with .notifyOthersOnDeactivation is what
        // resumes the music the user had going. Playback ends it.
        #endif
    }

    // MARK: Interruptions and route changes

    /// Two things the system does to a running engine, and what is done
    /// about each.
    ///
    /// An interruption (a call, Siri, another app taking the microphone)
    /// stops the engine. The buffer and the tap survive it, so when the
    /// interruption ends the engine is started again and capture carries
    /// on into the same buffer — with a gap where the call was, which is
    /// what happened. If it cannot be restarted, the controller ends the
    /// recording with what it has.
    ///
    /// A route change (headphones unplugged, a headset going out of range)
    /// makes the engine post a configuration change and stop. The tap has
    /// no format of its own, so it follows the new hardware; the converter
    /// is rebuilt from the next buffer's format. Only the engine needs
    /// starting again.
    private func observeSystem() {
        let center = NotificationCenter.default
        var added: [any NSObjectProtocol] = []

        #if os(iOS)
        added.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })
        #endif

        added.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        })

        lock.withLock { observers = added }
    }

    private func handleInterruption(_ notification: Notification) {
        #if os(iOS)
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            let handler: (@Sendable (CaptureEvent) -> Void)? = lock.withLock {
                guard isRunning, !isInterrupted else { return nil }
                isInterrupted = true
                currentLevel = 0
                return eventHandler
            }
            handler?(.interrupted)

        case .ended:
            let handler: (@Sendable (CaptureEvent) -> Void)? = lock.withLock {
                guard isRunning, isInterrupted else { return nil }
                return eventHandler
            }
            guard handler != nil else { return }
            let resumed = restartEngine()
            lock.withLock { isInterrupted = !resumed }
            handler?(.interruptionEnded(resumed: resumed))

        @unknown default:
            break
        }
        #endif
    }

    private func handleConfigurationChange() {
        let handler: (@Sendable (CaptureEvent) -> Void)? = lock.withLock {
            guard isRunning, !isInterrupted else { return nil }
            return eventHandler
        }
        // Not running, or interrupted: the interruption's end restarts the
        // engine, and a stopped one has nothing to restart.
        guard handler != nil || lock.withLock({ isRunning && !isInterrupted }) else { return }
        if !restartEngine() {
            lock.withLock { currentLevel = 0 }
            handler?(.lost("The microphone changed and could not be restarted."))
        }
    }

    /// Start the engine again on whatever hardware is there now. The tap
    /// stays installed; the buffer keeps its place.
    private func restartEngine() -> Bool {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        var startError: (any Error)?
        let raised = ObjCException.catching {
            do { try engine.start() } catch { startError = error }
        }
        return raised == nil && startError == nil && engine.isRunning
    }

    // MARK: The tap

    private func append(_ pcmBuffer: AVAudioPCMBuffer) {
        let target = Self.targetFormat
        if converter == nil || converterInput != pcmBuffer.format {
            converter = AVAudioConverter(from: pcmBuffer.format, to: target)
            converterInput = pcmBuffer.format
        }
        guard let converter else { return }

        // The meter reads the hardware buffer, before it is resampled: a
        // 48 kHz frame has the whole voice in it, and the analysis is sized
        // to exactly this buffer.
        var bands: [Float] = []
        if let channel = pcmBuffer.floatChannelData?[0] {
            let frames = Int(pcmBuffer.frameLength)
            bands = meter.process(
                UnsafeBufferPointer(start: channel, count: frames),
                sampleRate: pcmBuffer.format.sampleRate,
                dt: Float(Double(frames) / pcmBuffer.format.sampleRate))
        }

        let ratio = target.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return }

        // The input block is typed @Sendable but AVAudioConverter calls it
        // synchronously, on this thread, before convert() returns.
        nonisolated(unsafe) let source = pcmBuffer
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }

        guard error == nil,
              let samples = converted.floatChannelData?[0],
              converted.frameLength > 0
        else { return }

        let count = Int(converted.frameLength)
        var sumOfSquares: Float = 0
        for i in 0..<count { sumOfSquares += samples[i] * samples[i] }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let dt = Float(count) / Float(Self.sampleRate)

        lock.lock()
        guard isRunning || writeIndex == 0 else { lock.unlock(); return }
        let room = buffer.count - writeIndex
        if room <= 0 {
            didReachLimit = true
        } else {
            let copied = min(room, count)
            for i in 0..<copied { buffer[writeIndex + i] = samples[i] }
            writeIndex += copied
            if copied < count { didReachLimit = true }
        }
        currentLevel = scaler.level(rms: rms, dt: dt)
        if !bands.isEmpty { currentBands = bands }
        lock.unlock()
    }
}

// MARK: - Files

/// The recording on disk: 16-bit PCM WAV, 16 kHz mono. The exact samples
/// the engine transcribed, in a container anything can play.
public enum AudioFiles {
    /// A quiet tone that rises through the clip, so the ear can tell where
    /// a seek landed. Stand-in audio for simulated and sample recordings.
    public static func tone(seconds: TimeInterval) -> [Float] {
        let count = Int(max(0, seconds) * AudioRecorder.sampleRate)
        return (0..<count).map { i -> Float in
            let t = Float(i) / Float(AudioRecorder.sampleRate)
            let hz = 220 + 220 * t / Float(seconds)
            return 0.08 * sin(2 * .pi * hz * t)
        }
    }


    public static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioRecorder.targetFormat,
                                            frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw AudioRecorder.RecorderError.fileFailed("could not allocate a buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: samples.count)
                }
            }
        }
        try file.write(from: buffer)
    }

    /// Reads a recording back as 16 kHz mono Float32 — for re-transcribing
    /// with a different model.
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let target = AudioRecorder.targetFormat
        let frames = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: max(frames, 1))
        else { return [] }
        try file.read(into: source)

        if file.processingFormat.sampleRate == target.sampleRate,
           file.processingFormat.channelCount == 1,
           let channel = source.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(source.frameLength)))
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return [] }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return [] }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = source
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

// MARK: - Simulation

/// A recorder for tests and previews: no hardware, deterministic output.
public final class SimulatedRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?
    private var maxSeconds: Double = 0
    public var permissionGranted: Bool
    public var startError: Error?
    /// What `stop()` returns, per second recorded — a 440 Hz tone at -20 dB.
    public var samplesPerSecond: Int = Int(AudioRecorder.sampleRate)
    /// Overrides the wall clock, so a test can "record" for a minute at once.
    public var simulatedElapsed: TimeInterval?
    /// What `stop()` returns instead of the tone — real speech from a
    /// fixture, for a test that runs the loop through the real engine.
    public var samples: [Float]?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0
    private var eventHandler: (@Sendable (CaptureEvent) -> Void)?

    public init(permissionGranted: Bool = true, startError: Error? = nil) {
        self.permissionGranted = permissionGranted
        self.startError = startError
    }

    public func requestPermission() async -> Bool { permissionGranted }

    public var onEvent: (@Sendable (CaptureEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    /// What a phone call, or a headset walking off, would do.
    public func simulate(_ event: CaptureEvent) {
        onEvent?(event)
    }

    public private(set) var pauseCount = 0
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    public func pause() async {
        lock.withLock {
            guard startedAt != nil, pausedAt == nil else { return }
            pauseCount += 1
            pausedAt = Date()
        }
    }

    public func resume() async throws {
        lock.withLock {
            guard let pausedAt else { return }
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
    }

    public func start(maxSeconds: Double) async throws {
        if let startError { throw startError }
        lock.withLock {
            startCount += 1
            self.maxSeconds = maxSeconds
            startedAt = Date()
            pausedAt = nil
            pausedTotal = 0
        }
    }

    public func stop() async -> CaptureResult {
        let (seconds, reached) = lock.withLock {
            stopCount += 1
            let seconds = min(elapsedLocked, maxSeconds)
            let reached = elapsedLocked >= maxSeconds
            startedAt = nil
            return (seconds, reached)
        }
        if let samples { return CaptureResult(samples: samples, reachedLimit: reached) }
        let count = Int(seconds * Double(samplesPerSecond))
        let samples = (0..<count).map { i in
            0.1 * sin(2 * .pi * 440 * Float(i) / Float(AudioRecorder.sampleRate))
        }
        return CaptureResult(samples: samples, reachedLimit: reached)
    }

    public func cancel() async {
        lock.withLock {
            cancelCount += 1
            startedAt = nil
        }
    }

    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        guard startedAt != nil else { return 0 }
        // A slow pulse, so a preview meter visibly moves.
        return Float(0.5 + 0.4 * sin(Date().timeIntervalSinceReferenceDate * 4))
    }

    /// Six bars shaped like a voice: a slow pulse, the middle bars leading
    /// and the outer ones a little behind and smaller.
    public var bands: [Float] {
        let base = level
        guard base > 0 else { return [Float](repeating: 0, count: MeterAnalyzer.barCount) }
        let t = Date().timeIntervalSinceReferenceDate
        return (0..<MeterAnalyzer.barCount).map { bar in
            let center = Double(MeterAnalyzer.barCount - 1) / 2
            let distance = abs(Double(bar) - center) / center
            let envelope = 1 - 0.6 * distance
            let wobble = 0.15 * sin(t * (5 + Double(bar)) + Double(bar))
            return Float(min(1, max(0, Double(base) * envelope + wobble)))
        }
    }

    public var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsedLocked
    }

    public var reachedLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return startedAt != nil && elapsedLocked >= maxSeconds
    }

    /// The tail of what `stop()` would return now: the fixture's, or the
    /// tone's for the seconds elapsed so far.
    public func snapshot(lastSeconds seconds: TimeInterval) -> [Float] {
        let elapsed = lock.withLock { startedAt == nil ? 0 : min(elapsedLocked, maxSeconds) }
        let all: [Float]
        if let samples {
            all = samples
        } else {
            let count = Int(elapsed * Double(samplesPerSecond))
            all = (0..<count).map { i in
                0.1 * sin(2 * .pi * 440 * Float(i) / Float(AudioRecorder.sampleRate))
            }
        }
        let count = min(all.count, Int(max(0, seconds) * AudioRecorder.sampleRate))
        return Array(all.suffix(count))
    }

    private var elapsedLocked: TimeInterval {
        if let simulatedElapsed { return simulatedElapsed }
        guard let startedAt else { return 0 }
        let end = pausedAt ?? Date()
        return end.timeIntervalSince(startedAt) - pausedTotal
    }
}
