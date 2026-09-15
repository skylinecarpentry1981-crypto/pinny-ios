import Foundation
import CoreLocation

/// The one place that turns any thrown error into a DESIGN-SPEC §9.1 string.
/// `error.localizedDescription` must never reach the screen; use `error.userMessage`.
enum AppError {
    static let generic = "Something went wrong. Try again."
    static let offline = "You're offline. Check your connection."
    static let malformedCode = "Enter the 6-character code from your family."
    static let familyName = "Give your family a name (1–40 characters)."
    static let locationUnavailable = "Couldn't get your location. Try again."

    static func isOffline(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.Code.notConnectedToInternet.rawValue
    }

    static func userMessage(for error: Error) -> String {
        if let authError = error as? AuthError { return authError.errorDescription ?? generic }
        if let familyError = error as? FamilyError { return familyError.errorDescription ?? generic }
        if let placeError = error as? PlaceError { return placeError.errorDescription ?? generic }
        // One-shot fix timed out or Core Location failed (kCLErrorDomain).
        if error is LocationError || (error as NSError).domain == kCLErrorDomain { return locationUnavailable }
        if isOffline(error) { return offline }
        return generic
    }
}

extension Error {
    /// User-facing §9.1 string for this error.
    var userMessage: String { AppError.userMessage(for: self) }
}
