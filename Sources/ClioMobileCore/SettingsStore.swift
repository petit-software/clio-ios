import Foundation
import Observation

/// Loads and saves `Settings` as one JSON file, debounced.
///
/// Writes are debounced because SwiftUI bindings fire on every keystroke in
/// a text field, and settings.json is not worth an fsync per character.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    /// Set when the last save failed, so About can surface it rather than
    /// silently dropping the user's preferences.
    public private(set) var lastSaveError: String?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    public init(fileURL: URL = AppPaths.settingsFile) {
        self.fileURL = fileURL
        self.settings = Self.load(from: fileURL) ?? Settings()
    }

    /// For previews and tests: in memory, never written.
    public static func simulating(_ settings: Settings = Settings()) -> SettingsStore {
        let store = SettingsStore(fileURL: URL(fileURLWithPath: "/nonexistent-preview/settings.json"))
        store.settings = settings
        store.saveTask?.cancel()
        store.saveTask = nil
        return store
    }

    // MARK: Persistence

    private static func load(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // A settings file we cannot read is kept, not clobbered.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [settings] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self.write(settings)
        }
    }

    /// Force an immediate write — used when the app goes to the background,
    /// where the debounce window would otherwise swallow the last change.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = settings
        do {
            try Self.writeSynchronously(snapshot, to: fileURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    private func write(_ snapshot: Settings) async {
        do {
            try Self.writeSynchronously(snapshot, to: fileURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    private static func writeSynchronously(_ snapshot: Settings, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        // Atomic: a crash mid-write must not leave a truncated settings file.
        try data.write(to: url, options: .atomic)
    }
}
