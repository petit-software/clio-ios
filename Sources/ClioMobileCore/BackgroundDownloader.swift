import CryptoKit
import Foundation

/// Downloads that survive the screen locking.
///
/// A foreground `URLSession` dies with the app's background time — about
/// thirty seconds after the screen locks — and a gigabyte model takes
/// minutes. A background session hands the transfer to the system, which
/// carries on while the app is suspended and, if the app is killed, wakes
/// it when the file is in.
///
/// Because the app may not be around when a file finishes, this delegate
/// does the whole job itself: each task carries its destination, size and
/// checksum in `taskDescription`, which the system persists, and on
/// completion the file is verified and moved into place here, whether or
/// not anyone is awaiting it. A waiting `download` call is then resumed;
/// a relaunched app just finds the file where the next attempt expects it.
///
/// One instance per process, on one session identifier, or the system
/// cannot reconnect a relaunched app to its transfers.
public final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public static let sessionIdentifier = AppPaths.bundleIdentifier + ".models"
    public static let shared = BackgroundDownloader()

    /// What one task must do with its file when it lands.
    struct Job: Codable {
        var destination: String
        var size: Int64
        var sha256: String?
    }

    private struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>
        var onProgress: @Sendable (Int64) -> Void
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    /// The verdict from `didFinishDownloadingTo`, kept for the completion
    /// callback that follows it.
    private var outcomes: [Int: Result<Void, any Error>] = [:]
    private var session: URLSession!

    /// Set by the app delegate when iOS relaunches the app for this
    /// session's events; called once the delegate has handled them all.
    public var backgroundEventsCompletion: (@Sendable () -> Void)? {
        get { lock.withLock { completion } }
        set { lock.withLock { completion = newValue } }
    }
    private var completion: (@Sendable () -> Void)?

    override private init() {
        super.init()
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The user asked for it: not deferred to a "good time" by the system.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        #else
        // Background sessions want an app bundle to relaunch. The host build
        // is for tests; the same delegate on an ordinary session exercises
        // the same path.
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Fetch `url` into `destination`, verified by size and (if given) SHA-256.
    ///
    /// Returns when the file is in place. Cancelling the task cancels the
    /// transfer. Progress is bytes received so far, on an arbitrary thread.
    public func download(_ url: URL,
                         to destination: URL,
                         size: Int64,
                         sha256: String?,
                         onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        let job = Job(destination: destination.path, size: size, sha256: sha256)
        let task = session.downloadTask(with: url)
        task.taskDescription = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    waiters[task.taskIdentifier] = Waiter(continuation: continuation,
                                                          onProgress: onProgress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { waiters[downloadTask.taskIdentifier]?.onProgress }
        progress?(totalBytesWritten)
    }

    /// The file exists only until this returns, so the verify and move
    /// happen here, synchronously, for every task — including one started
    /// by a previous run of the app.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let outcome: Result<Void, any Error>
        do {
            guard let description = downloadTask.taskDescription,
                  let job = try? JSONDecoder().decode(Job.self, from: Data(description.utf8))
            else { throw ModelTransportError.badResponse(-1) }

            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw ModelTransportError.badResponse(http.statusCode)
            }
            try Self.install(location, as: job)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        lock.withLock { outcomes[downloadTask.taskIdentifier] = outcome }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: (any Error)?) {
        let (waiter, outcome) = lock.withLock {
            (waiters.removeValue(forKey: task.taskIdentifier),
             outcomes.removeValue(forKey: task.taskIdentifier))
        }
        guard let waiter else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume(throwing: error)
            }
            return
        }
        switch outcome {
        case .success: waiter.continuation.resume()
        case .failure(let failure): waiter.continuation.resume(throwing: failure)
        case nil: waiter.continuation.resume(throwing: ModelTransportError.badResponse(-1))
        }
    }

    #if os(iOS)
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            let handler = self.completion
            self.completion = nil
            return handler
        }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
    #endif

    // MARK: Verify and place

    static func install(_ file: URL, as job: Job) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let name = (job.destination as NSString).lastPathComponent
        guard Int64(size) == job.size else {
            throw ModelTransportError.checksumMismatch(name)
        }
        if let expected = job.sha256 {
            guard try sha256(of: file) == expected else {
                throw ModelTransportError.checksumMismatch(name)
            }
        }
        let destination = URL(fileURLWithPath: job.destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// Streamed: the largest model file is over half a gigabyte.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
