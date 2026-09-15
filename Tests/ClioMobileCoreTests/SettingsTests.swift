import Foundation
import Testing

@Suite("Settings additions")
struct SettingsAdditionsTests {
    @Test("Hold to record defaults off and survives a round trip")
    func holdToRecord() throws {
        #expect(Settings().holdToRecord == false)
        var settings = Settings()
        settings.holdToRecord = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).holdToRecord)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.holdToRecord == false)
    }

    @Test("Include location defaults off and survives a round trip")
    func includeLocation() throws {
        #expect(Settings().includeLocation == false)
        var settings = Settings()
        settings.includeLocation = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).includeLocation)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.includeLocation == false)
    }

    @Test("Appearance defaults to the system and survives a round trip")
    func appearance() throws {
        #expect(Settings().appearance == .system)
        var settings = Settings()
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).appearance == .dark)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"appearance":"neon"}"#.utf8))
        #expect(old.appearance == .system, "an unknown value falls back")
        #expect(RecordingLimit.range.upperBound == 30)
    }

    @Test("Intro shown defaults off and survives a round trip")
    func introShown() throws {
        #expect(Settings().introShown == false)
        var settings = Settings()
        settings.introShown = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).introShown)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.introShown == false)
    }

    @Test("Auto copy defaults off and survives a round trip")
    func autoCopy() throws {
        #expect(Settings().autoCopyTranscript == false)
        var settings = Settings()
        settings.autoCopyTranscript = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).autoCopyTranscript)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.autoCopyTranscript == false)
    }
}
@testable import ClioMobileCore

@Suite("Settings")
struct SettingsTests {

    @Test("Round-trips through JSON unchanged")
    func roundTrip() throws {
        var settings = Settings()
        settings.language = "nl"
        settings.translateToEnglish = true
        settings.customVocabulary = ["Clio", "WhisperKit"]
        settings.wordReplacements = [WordReplacement(find: "clio", replace: "Clio")]
        settings.maxRecordingSeconds = 120
        settings.vadSensitivity = 0.8
        settings.capitalizeFirstLetter = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("A missing key falls back to its default rather than failing the file")
    func missingKeys() throws {
        let json = #"{"schemaVersion": 1, "language": "de"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.language == "de")
        #expect(decoded.maxRecordingSeconds == Settings().maxRecordingSeconds)
        #expect(decoded.capitalizeFirstLetter == true)
    }

    @Test("A field of the wrong shape costs that field only")
    func wrongShape() throws {
        let json = #"{"maxRecordingSeconds": "ten", "translateToEnglish": true, "vadSensitivity": 9}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.maxRecordingSeconds == 600)
        #expect(decoded.translateToEnglish == true)
        #expect(decoded.vadSensitivity == 1, "clamped on the way in")
    }

    @Test("Recording limit is chosen in whole minutes within the range")
    func recordingLimit() {
        #expect(RecordingLimit.minutes(seconds: 600) == 10)
        #expect(RecordingLimit.minutes(seconds: 6_000) == 30)
        #expect(RecordingLimit.minutes(seconds: 0) == 1)
        #expect(RecordingLimit.minutes(seconds: 100) == 2)
        #expect(RecordingLimit.seconds(minutes: 3) == 180)
        #expect(RecordingLimit.label(seconds: 60) == "1 minute")
        #expect(RecordingLimit.label(seconds: 300) == "5 minutes")
    }

    @Test("The store writes to disk and reads back what it wrote")
    @MainActor
    func storePersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")

        let store = SettingsStore(fileURL: file)
        store.settings.language = "fr"
        store.flush()

        let reloaded = SettingsStore(fileURL: file)
        #expect(reloaded.settings.language == "fr")
    }

    @Test("A corrupt settings file is set aside, not clobbered")
    @MainActor
    func corruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: file)

        let store = SettingsStore(fileURL: file)
        #expect(store.settings == Settings())
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
    }
}
