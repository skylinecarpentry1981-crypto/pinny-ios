import Foundation
import CoreLocation
import FirebaseFirestore

/// Icon of a saved place. Stored as its raw value; the rules accept only these four.
enum PlaceIcon: String, Codable, CaseIterable {
    case home
    case school
    case work
    case pin

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .school: return "graduationcap.fill"
        case .work: return "briefcase.fill"
        case .pin: return "mappin"
        }
    }

    /// Name set by the editor's preset chip; nil for the custom `pin`.
    var presetName: String? {
        switch self {
        case .home: return "Home"
        case .school: return "School"
        case .work: return "Work"
        case .pin: return nil
        }
    }

    /// Preset names keep their icon; any other name is a custom place (`pin`).
    static func matching(name: String) -> PlaceIcon {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { icon in
            icon.presetName.map { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? false
        } ?? .pin
    }
}

/// Firestore: families/{familyId}/places/{placeId}. Used only to label a location that was already
/// shared; nothing is monitored (STAGE-3.6-CONTRACT §1).
struct Place: Codable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var icon: PlaceIcon
    var lat: Double
    var lng: Double
    /// Metres, 100...500 in 50 m steps.
    var radius: Int
    var createdBy: String
    @ServerTimestamp var createdAt: Date?

    /// Enforced by the client; the rules cannot count documents.
    static let maxPerFamily = 10
    static let nameLimit = 30
    static let radiusRange = 100...500
    static let radiusStep = 50
    static let defaultRadius = 150

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// "150 m" (non-breaking space) in rows and the editor; VoiceOver reads `radiusSpoken`.
    var radiusText: String { Self.radiusText(radius) }
    var radiusSpoken: String { Self.radiusSpoken(radius) }

    static func radiusText(_ metres: Int) -> String { "\(metres)\u{00A0}m" }
    static func radiusSpoken(_ metres: Int) -> String { "\(metres) metres" }
}

/// What the editor saves. The service adds `createdBy` and `createdAt` on create.
struct PlaceDraft {
    var name: String
    var icon: PlaceIcon
    var coordinate: CLLocationCoordinate2D
    var radius: Int
}

/// The saved place a shared location is inside, if any (STAGE-3.6-CONTRACT §4), computed on this
/// device and never stored. Inside = distance to the centre <= radius AND the fix is at least as
/// precise as the place (`acc` <= radius; legacy docs without `acc` may match). When several places
/// match, the nearest centre wins.
func placeFor(location: LocationPoint, places: [Place]) -> Place? {
    let here = CLLocation(latitude: location.lat, longitude: location.lng)
    return places
        .filter { place in
            location.acc.map { $0 <= place.radius } ?? true
        }
        .map { place in
            (place: place, distance: here.distance(from: CLLocation(latitude: place.lat, longitude: place.lng)))
        }
        .filter { $0.distance <= CLLocationDistance($0.place.radius) }
        .min { $0.distance < $1.distance }?
        .place
}
