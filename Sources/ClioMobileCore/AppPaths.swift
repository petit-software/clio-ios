import Foundation

/// Where Clio keeps things on disk.
///
/// One place, because the About section shows what is stored and how much,
/// and because "where did it put the models" is the support question.
///
/// Everything sits in Application Support, not Documents: recordings do not
/// belong in the Files app unless the user shares one, and Application
/// Support is backed up by default, which is what recordings want. Models
/// are large and re-downloadable, so `modelsDirectory` is excluded from
/// backup when it is created.
public enum AppPaths {
    public static let bundleIdentifier =
        Bundle.main.bundleIdentifier ?? "com.bartbak.clio.ios"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var libraryFile: URL {
        supportDirectory.appendingPathComponent("recordings.json")
    }

    public static var recordingsDirectory: URL {
        supportDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    public static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        let manager = FileManager.default
        for url in [supportDirectory, recordingsDirectory] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: modelsDirectory,
                                    withIntermediateDirectories: true)
        var models = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? models.setResourceValues(values)
    }
}
