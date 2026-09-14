import Foundation
import Observation

/// Progress for one in-flight download.
public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var completedFiles: Int
    public var totalFiles: Int

    public init(receivedBytes: Int64, totalBytes: Int64,
                completedFiles: Int, totalFiles: Int) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// The model catalog, what's installed, and moving between the two.
///
/// Installed models are discovered from disk rather than tracked in settings:
/// the folder either exists and is complete or it doesn't, and that survives a
/// settings reset and a half-finished download.
///
/// Adapted from the Mac app's manager minus the shared Hugging Face cache —
/// there is no `~/.cache` on a phone, so every model here is ours and every
/// model can be deleted.
@MainActor
@Observable
public final class ModelManager {

    public private(set) var catalog: [CatalogModel] = []
    public private(set) var installed: [InstalledModel] = []
    public private(set) var downloads: [String: DownloadProgress] = [:]
    public private(set) var failures: [String: String] = [:]

    /// Fires when the installed set changes — a download finished, a model was
    /// deleted. The app uses it to keep its selected model pointing at
    /// something that exists.
    public var onInstalledChanged: (() -> Void)?

    private let transport: any ModelTransport
    private let modelsDirectory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    /// A simulated manager's installed set is what it was told, and a
    /// rescan of a directory that does not exist must not empty it.
    private var isSimulated = false

    public init(transport: any ModelTransport = HuggingFaceTransport(),
                modelsDirectory: URL = AppPaths.modelsDirectory) {
        self.transport = transport
        self.modelsDirectory = modelsDirectory
        self.catalog = ModelCatalog.load()
        refreshInstalled()
    }

    /// For previews and tests: a manager with fixed state that does no disk
    /// scan. The real initialiser discovers what is installed by reading the
    /// models directory, which in a preview would show whatever this machine
    /// happens to have downloaded.
    public static func simulating(
        catalog: [CatalogModel] = ModelCatalog.builtIn,
        installed: [InstalledModel] = [],
        downloads: [String: DownloadProgress] = [:],
        failures: [String: String] = [:]
    ) -> ModelManager {
        let manager = ModelManager(
            transport: HuggingFaceTransport(),
            modelsDirectory: URL(fileURLWithPath: "/nonexistent-preview"))
        manager.isSimulated = true
        manager.catalog = catalog
        manager.installed = installed
        manager.downloads = downloads
        manager.failures = failures
        return manager
    }

    /// An installed model that exists only in name, for previews and tests
    /// on the stub engine. The URL points nowhere; the stub does not look.
    public static func simulatedInstalled(_ id: String = ModelCatalog.defaultModelID)
        -> InstalledModel {
        let catalog = ModelCatalog.builtIn.first { $0.id == id }
        return InstalledModel(
            id: id,
            displayName: catalog?.displayName ?? id,
            sizeBytes: catalog?.approximateBytes ?? 0,
            url: URL(fileURLWithPath: "/nonexistent-preview/models/\(id)"))
    }

    // MARK: Discovery

    public func refreshInstalled() {
        guard !isSimulated else { return }
        let found = Self.modelDirectories(in: modelsDirectory).map { url in
            let id = url.lastPathComponent
            return InstalledModel(id: id,
                                  displayName: displayName(for: id),
                                  sizeBytes: Self.directorySize(of: url),
                                  url: url)
        }
        let sorted = found.sorted { $0.displayName < $1.displayName }
        guard sorted != installed else { return }
        installed = sorted
        onInstalledChanged?()
    }

    public func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    public func installedModel(id: String?) -> InstalledModel? {
        guard let id else { return nil }
        return installed.first { $0.id == id }
    }

    /// Bytes of models on disk, for About.
    public var installedBytes: Int64 {
        installed.reduce(0) { $0 + $1.sizeBytes }
    }

    /// A model folder is one containing at least one compiled Core ML model.
    /// That is also what makes a half-finished download not count as installed.
    static func modelDirectories(in root: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        return entries.filter { url in
            guard !url.lastPathComponent.hasSuffix(stagingSuffix) else { return false }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            let contents = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return contents.contains { $0.hasSuffix(".mlmodelc") }
        }
    }

    static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    public func displayName(for id: String) -> String {
        catalog.first { $0.id == id }?.displayName ?? id
    }

    // MARK: Download

    public func isDownloading(_ id: String) -> Bool {
        downloads[id] != nil
    }

    public func download(_ model: CatalogModel) {
        guard tasks[model.id] == nil, !isInstalled(model.id) else { return }

        failures[model.id] = nil
        downloads[model.id] = DownloadProgress(receivedBytes: 0, totalBytes: 0,
                                               completedFiles: 0, totalFiles: 0)

        tasks[model.id] = Task { [weak self] in
            await self?.performDownload(model)
        }
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloads[id] = nil
        // Cancel means "I do not want this": the staging folder goes too, so
        // a later download starts clean rather than resuming a gigabyte the
        // user decided against.
        try? FileManager.default.removeItem(at: stagingDirectory(for: id))
        refreshInstalled()
    }

    /// Where a download lands while it is in flight. Discovery skips the
    /// suffix, so a half-finished download never reads as installed, and a
    /// failed one keeps its files for the retry to resume from.
    func stagingDirectory(for id: String) -> URL {
        modelsDirectory.appendingPathComponent(id + Self.stagingSuffix)
    }

    static let stagingSuffix = ".partial"

    /// Where the tokenizer for an installed model lives.
    ///
    /// A subfolder rather than the model folder itself: the tokenizer repo has
    /// its own `config.json`, and dropping that next to WhisperKit's would
    /// overwrite it.
    public nonisolated static func tokenizerDirectory(for model: InstalledModel) -> URL {
        model.url.appendingPathComponent("tokenizer", isDirectory: true)
    }

    /// Model weights only — the tokenizer repo also carries PyTorch, TF and
    /// ONNX copies of the model that we have no use for.
    static let weightExtensions: Set<String> = [
        "bin", "safetensors", "msgpack", "h5", "onnx", "ot", "pt", "ckpt",
    ]

    private func performDownload(_ model: CatalogModel) async {
        defer { tasks[model.id] = nil }

        do {
            var files = try await transport.list(repo: model.repo, path: model.id)
                .map { (file: $0, subdirectory: String?.none) }

            if let tokenizerRepo = model.tokenizerRepo {
                let tokenizerFiles = try await transport.list(repo: tokenizerRepo, path: "")
                    .filter { file in
                        let ext = (file.path as NSString).pathExtension.lowercased()
                        return !Self.weightExtensions.contains(ext)
                    }
                files.append(contentsOf: tokenizerFiles.map { (file: $0, subdirectory: "tokenizer") })
            }

            let total = files.reduce(Int64(0)) { $0 + $1.file.size }
            // Captured as a plain Int: the progress callback is @Sendable, and
            // reaching into `files` from inside it would send a non-Sendable
            // array across isolation.
            let fileCount = files.count
            downloads[model.id] = DownloadProgress(
                receivedBytes: 0, totalBytes: total,
                completedFiles: 0, totalFiles: fileCount)

            let destinationRoot = stagingDirectory(for: model.id)
            try FileManager.default.createDirectory(
                at: destinationRoot, withIntermediateDirectories: true)
            Self.excludeFromBackup(destinationRoot)

            var completedBytes: Int64 = 0

            for (index, entry) in files.enumerated() {
                try Task.checkCancellation()
                let file = entry.file

                // Paths in the listing are repo-relative and start with the
                // model id; strip it so the folder is not nested twice.
                let relative = file.path.hasPrefix(model.id + "/")
                    ? String(file.path.dropFirst(model.id.count + 1))
                    : file.path
                let destination = entry.subdirectory
                    .map { destinationRoot.appendingPathComponent($0)
                                          .appendingPathComponent(relative) }
                    ?? destinationRoot.appendingPathComponent(relative)

                // Already there and the right size — a retry after a failure
                // resumes at file granularity rather than starting over.
                if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]),
                   Int64(existing.fileSize ?? 0) == file.size {
                    completedBytes += file.size
                    downloads[model.id] = DownloadProgress(
                        receivedBytes: completedBytes, totalBytes: total,
                        completedFiles: index + 1, totalFiles: fileCount)
                    continue
                }

                let base = completedBytes
                let sourceRepo = entry.subdirectory == nil
                    ? model.repo
                    : (model.tokenizerRepo ?? model.repo)
                try await transport.download(
                    repo: sourceRepo, file: file, to: destination
                ) { [weak self] received in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloads[model.id] != nil else { return }
                        self.downloads[model.id] = DownloadProgress(
                            receivedBytes: base + received, totalBytes: total,
                            completedFiles: index, totalFiles: fileCount)
                    }
                }

                completedBytes += file.size
                downloads[model.id] = DownloadProgress(
                    receivedBytes: completedBytes, totalBytes: total,
                    completedFiles: index + 1, totalFiles: fileCount)
            }

            // Every file is in and verified: one rename makes it installed.
            let final = modelsDirectory.appendingPathComponent(model.id)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: destinationRoot, to: final)

            downloads[model.id] = nil
            refreshInstalled()

        } catch is CancellationError {
            downloads[model.id] = nil
        } catch {
            downloads[model.id] = nil
            failures[model.id] = error.localizedDescription
            // The staging folder stays: the retry resumes at file granularity,
            // so a dropped connection on the last of twenty files costs one
            // file, not twenty. It is never mistaken for an install, and a
            // cancel clears it.
        }
    }

    /// A gigabyte of re-downloadable weights has no business in an iCloud
    /// backup. `AppPaths.ensureDirectories` marks the models directory; a
    /// download marks its own folder too, in case the directory was made by
    /// something else first.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Delete

    public enum DeleteError: LocalizedError {
        case notOurs

        public var errorDescription: String? {
            "That model is not in Clio's models folder and will not be deleted."
        }
    }

    /// Only ever deletes from our own models directory. There is no shared
    /// cache on iOS, so this is belt and braces — but delete is destructive,
    /// and a wrong URL handed in from anywhere must not take a folder with it.
    public func delete(_ model: InstalledModel) throws {
        guard canDelete(model) else { throw DeleteError.notOurs }
        try FileManager.default.removeItem(at: model.url)
        refreshInstalled()
    }

    public func canDelete(_ model: InstalledModel) -> Bool {
        Self.isDescendant(model.url, of: modelsDirectory)
    }

    /// Containment by path components, not by string prefix.
    ///
    /// A string prefix gets this wrong twice: FileManager hands back resolved
    /// paths (`/private/var/…`) where our own URL is still the symlink
    /// (`/var/…`), and `…/models` is a textual prefix of `…/models-backup`.
    /// Deleting is destructive, so it does not get to be approximately right.
    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        guard target.count > root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }
}
