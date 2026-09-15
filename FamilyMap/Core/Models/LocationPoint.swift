import Foundation
import CoreLocation
import FirebaseFirestore

/// A single captured position. Embedded in `AppUser.lastLocation`; each share overwrites it (no history).
struct LocationPoint: Codable {
    var lat: Double
    var lng: Double
    /// Always written as `FieldValue.serverTimestamp()`. Nil only in the local snapshot of our own
    /// write before the server resolves it.
    @ServerTimestamp var updatedAt: Date?
    /// Horizontal accuracy in metres at share time (0...100000). Nil when unknown.
    var acc: Int?
    /// Battery level 0...100 at share time. Nil when unknown (e.g. simulator).
    var battery: Int?
    /// Charging or full at share time. Nil when unknown.
    var charging: Bool?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// A pending (nil) timestamp is our own write that just happened, so treat it as now.
    var displayDate: Date {
        updatedAt ?? Date()
    }

    var isStale: Bool {
        updatedAt?.isStale() ?? false
    }

    /// "Updated 12 min ago" or, when stale, "Last seen 3 days ago" (DESIGN-SPEC §8 prefixes).
    var statusText: String {
        let prefix = isStale ? "Last seen" : "Updated"
        return "\(prefix) \(displayDate.relativePhrase)"
    }
}
