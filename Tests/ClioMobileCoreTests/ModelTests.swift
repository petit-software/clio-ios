import Foundation
import Testing
@testable import ClioMobileCore

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-ios-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes bytes locally instead of reaching Hugging Face, so the download
/// orchestration is testable offline.
private final class StubTransport: ModelTransport, @unchecked Sendable {
    let files: [RemoteFile]
    var failOn: String?
    private let lock = NSLock()
    private var downloadedPaths: [String] = []

    init(files: [RemoteFile], failOn: String? = nil) {
        self.files = files
        self.failOn = failOn
    }

    var downloaded: [String] { lock.withLock { downloadedPaths } }

    func list(repo: String, path: String) async throws -> [RemoteFile] {
        if files.isEmpty { throw ModelTransportError.emptyListing }
        return files
    }

    func download(repo: String, file: RemoteFile, to destination: URL,
                  onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        if file.path == failOn {
            throw ModelTransportError.badResponse(500)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: Int(file.size))
        try data.write(to: destination)
        lock.withLock { downloadedPaths.append(file.path) }
        onProgress(file.size)
    }
}

private let tinyID = "openai_whisper-tiny"

private func remoteFiles(id: String = tinyID) -> [RemoteFile] {
    [
        RemoteFile(path: "\(id)/AudioEncoder.mlmodelc/coremldata.bin", size: 512),
        RemoteFile(path: "\(id)/AudioEncoder.mlmodelc/model.mil", size: 2048),
        RemoteFile(path: "\(id)/TextDecoder.mlmodelc/coremldata.bin", size: 256),
        RemoteFile(path: "\(id)/config.json", size: 64),
    ]
}

private let tiny = CatalogModel(id: tinyID, displayName: "Tiny",
                                repo: "argmaxinc/whisperkit-coreml",
                                approximateBytes: 2880, tier: .fast,
                                languages: .multilingual)

private func waitUntil(timeout: Duration = .seconds(5),
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}

// MARK: - Catalog

@Suite("Model catalog")
struct ModelCatalogTests {

    @Test("The built-in catalog has the default model in it")
    func builtInHasDefault() {
        #expect(ModelCatalog.builtIn.contains { $0.id == ModelCatalog.defaultModelID })
        // Every model carries its tokenizer, or the first transcription
        // would reach for the network.
        #expect(ModelCatalog.builtIn.allSatisfy { $0.tokenizerRepo != nil })
    }

    @Test("An override catalog on disk wins over the built-in one")
    func overrideWins() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let override = directory.appendingPathComponent("models.json")

        let custom = [CatalogModel(id: "custom", displayName: "Custom",
                                   repo: "acme/models", approximateBytes: 1,
                                   tier: .fast, languages: .english)]
        try JSONEncoder().encode(custom).write(to: override)

        #expect(ModelCatalog.load(overrideURL: override) == custom)
    }

    @Test("A corrupt override falls back rather than emptying the catalog")
    func corruptOverrideFallsBack() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let override = directory.appendingPathComponent("models.json")
        try Data("nonsense".utf8).write(to: override)

        #expect(ModelCatalog.load(overrideURL: override) == ModelCatalog.builtIn)
    }
}

// MARK: - Manager

@Suite("Model manager")
struct ModelManagerTests {

    @Test("Only folders containing a compiled model count as installed")
    @MainActor
    func discoveryRequiresCompiledModel() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let good = root.appendingPathComponent("\(tinyID)/AudioEncoder.mlmodelc")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)

        // A half-finished download: a folder with loose files and no .mlmodelc.
        let partial = root.appendingPathComponent("half-downloaded")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: partial.appendingPathComponent("config.json"))

        let manager = ModelManager(transport: StubTransport(files: []), modelsDirectory: root)
        #expect(manager.installed.map(\.id) == [tinyID])
        #expect(manager.installed.first?.displayName == "Whisper Tiny", "named from the catalog")
    }

    @Test("Directory size sums nested files")
    @MainActor
    func directorySizeIsRecursive() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a/one.bin"))
        try Data(repeating: 0, count: 250).write(to: nested.appendingPathComponent("two.bin"))

        #expect(ModelManager.directorySize(of: root) == 350)
    }

    @Test("A download installs every file and flattens the repo prefix")
    @MainActor
    func downloadInstallsFiles() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ModelManager(transport: StubTransport(files: remoteFiles()),
                                   modelsDirectory: root)
        manager.download(tiny)
        try await waitUntil { manager.isInstalled(tinyID) }

        // The id must not appear twice in the path.
        let encoder = root.appendingPathComponent("\(tinyID)/AudioEncoder.mlmodelc/coremldata.bin")
        #expect(FileManager.default.fileExists(atPath: encoder.path))
        #expect(manager.downloads[tinyID] == nil)
        #expect(manager.installed.first?.sizeBytes == 2880)
        #expect(manager.installedBytes == 2880)
    }

    @Test("The tokenizer is installed in its own folder, without the weights")
    @MainActor
    func tokenizerInstalledAlongside() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // One listing serves both repos in this stub; the weights file must
        // be filtered out of the tokenizer copy and kept in the model copy.
        var files = remoteFiles()
        files.append(RemoteFile(path: "tokenizer.json", size: 32))
        files.append(RemoteFile(path: "model.safetensors", size: 4096))
        let transport = StubTransport(files: files)
        let manager = ModelManager(transport: transport, modelsDirectory: root)

        var withTokenizer = tiny
        withTokenizer.tokenizerRepo = "openai/whisper-tiny"
        manager.download(withTokenizer)
        try await waitUntil { manager.isInstalled(tinyID) }

        let installed = try #require(manager.installed.first)
        let tokenizer = ModelManager.tokenizerDirectory(for: installed)
        #expect(FileManager.default.fileExists(
            atPath: tokenizer.appendingPathComponent("tokenizer.json").path))
        #expect(FileManager.default.fileExists(
            atPath: tokenizer.appendingPathComponent("model.safetensors").path) == false)
    }

    @Test("A failed download reports it, is not installed, and resumes on retry")
    @MainActor
    func failedDownloadResumes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = remoteFiles()
        let transport = StubTransport(files: files, failOn: files[2].path)
        let manager = ModelManager(transport: transport, modelsDirectory: root)

        manager.download(tiny)
        try await waitUntil { manager.failures[tinyID] != nil }

        #expect(manager.isInstalled(tinyID) == false)
        #expect(manager.downloads[tinyID] == nil)
        #expect(transport.downloaded.count == 2)
        // The two files that arrived are staged, not installed — even
        // though one of them sits in a .mlmodelc folder.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(tinyID).path) == false)
        #expect(FileManager.default.fileExists(atPath: manager.stagingDirectory(for: tinyID).path))
        manager.refreshInstalled()
        #expect(manager.isInstalled(tinyID) == false)

        // The retry picks up where it left off: two files were already the
        // right size on disk, so only the two remaining are fetched.
        transport.failOn = nil
        manager.download(tiny)
        try await waitUntil { manager.isInstalled(tinyID) }
        #expect(manager.failures[tinyID] == nil)
        #expect(transport.downloaded.count == 4)
        #expect(FileManager.default.fileExists(atPath: manager.stagingDirectory(for: tinyID).path) == false)
    }

    @Test("Cancelling clears the partial folder")
    @MainActor
    func cancelClearsPartial() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ModelManager(transport: StubTransport(files: []), modelsDirectory: root)
        let partial = manager.stagingDirectory(for: tinyID)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        manager.cancel(tinyID)
        #expect(FileManager.default.fileExists(atPath: partial.path) == false)
    }

    @Test("Deleting removes a model we own and refuses one we do not")
    @MainActor
    func deleteOnlyOurs() async throws {
        let root = try makeTempDirectory()
        let elsewhere = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }

        let manager = ModelManager(transport: StubTransport(files: remoteFiles()),
                                   modelsDirectory: root)
        manager.download(tiny)
        try await waitUntil { manager.isInstalled(tinyID) }

        let stranger = InstalledModel(id: "stranger", displayName: "Stranger",
                                      sizeBytes: 1, url: elsewhere)
        #expect(manager.canDelete(stranger) == false)
        #expect(throws: ModelManager.DeleteError.self) { try manager.delete(stranger) }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))

        let ours = try #require(manager.installed.first)
        #expect(manager.canDelete(ours))
        try manager.delete(ours)
        #expect(manager.isInstalled(tinyID) == false)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(tinyID).path) == false)
    }

    @Test("Containment is by path component, not string prefix")
    @MainActor
    func containmentIsNotStringPrefix() {
        let models = URL(fileURLWithPath: "/data/models")
        #expect(ModelManager.isDescendant(URL(fileURLWithPath: "/data/models/whisper-tiny"), of: models))
        #expect(ModelManager.isDescendant(URL(fileURLWithPath: "/data/models-backup/whisper-tiny"), of: models) == false)
        #expect(ModelManager.isDescendant(models, of: models) == false)
    }

    @Test("Installing and deleting notify, an unchanged rescan does not")
    @MainActor
    func installedChangesAreAnnounced() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ModelManager(transport: StubTransport(files: remoteFiles()),
                                   modelsDirectory: root)
        var notifications = 0
        manager.onInstalledChanged = { notifications += 1 }

        manager.download(tiny)
        try await waitUntil { manager.isInstalled(tinyID) }
        #expect(notifications == 1)

        manager.refreshInstalled()
        #expect(notifications == 1)

        try manager.delete(try #require(manager.installed.first))
        #expect(notifications == 2)
    }
}

// MARK: - Trimmer

@Suite("Voice activity trimmer")
struct TrimmerTests {

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * AudioRecorder.sampleRate)).map { i in
            amplitude * sin(2 * .pi * 220 * Float(i) / Float(AudioRecorder.sampleRate))
        }
    }

    @Test("Silence at both ends is cut, with a little padding kept")
    func trimsEnds() throws {
        let silence = tone(seconds: 2, amplitude: 0)
        let speech = tone(seconds: 1, amplitude: 0.3)
        let clip = silence + speech + silence

        let result = try #require(VoiceActivityTrimmer.trim(clip, sensitivity: 0.5))
        let seconds = Double(result.samples.count) / AudioRecorder.sampleRate
        #expect(seconds > 1 && seconds < 1.5)
        #expect(result.trimmedLeadingSeconds > 1.5)
        #expect(result.trimmedTrailingSeconds > 1.5)
        #expect(abs(result.totalTrimmedSeconds + seconds - 5) < 0.001)
    }

    @Test("A clip with no speech at all is nil, not empty")
    func silenceIsNil() {
        #expect(VoiceActivityTrimmer.trim(tone(seconds: 3, amplitude: 0), sensitivity: 0.5) == nil)
        #expect(VoiceActivityTrimmer.trim([], sensitivity: 0.5) == nil)
    }

    @Test("Higher sensitivity keeps quieter speech")
    func sensitivityLowersThreshold() {
        let quiet = tone(seconds: 1, amplitude: 0) + tone(seconds: 1, amplitude: 0.01)
        #expect(VoiceActivityTrimmer.trim(quiet, sensitivity: 0) == nil)
        #expect(VoiceActivityTrimmer.trim(quiet, sensitivity: 1) != nil)
        #expect(VoiceActivityTrimmer.energyThreshold(for: 1) < VoiceActivityTrimmer.energyThreshold(for: 0))
    }
}
