import Foundation
import StoreKit
import FirebaseFunctions

/// Family Pass errors. Strings are STAGE-7-CONTRACT §4 verbatim (via `AppError`).
enum PassError: LocalizedError {
    /// StoreKit purchase threw (not a cancel).
    case purchaseFailed
    /// `redeemFamilyPass` failed, or StoreKit's signature check failed.
    case verificationFailed
    /// `already-exists`: the transaction is bound to another Pinny account.
    case alreadyUsed
    /// `Product.products(for:)` threw or returned nothing.
    case productsUnavailable
    /// `AppStore.sync()` threw (not a cancel).
    case restoreFailed
    /// Restore found no Family Pass on this Apple ID.
    case noPurchaseFound
    case network

    var errorDescription: String? {
        switch self {
        case .purchaseFailed: return AppError.purchaseFailed
        case .verificationFailed: return AppError.purchaseUnverified
        case .alreadyUsed: return AppError.passAlreadyUsed
        case .productsUnavailable: return AppError.passProductsUnavailable
        case .restoreFailed: return AppError.restoreFailed
        case .noPurchaseFound: return AppError.passNotFound
        case .network: return AppError.offline
        }
    }

    /// Maps a callable error. `FunctionsError` bridges to NSError with `FunctionsErrorDomain` and the
    /// `FunctionsErrorCode` raw value.
    static func fromCallable(_ error: Error) -> PassError {
        if let passError = error as? PassError { return passError }
        if AppError.isOffline(error) { return .network }
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain {
            switch FunctionsErrorCode(rawValue: nsError.code) {
            case .alreadyExists?: return .alreadyUsed
            case .unavailable?: return .network
            default: return .verificationFailed
            }
        }
        return .verificationFailed
    }
}

/// StoreKit 2 purchase + server redemption of the Family Pass (STAGE-7-CONTRACT §2).
/// The entitlement that gates "Create family" is `users/{uid}.pass`, written by the server; this
/// object only buys, restores and hands the signed transaction (JWS) to `redeemFamilyPass`.
@MainActor
final class PassService: ObservableObject {
    enum State: Equatable {
        case idle
        /// `Product.products(for:)` in flight.
        case loading
        /// The App Store payment sheet is up.
        case purchasing
        /// Purchase (or restore) done; `redeemFamilyPass` is running.
        case verifying
        /// Ask to Buy: the purchase waits for a parent. `Transaction.updates` delivers it later.
        case pending
        case failed(String)
    }

    static let productId = "com.skyline.pinny.family.pass"
    static let region = "australia-southeast1"

    @Published private(set) var products: [Product] = []
    @Published private(set) var state: State = .idle
    /// A verified StoreKit entitlement on this Apple ID. A hint only (contract §5): the server's
    /// `pass` is the truth. Used to offer Restore first.
    @Published private(set) var hasLocalEntitlement = false
    /// True once the server accepted a JWS. The users/{uid} listener delivers `pass` a moment later;
    /// the paywall keeps its spinner until then.
    @Published private(set) var didRedeem = false

    private var updatesTask: Task<Void, Never>?

    var product: Product? {
        products.first { $0.id == Self.productId }
    }

    var isBusy: Bool {
        switch state {
        case .loading, .purchasing, .verifying: return true
        case .idle, .pending, .failed: return false
        }
    }

    // MARK: - Launch

    /// Call once at app launch. Listens for transactions that arrive outside `purchase()`: Ask to Buy
    /// approvals, purchases on another device, and any transaction left unfinished because the
    /// server call failed last time. Also reads the local entitlement.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handleUpdate(result)
            }
        }
        Task {
            await refreshLocalEntitlement()
        }
    }

    /// Back to `.idle` when the paywall opens or closes: a `failed` banner should not outlive its
    /// screen, and `didRedeem` only means anything for the sheet that is open.
    func reset() {
        guard !isBusy else { return }
        state = .idle
        didRedeem = false
    }

    // MARK: - Products

    func loadProducts() async {
        guard product == nil, state != .loading else { return }
        state = .loading
        do {
            products = try await Product.products(for: [Self.productId])
            state = product == nil ? .failed(PassError.productsUnavailable.userMessage) : .idle
        } catch {
            state = .failed(Self.message(for: error, fallback: .productsUnavailable))
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard !isBusy else { return }
        guard let product else {
            await loadProducts()
            return
        }
        state = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // StoreKit could not verify Apple's signature; nothing to send to the server.
                    state = .failed(PassError.verificationFailed.userMessage)
                    return
                }
                state = .verifying
                try await redeem(jws: verification.jwsRepresentation)
                await transaction.finish()
                didRedeem = true
                hasLocalEntitlement = true
                state = .idle
            case .userCancelled:
                state = .idle
            case .pending:
                state = .pending
            @unknown default:
                state = .idle
            }
        } catch {
            if Self.isCancelled(error) {
                state = .idle
            } else {
                // A redeem failure leaves the transaction unfinished: StoreKit delivers it again on
                // the next launch (`Transaction.updates`), and Restore also finds it.
                state = .failed(Self.message(for: error, fallback: .purchaseFailed))
            }
        }
    }

    // MARK: - Restore

    /// Apple requirement. `AppStore.sync()` may show an App Store sign-in; then every verified,
    /// unrevoked Family Pass entitlement is sent to the server. The transaction is finished only
    /// after `redeemFamilyPass` succeeds.
    func restore() async {
        guard !isBusy else { return }
        state = .verifying
        do {
            do {
                try await AppStore.sync()
            } catch {
                if Self.isCancelled(error) || AppError.isOffline(error) { throw error }
                throw PassError.restoreFailed
            }
            var found = false
            var lastError: Error?
            for await result in StoreKit.Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.productID == Self.productId,
                      transaction.revocationDate == nil else { continue }
                found = true
                do {
                    try await redeem(jws: result.jwsRepresentation)
                    await transaction.finish()
                    didRedeem = true
                    hasLocalEntitlement = true
                    state = .idle
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            if !found { throw PassError.noPurchaseFound }
            state = .idle
        } catch {
            if Self.isCancelled(error) {
                state = .idle
            } else {
                state = .failed(Self.message(for: error, fallback: .restoreFailed))
            }
        }
    }

    // MARK: - Private

    private func refreshLocalEntitlement() async {
        var entitled = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productId,
               transaction.revocationDate == nil {
                entitled = true
                break
            }
        }
        hasLocalEntitlement = entitled
    }

    private func handleUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result,
              transaction.productID == Self.productId else { return }
        if transaction.revocationDate != nil {
            // Refund / revocation: the server clears `pass` from App Store Server Notifications.
            await transaction.finish()
            hasLocalEntitlement = false
            return
        }
        do {
            try await redeem(jws: result.jwsRepresentation)
            await transaction.finish()
            didRedeem = true
            hasLocalEntitlement = true
            if state == .pending {
                // Ask to Buy approved while the paywall was open.
                state = .idle
            }
        } catch {
            // Not signed in yet, offline, or bound to another account: left unfinished so StoreKit
            // delivers it again next launch. Restore purchases covers it too.
        }
    }

    /// `redeemFamilyPass({ jws })` -> `{ ok: true }`. Throws `PassError`.
    private func redeem(jws: String) async throws {
        let callable = Functions.functions(region: Self.region).httpsCallable("redeemFamilyPass")
        callable.timeoutInterval = 15   // DESIGN-SPEC §14.3: the sheet is locked while verifying
        do {
            _ = try await callable.call(["jws": jws])
        } catch {
            throw PassError.fromCallable(error)
        }
    }

    private static func isCancelled(_ error: Error) -> Bool {
        if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError {
            return true
        }
        return false
    }

    private static func message(for error: Error, fallback: PassError) -> String {
        if error is PassError { return error.userMessage }
        if AppError.isOffline(error) { return AppError.offline }
        if let storeKitError = error as? StoreKitError, case .networkError = storeKitError {
            return AppError.offline
        }
        return fallback.userMessage
    }
}
