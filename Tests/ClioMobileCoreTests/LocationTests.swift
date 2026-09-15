import Foundation
import Testing
@testable import ClioMobileCore

@Suite("Location")
struct LocationTests {

    @Test("A location survives the index, and an index without one decodes")
    func roundTrip() throws {
        var recording = Recording(duration: 1)
        recording.location = RecordingLocation(latitude: 52.37, longitude: 4.89,
                                               placeName: "Prinsengracht, Amsterdam")
        let data = try JSONEncoder().encode(recording)
        let back = try JSONDecoder().decode(Recording.self, from: data)
        #expect(back.location == recording.location)
        #expect(back.location?.label == "Prinsengracht, Amsterdam")

        let bare = Data(#"{"id":"\#(UUID().uuidString)","audioFileName":"a.wav"}"#.utf8)
        #expect(try JSONDecoder().decode(Recording.self, from: bare).location == nil)
    }

    @Test("Coordinates alone print as coordinates")
    func coordinateLabel() {
        let location = RecordingLocation(latitude: 52.37019, longitude: 4.89123)
        #expect(location.label == "52.3702, 4.8912")
    }

    @MainActor
    private func makeController(settings: Settings, locations: StubLocationProvider)
        throws -> (CaptureController, RecordingStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = RecordingStore(indexURL: directory.appendingPathComponent("r.json"),
                                     audioDirectory: directory)
        let controller = CaptureController(recorder: SimulatedRecorder(),
                                           engine: StubTranscriptionEngine(latency: .milliseconds(10)),
                                           models: .simulating(installed: [ModelManager.simulatedInstalled()]),
                                           settings: .simulating(settings),
                                           library: library,
                                           locations: locations)
        return (controller, library, directory)
    }

    @Test("With the setting on, the recording lands with where it was made")
    @MainActor
    func attachedWhenOn() async throws {
        var settings = Settings()
        settings.includeLocation = true
        let place = RecordingLocation(latitude: 1, longitude: 2, placeName: "Here")
        let (controller, library, directory) = try makeController(
            settings: settings, locations: StubLocationProvider(location: place))
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        #expect(library.recordings.first?.location == place)
    }

    @Test("With the setting off, the provider is never asked")
    @MainActor
    func notAskedWhenOff() async throws {
        let provider = StubLocationProvider(location: RecordingLocation(latitude: 1, longitude: 2))
        let (controller, library, directory) = try makeController(settings: Settings(),
                                                                  locations: provider)
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.start()
        await controller.stop()
        #expect(library.recordings.first?.location == nil)
    }
}
