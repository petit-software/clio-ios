import Foundation

/// One file inside a model folder on the remote.
public struct RemoteFile: Sendable, Equatable {
    public var path: String        // full path within the repo
    public var size: Int64
    /// Hugging Face reports an LFS `oid`, which is the file's SHA-256. Small
    /// non-LFS files have none, and are verified by size alone.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// The network seam.
///
/// A protocol so the download orchestration can be tested without reaching
/// Hugging Face — the tests drive a stub that writes bytes locally.
public protocol ModelTransport: Sendable {
    func list(repo: String, path: String) async throws -> [RemoteFile]
    func download(repo: String,
                  file: RemoteFile,
                  to destination: URL,
                  onProgress: @Sendable @escaping (Int64) -> Void) async throws
}

public enum ModelTransportError: LocalizedError {
    case badResponse(Int)
    case checksumMismatch(String)
    case emptyListing

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "The server responded with status \(code)."
        case .checksumMismatch(let name):
            return "\(name) failed its checksum and was discarded."
        case .emptyListing:
            return "The model folder is empty on the server."
        }
    }
}

public struct HuggingFaceTransport: ModelTransport {
    /// For listings. Downloads go through the background session.
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func list(repo: String, path: String) async throws -> [RemoteFile] {
        // An empty path means the repo root; the API wants no trailing slash.
        let suffix = path.isEmpty ? "" : "/\(path)"
        var components = URLComponents(
            string: "https://huggingface.co/api/models/\(repo)/tree/main\(suffix)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelTransportError.badResponse(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries
            .filter { $0.type == "file" }
            .map { RemoteFile(path: $0.path, size: $0.size, sha256: $0.lfs?.oid) }

        guard !files.isEmpty else { throw ModelTransportError.emptyListing }
        return files
    }

    /// Through the background session, so the transfer outlives the app's
    /// foreground time; see `BackgroundDownloader`. Verification and the
    /// move into place happen there, as the file lands.
    public func download(repo: String,
                         file: RemoteFile,
                         to destination: URL,
                         onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        let url = URL(string:
            "https://huggingface.co/\(repo)/resolve/main/\(file.path)")!
        try await BackgroundDownloader.shared.download(
            url, to: destination, size: file.size, sha256: file.sha256, onProgress: onProgress)
    }

    // MARK: Wire format

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
        let lfs: LFS?

        struct LFS: Decodable { let oid: String }
    }
}
