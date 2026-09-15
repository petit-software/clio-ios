import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Where a recording was made, when the user asked for it. A pair of
/// coordinates and, when the geocoder answered, a place to print.
public struct RecordingLocation: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// "Prinsengracht, Amsterdam" or "Amsterdam"; nil when only the
    /// coordinates are known.
    public var placeName: String?

    public init(latitude: Double, longitude: Double, placeName: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
    }

    /// What the detail view prints: the place, or the coordinates.
    public var label: String {
        placeName ?? String(format: "%.4f, %.4f", latitude, longitude)
    }
}

/// One fix, when asked. The live one talks to Core Location; tests and
/// previews hand back a fixed answer or nothing.
public protocol LocationProviding: AnyObject, Sendable {
    /// Ask the system for permission, if it has not been asked. Called
    /// when the setting is switched on, not mid-recording.
    func requestAccess()
    /// The current place, or nil: permission refused, no fix in time, or
    /// no location on this device.
    func currentLocation() async -> RecordingLocation?
}

public final class StubLocationProvider: LocationProviding, @unchecked Sendable {
    public var location: RecordingLocation?
    public private(set) var accessRequests = 0

    public init(location: RecordingLocation? = nil) { self.location = location }

    public func requestAccess() { accessRequests += 1 }
    public func currentLocation() async -> RecordingLocation? { location }
}

#if canImport(CoreLocation)
/// Core Location, once per recording: the first fix within a few seconds,
/// reverse-geocoded to a street and town. Nothing is stored beyond the
/// recording it was made for.
public final class CoreLocationProvider: LocationProviding, @unchecked Sendable {
    /// How long a recording waits for a fix before going without.
    public var timeout: Duration = .seconds(8)

    public init() {}

    public func requestAccess() {
        let manager = CLLocationManager()
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func currentLocation() async -> RecordingLocation? {
        guard Self.isAuthorized(CLLocationManager().authorizationStatus) else { return nil }
        guard let fix = await firstFix() else { return nil }
        let place = await placeName(for: fix)
        return RecordingLocation(latitude: fix.coordinate.latitude,
                                 longitude: fix.coordinate.longitude,
                                 placeName: place)
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        status == .authorized || status == .authorizedAlways
        #else
        status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func firstFix() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { [timeout] in
                try? await Task.sleep(for: timeout)
                return nil
            }
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied { return nil }
                    }
                } catch {}
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func placeName(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        else { return nil }
        let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
#endif
