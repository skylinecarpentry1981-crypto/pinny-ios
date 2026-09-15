import Foundation
import AuthenticationServices
import FirebaseAuth

enum AuthProvider {
    case apple
    case password
    case unknown
}

/// Credential used to re-authenticate after `User.delete()` fails with `.requiresRecentLogin`.
enum Reauthentication {
    case apple(ASAuthorization, rawNonce: String)
    case password(String)
}

/// Strings are the DESIGN-SPEC §9.1 table, verbatim.
enum AuthError: LocalizedError {
    /// Apple credential unreadable, a non-cancel `ASAuthorizationError`, or a Firebase credential error.
    case appleFailed
    case notSignedIn
    case wrongPassword
    case userNotFound
    case emailInUse
    case weakPassword
    case invalidEmail
    case requiresRecentLogin
    case network
    case unknown

    var errorDescription: String? {
        switch self {
        case .appleFailed: return "Apple sign-in didn't work. Try again."
        case .notSignedIn: return AppError.generic
        case .wrongPassword: return "Wrong password. Try again or reset it."
        case .userNotFound: return "No account with that email. Create one?"
        case .emailInUse: return "That email already has an account. Sign in."
        case .weakPassword: return "Use at least 6 characters."
        case .invalidEmail: return "Enter a valid email address."
        case .requiresRecentLogin: return "For your security, sign in again to confirm."
        case .network: return AppError.offline
        case .unknown: return AppError.generic
        }
    }

    /// Maps Firebase `AuthErrorCode` values (and URLError offline) to user-facing errors.
    static func from(_ error: Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        if AppError.isOffline(error) { return .network }
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: nsError.code) else {
            return .unknown
        }
        switch code {
        case .wrongPassword, .invalidCredential: return .wrongPassword
        case .userNotFound: return .userNotFound
        case .emailAlreadyInUse: return .emailInUse
        case .weakPassword: return .weakPassword
        case .invalidEmail: return .invalidEmail
        case .requiresRecentLogin: return .requiresRecentLogin
        case .networkError: return .network
        default: return .unknown
        }
    }
}

protocol AuthService: AnyObject {
    var currentUserId: String? { get }
    var currentEmail: String? { get }
    /// Name to seed `users/{uid}.name` with on first sign-in (Apple full name or profile display name).
    var currentDisplayName: String? { get }
    var currentProvider: AuthProvider { get }

    /// Calls `onChange` immediately with the current uid and again on every change.
    func observeAuthState(_ onChange: @escaping (String?) -> Void)
    func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws
    func signIn(email: String, password: String) async throws
    func createAccount(email: String, password: String, displayName: String) async throws
    func sendPasswordReset(email: String) async throws
    func signOut() throws
    /// Deletes the Firebase user. Pass `reauth` only after a `.requiresRecentLogin` failure: it
    /// re-authenticates first (and revokes the Apple token, which Apple requires on deletion).
    /// Firestore clean-up is done server-side by the `onUserDeleted` Cloud Function.
    func deleteAccount(reauth: Reauthentication?) async throws
}

final class FirebaseAuthService: AuthService {
    private var listenerHandle: AuthStateDidChangeListenerHandle?
    /// Apple only sends the full name on the very first sign-in; keep it until the user doc is created.
    private var pendingDisplayName: String?

    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    var currentEmail: String? {
        Auth.auth().currentUser?.email
    }

    var currentDisplayName: String? {
        pendingDisplayName ?? Auth.auth().currentUser?.displayName
    }

    var currentProvider: AuthProvider {
        let ids = Auth.auth().currentUser?.providerData.map { $0.providerID } ?? []
        if ids.contains("apple.com") { return .apple }
        if ids.contains("password") { return .password }
        return .unknown
    }

    func observeAuthState(_ onChange: @escaping (String?) -> Void) {
        if let listenerHandle {
            Auth.auth().removeStateDidChangeListener(listenerHandle)
        }
        listenerHandle = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user?.uid)
        }
    }

    func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws {
        guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.appleFailed
        }
        let fullName = appleCredential.fullName
        // Set before signIn so the auth-state listener (which bootstraps users/{uid}) can read it.
        pendingDisplayName = Self.displayName(from: fullName)
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: fullName
        )
        do {
            let result = try await Auth.auth().signIn(with: credential)
            if let name = pendingDisplayName, result.user.displayName == nil {
                let change = result.user.createProfileChangeRequest()
                change.displayName = name
                try? await change.commitChanges()
            }
        } catch {
            pendingDisplayName = nil
            throw AuthError.from(error) == .network ? AuthError.network : AuthError.appleFailed
        }
    }

    func signIn(email: String, password: String) async throws {
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            throw AuthError.from(error)
        }
    }

    func createAccount(email: String, password: String, displayName: String) async throws {
        pendingDisplayName = displayName.isEmpty ? nil : displayName
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            if let name = pendingDisplayName {
                let change = result.user.createProfileChangeRequest()
                change.displayName = name
                try? await change.commitChanges()
            }
        } catch {
            pendingDisplayName = nil
            throw AuthError.from(error)
        }
    }

    func sendPasswordReset(email: String) async throws {
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            throw AuthError.from(error)
        }
    }

    func signOut() throws {
        pendingDisplayName = nil
        try Auth.auth().signOut()
    }

    func deleteAccount(reauth: Reauthentication?) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthError.notSignedIn }
        do {
            switch reauth {
            case .apple(let authorization, let rawNonce)?:
                guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let tokenData = appleCredential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8),
                      let codeData = appleCredential.authorizationCode,
                      let authorizationCode = String(data: codeData, encoding: .utf8) else {
                    throw AuthError.appleFailed
                }
                let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: nil)
                _ = try await user.reauthenticate(with: credential)
                // Apple requires the token to be revoked when the account is deleted.
                try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
            case .password(let password)?:
                guard let email = user.email else { throw AuthError.unknown }
                let credential = EmailAuthProvider.credential(withEmail: email, password: password)
                _ = try await user.reauthenticate(with: credential)
            case nil:
                // Never delete an Apple user without revoking their token: force the SIWA re-auth path.
                if currentProvider == .apple { throw AuthError.requiresRecentLogin }
            }
            try await user.delete()
        } catch {
            let mapped = AuthError.from(error)
            // A rejected Apple credential maps to `.wrongPassword`; show the Apple string instead.
            if case .apple? = reauth, mapped == .wrongPassword {
                throw AuthError.appleFailed
            }
            throw mapped
        }
        pendingDisplayName = nil
        // `delete()` already clears the session; this only guards against a stale cached user.
        try? Auth.auth().signOut()
    }

    private static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let name = [components.givenName, components.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }
}
