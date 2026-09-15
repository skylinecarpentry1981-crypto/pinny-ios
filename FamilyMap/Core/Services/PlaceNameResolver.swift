import Foundation
import CoreLocation

/// Drawer place lines ("Near 12 George St, Parramatta"), reverse-geocoded on this device.
///
/// Privacy: results live in memory only and are never written to Firestore (DESIGN-SPEC 11.11).
/// Apple rate-limits `CLGeocoder`, so there is one request at a time, a queue, and a cache keyed by
/// uid + coordinate rounded to 4 decimals (+ rough/precise). A resolved coordinate is never geocoded
/// again; "no result" (bush, open water) counts as resolved and shows "Location shared". Any other
/// failure is retried after 60 s, or on return to the foreground once those 60 s have passed.
/// Members inside a saved place are not passed in at all: their line is "At {place}".
@MainActor
final class PlaceNameResolver: ObservableObject {
    struct PlaceName: Equatable {
        /// Drawer text, e.g. "Near 12 George St, Parramatta".
        let display: String
        /// VoiceOver text: street + suburb, no number or comma, e.g. "near George St Parramatta".
        let spoken: String

        /// Pending, failed or offline.
        static let shared = PlaceName(display: "Location shared", spoken: "location shared")
        static let noLocation = PlaceName(display: "No location yet", spoken: "no location yet")
    }

    private struct Job {
        let uid: String
        let key: String
        let location: CLLocation
        let accuracy: Int?
    }

    /// Above this accuracy (metres) the street is a guess, so only the suburb is shown.
    private static let streetAccuracyLimit = 500

    /// Latest result per uid, tagged with the coordinate key it was computed for.
    @Published private var resolved: [String: (key: String, name: PlaceName)] = [:]
    /// Failures are not cached as results; they only hold off a retry for `retryInterval`.
    private var failedAt: [String: (key: String, date: Date)] = [:]
    private let geocoder = CLGeocoder()
    private var queue: [Job] = []
    private var inFlight: Job?
    /// Members from the last `resolve`, so a scheduled retry can run without the view calling in.
    private var lastMembers: [AppUser] = []
    private var retryTask: Task<Void, Never>?

    private static let retryInterval: TimeInterval = 60

    /// Rounded coordinate plus whether the fix is rough (> 500 m), which changes the wording.
    static func key(for point: LocationPoint) -> String {
        let rough = (point.acc ?? 0) > streetAccuracyLimit
        return String(format: "%.4f,%.4f", point.lat, point.lng) + (rough ? "|r" : "|p")
    }

    /// Cached place for the member's current coordinate; "Location shared" until it resolves.
    func place(for member: AppUser) -> PlaceName {
        guard let uid = member.id, let point = member.lastLocation else { return .noLocation }
        if let entry = resolved[uid], entry.key == Self.key(for: point) {
            return entry.name
        }
        return .shared
    }

    /// Queues a lookup for every member whose coordinate is new. Call when members change.
    func resolve(_ members: [AppUser]) {
        lastMembers = members
        for member in members {
            guard let uid = member.id, let point = member.lastLocation else { continue }
            let key = Self.key(for: point)
            if resolved[uid]?.key == key { continue }
            if let inFlight, inFlight.uid == uid, inFlight.key == key { continue }
            if let failure = failedAt[uid], failure.key == key,
               Date().timeIntervalSince(failure.date) < Self.retryInterval { continue }
            // A newer coordinate replaces any queued older one for the same member.
            queue.removeAll { $0.uid == uid }
            queue.append(Job(
                uid: uid,
                key: key,
                location: CLLocation(latitude: point.lat, longitude: point.lng),
                accuracy: point.acc
            ))
        }
        processNext()
    }

    /// Foreground: retry failures whose 60 s hold-off has passed. Newer ones keep their scheduled retry.
    func retryFailures() {
        resolve(lastMembers)
    }

    private func processNext() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        inFlight = job
        let geocoder = self.geocoder
        Task { [weak self] in
            let name: PlaceName?
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(job.location)
                name = Self.format(placemarks.first, accuracy: job.accuracy)
            } catch let error as CLError where error.code == .geocodeFoundNoResult {
                // Nothing to find at this coordinate: resolved as "Location shared", never retried.
                name = PlaceName.shared
            } catch {
                // Offline or rate-limited: show "Location shared" and retry later.
                name = nil
            }
            self?.finish(job, name: name)
        }
    }

    private func finish(_ job: Job, name: PlaceName?) {
        if let name {
            resolved[job.uid] = (key: job.key, name: name)
            failedAt[job.uid] = nil
        } else {
            failedAt[job.uid] = (key: job.key, date: Date())
            scheduleRetry()
        }
        inFlight = nil
        processNext()
    }

    /// One pending retry at a time, after the hold-off has passed.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.retryInterval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.resolve(self.lastMembers)
            // A failure that was still held off this time gets its own retry.
            let now = Date()
            if self.failedAt.values.contains(where: { now.timeIntervalSince($0.date) < Self.retryInterval }) {
                self.scheduleRetry()
            }
        }
    }

    /// "Near {number} {street}, {suburb}"; no street (or accuracy > 500 m) -> "Near {suburb}".
    private static func format(_ placemark: CLPlacemark?, accuracy: Int?) -> PlaceName {
        guard let placemark else { return .shared }
        let locality = placemark.locality ?? placemark.subAdministrativeArea
        let roughFix = (accuracy ?? 0) > streetAccuracyLimit
        let street = roughFix ? nil : placemark.thoroughfare

        switch (street, locality) {
        case let (street?, locality?):
            let streetLine = [placemark.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
            return PlaceName(display: "Near \(streetLine), \(locality)", spoken: "near \(street) \(locality)")
        case let (street?, nil):
            let streetLine = [placemark.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
            return PlaceName(display: "Near \(streetLine)", spoken: "near \(street)")
        case let (nil, locality?):
            return PlaceName(display: "Near \(locality)", spoken: "near \(locality)")
        case (nil, nil):
            return .shared
        }
    }
}
