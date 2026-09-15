import Foundation
import Combine
import CoreLocation
import Network
import UIKit

/// Shares my location once when the app comes to the foreground, or on Refresh / Check in.
///
/// Privacy: one-shot `requestLocation()` through `LocationService` only (when-in-use; no background,
/// no continuous updates, no region monitoring). Each share overwrites `users/{uid}.lastLocation`,
/// so only the latest location is ever stored. Battery level is read at share time only.
@MainActor
final class LocationSync: ObservableObject {
    enum Status: Equatable {
        case idle
        case sharing
        /// Shown as "Shared just now" for 2 s, then back to `.idle`.
        case shared
        /// Already mapped through `error.userMessage`.
        case failed(String)

        var errorMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    @Published private(set) var status: Status = .idle
    /// When our last share reached Firestore. In memory only; drives the auto-share throttle.
    @Published private(set) var lastSharedAt: Date?

    /// My uid while sharing is allowed (`authState == .ready`), nil otherwise. Set by `AppState`.
    var sharingUserId: @MainActor () -> String? = { nil }

    /// Auto-shares (`.open`) closer together than this are skipped. `.manual` and `.sos` ignore it.
    static let autoShareInterval: TimeInterval = 2 * 60
    private static let sharedVisibleNanoseconds: UInt64 = 2_000_000_000
    /// Backstop only: the write is a transaction, which fails by itself when the connection drops.
    private static let writeTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let maxAccuracy = 100_000.0
    /// SOS waits at most 3 s for a fresh fix, then uses the system's cached fix if it is ≤ 2 min old
    /// (DESIGN-SPEC §13.3).
    private static let sosFixTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let sosCachedFixMaxAge: TimeInterval = 2 * 60
    /// How often an SOS checks whether a share that is already writing has finished.
    private static let takeOverPollNanoseconds: UInt64 = 100_000_000

    private let locationService: LocationService
    private let familyService: FamilyService
    private let pathMonitor = NWPathMonitor()
    /// Optimistic until the monitor reports, so the very first share after launch is not refused.
    /// Also read by the place editor to fail fast offline instead of queueing a write.
    private(set) var isOnline = true
    private var authorizationObserver: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    /// Bumped by `reset()`, and by an SOS taking over, so an abandoned share changes nothing.
    private var generation = 0
    /// True while a share's Firestore write is in flight (its fix is already in hand).
    private var isWriting = false

    init(locationService: LocationService, familyService: FamilyService) {
        self.locationService = locationService
        self.familyService = familyService
        // If the user grants permission later (system prompt or Settings), share once.
        authorizationObserver = locationService.$authorizationStatus
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.authorizationDidChange(to: status)
                }
            }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "FamilyMap.LocationSync.path"))
    }

    /// Foreground trigger. Skipped if our last successful share was under 2 minutes ago.
    func shareIfNeeded() async {
        await share(source: .open)
    }

    /// Captures one fix plus battery and writes them to `users/{uid}.lastLocation` with `src`.
    /// `.open` is throttled; Refresh / Check in pass `.manual`, Stage 4 SOS passes `.sos`.
    /// While a share is running, other triggers are skipped; only `.sos` takes over.
    /// Returns true only when a fresh location reached Firestore.
    @discardableResult
    func share(source: LocationSource) async -> Bool {
        if status == .sharing {
            guard source == .sos else { return false }
            await takeOverShareInFlight()
        }
        guard let uid = sharingUserId() else { return false }
        if source == .open, let last = lastSharedAt, Date().timeIntervalSince(last) < Self.autoShareInterval {
            return false
        }

        switch locationService.authorizationStatus {
        case .notDetermined:
            // System prompt (NSLocationWhenInUseUsageDescription). `authorizationDidChange` shares if allowed.
            locationService.requestWhenInUseAuthorization()
            return false
        case .denied, .restricted:
            // The Map shows the "Location is off" banner instead of an error.
            clearStatus()
            return false
        default:
            break
        }

        let started = generation
        hideTask?.cancel()
        status = .sharing
        do {
            // Offline: fail at once, before asking for a fix. Nothing is queued for later.
            guard isOnline else { throw FamilyError.network }
            UIDevice.current.isBatteryMonitoringEnabled = true
            let fix = try await currentFix(for: source)
            // An SOS took this share over (or `reset()` ran) while it waited for the fix: write nothing.
            guard started == generation else { return false }
            isWriting = true
            defer { isWriting = false }
            try await write(userId: uid, share: Self.makeShare(from: fix, source: source))
            guard started == generation else { return false }
            lastSharedAt = Date()
            status = .shared
            scheduleHide()
            return true
        } catch LocationError.alreadyRequesting {
            // Another one-shot fix is in flight (e.g. the place editor's Use my location): skip quietly.
            guard started == generation else { return false }
            clearStatus()
            return false
        } catch {
            guard started == generation else { return false }
            status = .failed(error.userMessage)
            return false
        }
    }

    /// Error banners hide on tap as well as on the next successful share.
    func dismissError() {
        if status.errorMessage != nil {
            clearStatus()
        }
    }

    /// Sign-out, account switch or leaving the family: abandon any fix, forget the throttle and banner.
    func reset() {
        generation += 1
        locationService.cancel()
        clearStatus()
        lastSharedAt = nil
    }

    // MARK: - Private

    /// An SOS can't queue behind another share (e.g. the app-open one). A share still waiting for its
    /// fix is abandoned: the generation bump drops its result, including the `CancellationError`.
    /// A share already writing is awaited, so its `src: "open"` write can't land after the SOS write;
    /// the wait is bounded by the write timeout and is normally under 1 s.
    private func takeOverShareInFlight() async {
        var waited: UInt64 = 0
        while status == .sharing {
            guard isWriting, waited < Self.writeTimeoutNanoseconds else {
                generation += 1
                locationService.cancel()
                // The abandoned share won't reset its status; the SOS share sets its own.
                clearStatus()
                return
            }
            try? await Task.sleep(nanoseconds: Self.takeOverPollNanoseconds)
            waited += Self.takeOverPollNanoseconds
        }
    }

    /// One fix. SOS can't wait 15 s: 3 s, then the cached fix if it is ≤ 2 min old, else it fails
    /// and the SOS goes out without a location.
    private func currentFix(for source: LocationSource) async throws -> CLLocation {
        guard source == .sos else { return try await locationService.requestCurrentLocation() }
        // SOS also takes over a fix requested outside LocationSync (the place editor's Use my
        // location), which treats the CancellationError silently. A no-op when nothing is in flight.
        locationService.cancel()
        do {
            return try await locationService.requestCurrentLocation(timeoutNanoseconds: Self.sosFixTimeoutNanoseconds)
        } catch {
            guard Self.allowsCachedFix(after: error),
                  let cached = locationService.lastKnownLocation,
                  Date().timeIntervalSince(cached.timestamp) <= Self.sosCachedFixMaxAge else {
                throw error
            }
            return cached
        }
    }

    /// SOS falls back to the cached fix on a timeout or any Core Location failure (indoors,
    /// `kCLErrorLocationUnknown` often comes fast). Not after a cancel (sign-out, account switch) and
    /// not after the user denied location.
    private static func allowsCachedFix(after error: Error) -> Bool {
        if (error as? LocationError) == .timedOut { return true }
        if let clError = error as? CLError { return clError.code != .denied }
        return false
    }

    /// Battery and accuracy as the rules expect: integers, unknown values omitted.
    private static func makeShare(from fix: CLLocation, source: LocationSource) -> LocationShare {
        let device = UIDevice.current
        let accuracy: Int? = fix.horizontalAccuracy >= 0
            ? Int(min(fix.horizontalAccuracy, maxAccuracy).rounded())
            : nil
        let level = device.batteryLevel
        let battery: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
        let charging: Bool?
        switch device.batteryState {
        case .charging, .full: charging = true
        case .unplugged: charging = false
        default: charging = nil
        }
        return LocationShare(
            source: source,
            coordinate: fix.coordinate,
            accuracy: accuracy,
            battery: battery,
            charging: charging
        )
    }

    private func authorizationDidChange(to status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await shareIfNeeded() }
        case .denied, .restricted:
            if self.status != .sharing {
                clearStatus()
            }
        default:
            break
        }
    }

    private func clearStatus() {
        hideTask?.cancel()
        hideTask = nil
        status = .idle
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sharedVisibleNanoseconds)
            guard !Task.isCancelled, self?.status == .shared else { return }
            self?.status = .idle
        }
    }

    /// Waits at most 10 s for the transaction, then reports offline. The timeout task is cancelled as
    /// soon as the write finishes.
    private func write(userId: String, share: LocationShare) async throws {
        let familyService = self.familyService
        let timeout = Self.writeTimeoutNanoseconds
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce(continuation)
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                gate.resume(with: .failure(FamilyError.network))
            }
            Task { @MainActor in
                do {
                    try await familyService.updateLocation(userId: userId, share: share)
                    gate.resume(with: .success(()))
                } catch {
                    gate.resume(with: .failure(error))
                }
                timeoutTask.cancel()
            }
        }
    }
}

/// Resumes a continuation at most once: whichever of write / timeout finishes first wins.
/// Only touched from main-actor tasks, so the two callers never race.
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
