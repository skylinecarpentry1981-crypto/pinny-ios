import SwiftUI
import UIKit

/// Loads one avatar photo and keeps it in a cache shared by every avatar.
/// The download runs in an unstructured task, so a row re-render (drawer TimelineView, lazy stacks,
/// map annotation rebuilds) never cancels or restarts it; only a URL change does.
@MainActor
final class AvatarImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private var url: URL?
    private var task: Task<Void, Never>?

    /// The photo for `url` if this loader or the shared cache has it. Lets a freshly created view
    /// draw a cached photo on its first frame, before `load` has run.
    func displayImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        if url == self.url, let image { return image }
        return Self.cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL?) {
        // Same URL: keep the photo or the download in flight. A load that failed is tried again.
        if url == self.url, image != nil || task != nil { return }
        task?.cancel()
        task = nil
        self.url = url
        image = nil
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        task = Task { [weak self] in
            let loaded = await AvatarImageLoader.fetch(url)
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.task = nil
            guard let loaded else { return }
            AvatarImageLoader.cache.setObject(loaded, forKey: url as NSURL)
            self.image = loaded
        }
    }

    /// Downloads and decodes off the main actor. One retry after a short pause.
    private nonisolated static func fetch(_ url: URL) async -> UIImage? {
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return nil }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let decoded = UIImage(data: data) {
                return decoded.preparingForDisplay() ?? decoded
            }
        }
        return nil
    }
}

/// Circular photo, falling back to initials.
/// Initials show while the photo loads and if it fails, so a row never goes blank. Photos come from
/// `AvatarImageLoader`'s shared in-memory cache; the shared URLSession's URLCache keeps the JPEG for
/// later launches (STAGE-8-CONTRACT §3).
struct AvatarView: View {
    let name: String
    var photoURL: String? = nil
    var size: CGFloat = 40

    @StateObject private var loader = AvatarImageLoader()

    private var url: URL? {
        photoURL.flatMap { URL(string: $0) }
    }

    var body: some View {
        Group {
            if let image = loader.displayImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        // Opaque base: the drawer row and map pin draw a solid ring circle behind the avatar, which
        // would otherwise show through the translucent initials tint (accent on accent = no initials).
        .background(Color.fm.background)
        .clipShape(Circle())
        .accessibilityLabel(name)
        .task(id: photoURL) {
            loader.load(url)
        }
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Color.fm.accent.opacity(0.18))
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(Color.fm.accent)
        }
    }

    private var initialsText: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
