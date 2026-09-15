import Foundation
import Combine
import CoreLocation

/// Never shown directly: `AppError.userMessage` maps every case to "Couldn't get your location. Try again."
enum LocationError: LocalizedError {
    case denied
    case restricted
    case alreadyRequesting
    case timedOut

    var errorDescription: String? {
        AppError.locationUnavailable
    }
}

/// When-in-use only. One-shot fixes via `requestLocation()`; no background tracking, no continuous updates.
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    /// A fix that has not arrived after this long fails with `LocationError.timedOut`.
    private static let fixTimeoutNanoseconds: UInt64 = 15_000_000_000

    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var wantsFixAfterAuthorization = false
    private var timeoutTask: Task<Void, Never>?
    /// Timeout of the fix being requested (15 s, or the caller's shorter one, e.g. SOS 3 s).
    private var fixTimeout = LocationService.fixTimeoutNanoseconds

    override init() {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        self.manager = manager
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// The system's cached fix, if any. Reading it starts no location updates.
    var lastKnownLocation: CLLocation? {
        manager.location
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requests a single fix (fails after 15 s, or after `timeoutNanoseconds` when given). Prompts for
    /// permission first if it has not been decided yet. Uploading the result is the caller's job
    /// (`LocationSync.share`).
    @MainActor
    func requestCurrentLocation(timeoutNanoseconds: UInt64? = nil) async throws -> CLLocation {
        guard continuation == nil else { throw LocationError.alreadyRequesting }
        switch authorizationStatus {
        case .denied: throw LocationError.denied
        case .restricted: throw LocationError.restricted
        default: break
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.fixTimeout = timeoutNanoseconds ?? Self.fixTimeoutNanoseconds
            if self.isAuthorized {
                self.startFix()
            } else {
                self.wantsFixAfterAuthorization = true
                self.manager.requestWhenInUseAuthorization()
            }
        }
    }

    /// Abandons an in-flight fix (sign-out, account switch, leaving the family, or an SOS taking over).
    /// The waiting caller gets `CancellationError`; a late fix from Core Location is then ignored.
    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    /// One-shot request plus the timeout. The timer starts here, not while a permission prompt is up.
    private func startFix() {
        manager.requestLocation()
        timeoutTask?.cancel()
        let timeout = fixTimeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(with: .failure(LocationError.timedOut))
        }
    }

    private func finish(with result: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        wantsFixAfterAuthorization = false
        continuation.resume(with: result)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard wantsFixAfterAuthorization else { return }
        if isAuthorized {
            wantsFixAfterAuthorization = false
            startFix()
        } else if isDenied {
            finish(with: .failure(LocationError.denied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        finish(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(error))
    }
}
