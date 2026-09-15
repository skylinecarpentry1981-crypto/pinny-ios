import Foundation
import MapKit

/// Place editor search (DESIGN-SPEC 12.2): Apple `MKLocalSearch`, biased to the visible region.
/// The query goes to Apple; Pinny stores nothing. Searches run on Return only (not per keystroke);
/// typing just cancels a search in flight and clears the list.
@MainActor
final class PlaceSearchModel: ObservableObject {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    enum Phase {
        case idle
        case searching
        case results([Result])
        case noResults
        /// Already mapped through `error.userMessage`.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }

    private var pending: Task<Void, Never>?
    private var activeSearch: MKLocalSearch?

    /// Typing: cancels any search in flight and clears the list. Nothing is sent to Apple.
    func queryChanged() {
        cancelSearch()
        phase = .idle
    }

    /// Return key: searches at once. An empty query clears the list.
    func submit(_ query: String, near region: MKCoordinateRegion, isOnline: Bool) {
        cancelSearch()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        pending = Task { [weak self] in
            await self?.run(text, near: region, isOnline: isOnline)
        }
    }

    private func cancelSearch() {
        pending?.cancel()
        pending = nil
        activeSearch?.cancel()
        activeSearch = nil
    }

    private func run(_ text: String, near region: MKCoordinateRegion, isOnline: Bool) async {
        // Checked first so offline reads as offline, not as a MapKit server failure.
        guard isOnline else {
            phase = .failed(PlaceError.network.userMessage)
            return
        }
        phase = .searching
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = region
        let search = MKLocalSearch(request: request)
        activeSearch = search
        do {
            let response = try await search.start()
            guard !Task.isCancelled else { return }
            let results = response.mapItems.compactMap(Self.result(from:))
            phase = results.isEmpty ? .noResults : .results(results)
        } catch {
            guard !Task.isCancelled else { return }
            if let mapError = error as? MKError, mapError.code == .placemarkNotFound {
                phase = .noResults
            } else {
                phase = .failed(PlaceError.from(error, fallback: .searchFailed).userMessage)
            }
        }
        if activeSearch === search {
            activeSearch = nil
        }
    }

    /// Name on the first line, street + suburb on the second (skipped when it repeats the name).
    private static func result(from item: MKMapItem) -> Result? {
        let placemark = item.placemark
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let title = item.name ?? street
        guard !title.isEmpty else { return nil }
        let subtitle = [street, placemark.locality ?? ""]
            .filter { !$0.isEmpty && $0 != title }
            .joined(separator: ", ")
        return Result(title: title, subtitle: subtitle, coordinate: placemark.coordinate)
    }
}
