import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

/// Profile photo upload / removal (STAGE-8-CONTRACT §2). Resizes on the client, stores the JPEG at
/// `avatars/{uid}.jpg` and writes the download URL to `users/{uid}.photoURL`; the users/{uid}
/// listener delivers the new URL to every screen.
@MainActor
final class PhotoService: ObservableObject {
    enum State: Equatable {
        case idle
        case uploading
        case failed(String)
    }

    /// Contract §2: 512×512 centre-crop square, JPEG quality 0.8.
    static let side: CGFloat = 512
    static let jpegQuality: CGFloat = 0.8

    @Published private(set) var state: State = .idle

    private let familyService: FamilyService

    init(familyService: FamilyService) {
        self.familyService = familyService
    }

    /// Computed so `Storage.storage()` is never called before `FirebaseApp.configure()`.
    private func avatarRef(uid: String) -> StorageReference {
        let storage = Storage.storage()
        storage.maxUploadRetryTime = 15      // DESIGN-SPEC §15: fail within 15 s instead of Firebase's 600 s default
        storage.maxOperationRetryTime = 15
        return storage.reference(withPath: "avatars/\(uid).jpg")
    }

    /// Ends in `.idle` on success or `.failed(message)`; the caller shows the message and calls `reset()`.
    func upload(imageData: Data) async {
        guard state != .uploading else { return }
        guard let uid = Auth.auth().currentUser?.uid else {
            state = .failed(AppError.generic)
            return
        }
        state = .uploading
        // Decoding and resizing a camera-roll photo is too slow for the main thread.
        let jpeg = await Task.detached(priority: .userInitiated) {
            Self.squareJPEG(from: imageData)
        }.value
        guard let jpeg else {
            state = .failed(AppError.photoUpdateFailed)
            return
        }
        do {
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"
            let ref = avatarRef(uid: uid)
            _ = try await ref.putDataAsync(jpeg, metadata: metadata)
            let url = try await ref.downloadURL()
            try await familyService.updatePhotoURL(userId: uid, url: url.absoluteString)
            state = .idle
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Deletes the Storage object (a missing object is fine) and clears `photoURL`.
    func remove() async {
        guard state != .uploading else { return }
        guard let uid = Auth.auth().currentUser?.uid else {
            state = .failed(AppError.generic)
            return
        }
        state = .uploading
        do {
            do {
                try await avatarRef(uid: uid).delete()
            } catch {
                guard Self.isObjectNotFound(error) else { throw error }
            }
            try await familyService.updatePhotoURL(userId: uid, url: nil)
            state = .idle
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func reset() {
        guard state != .uploading else { return }
        state = .idle
    }

    // MARK: - Helpers

    /// Centre-crops to a square and scales to `side`×`side` points at 1× (so exactly 512 px).
    /// `UIImage.draw` applies the EXIF orientation, so the result is always upright.
    nonisolated static func squareJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let source = image.size
        let scale = side / min(source.width, source.height)
        let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return square.jpegData(compressionQuality: jpegQuality)
    }

    private static func isObjectNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == StorageErrorDomain
            && nsError.code == StorageErrorCode.objectNotFound.rawValue
    }

    private static func message(for error: Error) -> String {
        if AppError.isOffline(error) || FamilyError.from(error) == .network { return AppError.offline }
        return AppError.photoUpdateFailed
    }
}
