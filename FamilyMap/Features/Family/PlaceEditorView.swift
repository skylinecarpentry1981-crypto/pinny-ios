import SwiftUI
import MapKit
import UIKit

/// What the Family tab opens the place editor for.
enum PlaceEditorTarget: Identifiable {
    case new
    case edit(Place)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let place): return "edit-\(place.id ?? place.name)"
        }
    }
}

/// Place editor (DESIGN-SPEC 12.2), shown as a `.fullScreenCover`: search field, map with a fixed
/// centre pin and a radius circle drawn in screen space (the iOS 16 SwiftUI `Map` has no overlays),
/// radius slider, name + preset chips. Cancel is the only exit.
///
/// Privacy: "Use my location" takes one fix through `LocationService` and only recentres the map; it
/// is not a share (no Firestore write, no status capsule, no push). The map never shows the user's
/// location dot, which would start continuous updates.
@MainActor
struct PlaceEditorView: View {
    let target: PlaceEditorTarget

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var locationSync: LocationSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var search = PlaceSearchModel()

    @State private var region: MKCoordinateRegion
    @State private var name: String
    /// Metres; `Slider` needs a floating-point value.
    @State private var radius: Double
    @State private var query = ""
    @State private var showsResults = false
    @State private var banner: EditorBanner?
    @State private var isSaving = false
    @State private var isLocating = false
    @State private var showDiscardDialog = false
    /// The map's frame, for the points-per-metre maths.
    @State private var mapSize: CGSize = .zero
    /// New place: the document ID, made on the first Save and reused by every retry, so a save that
    /// timed out but landed can't be created twice.
    @State private var newPlaceId: String?
    @FocusState private var focus: Field?

    /// The "unchanged" baseline. `@State` so it is set once per editor session: the cover's content
    /// re-runs `init` whenever the Family tab re-renders (e.g. my own share moves `fallbackCentre`).
    @State private var initialCentre: CLLocationCoordinate2D
    @State private var initialName: String
    @State private var initialRadius: Int

    private enum Field: Hashable {
        case search
        case name
    }

    /// One banner at a time, directly under the search field.
    private enum EditorBanner: Equatable {
        case locationOff
        case error(String)
    }

    /// Last resort when there is no place, no shared location and no Map tab centre (Sydney, as the Map tab).
    static let defaultCentre = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    private static let presets: [PlaceIcon] = [.home, .school, .work]
    /// About 1 m. MapKit may nudge the centre by less when it lays the map out.
    private static let centreTolerance: CLLocationDegrees = 0.00001
    private static let metresPerDegree = 111_319.49
    private static let saveTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// `fallbackCentre` opens a new place: my last shared location, else the Map tab's centre.
    init(target: PlaceEditorTarget, fallbackCentre: CLLocationCoordinate2D?) {
        self.target = target
        let centre: CLLocationCoordinate2D
        let name: String
        let radius: Int
        switch target {
        case .new:
            centre = fallbackCentre ?? Self.defaultCentre
            name = ""
            radius = Place.defaultRadius
        case .edit(let place):
            centre = place.coordinate
            name = place.name
            radius = place.radius
        }
        _initialCentre = State(initialValue: centre)
        _initialName = State(initialValue: name)
        _initialRadius = State(initialValue: radius)
        _name = State(initialValue: name)
        _radius = State(initialValue: Double(radius))
        _region = State(initialValue: Self.openingRegion(centre: centre, radius: radius))
    }

    // MARK: - Derived

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var radiusMetres: Int { Int(radius) }

    /// The icon follows the name: a preset name (any case) keeps its icon, anything else is `pin`.
    private var icon: PlaceIcon { PlaceIcon.matching(name: name) }

    private var centreMoved: Bool {
        abs(region.center.latitude - initialCentre.latitude) > Self.centreTolerance
            || abs(region.center.longitude - initialCentre.longitude) > Self.centreTolerance
    }

    private var hasChanges: Bool {
        name != initialName || radiusMetres != initialRadius || centreMoved
    }

    private var canSave: Bool {
        !name.isEmpty && !isSaving && (isNew || hasChanges)
    }

    /// Circle diameter in points. Web Mercator is linear in longitude across the width, and conformal,
    /// so metres per point at the centre latitude sizes the circle both ways.
    private var circleDiameter: CGFloat {
        let cosLat = cos(region.center.latitude * .pi / 180)
        let metresAcross = region.span.longitudeDelta * Self.metresPerDegree * cosLat
        guard metresAcross > 0, mapSize.width > 0 else { return 0 }
        let diameter = CGFloat(2 * radius / metresAcross) * mapSize.width
        // Zoomed far in, the circle is clipped anyway; keep the layer a sane size.
        return min(diameter, 4 * max(mapSize.width, mapSize.height))
    }

    private var isShowingResults: Bool {
        guard showsResults else { return false }
        switch search.phase {
        case .results, .noResults, .failed: return true
        case .idle, .searching: return false
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            GeometryReader { screen in
                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, FMSpacing.lg)
                        .padding(.vertical, FMSpacing.sm)
                    mapArea
                    // Search focused -> the panel hides so the results get the room.
                    if focus != .search {
                        bottomPanel(maxHeight: screen.size.height * 0.5)
                    }
                }
            }
            .navigationTitle(isNew ? "New place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.bold)
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $showDiscardDialog, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: query) { _ in
                // Typing only clears the list; the search runs on Return (§12.2).
                banner = nil
                search.queryChanged()
            }
            .onChange(of: name) { newName in
                // Input stops at 30 UTF-16 units, the unit the rules' size() counts (an emoji counts 2+).
                if newName.utf16.count > Place.nameLimit {
                    name = newName.clamped(toUTF16: Place.nameLimit)
                }
            }
            .onChange(of: radiusMetres) { _ in
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: FMSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color.fm.textSecondary)
                .accessibilityHidden(true)
            TextField("Search for an address", text: $query)
                .focused($focus, equals: .search)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    showsResults = true
                    search.submit(query, near: region, isOnline: locationSync.isOnline)
                }
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                        .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, FMSpacing.md)
        .frame(minHeight: FMSize.minTapTarget)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .disabled(isSaving)
    }

    // MARK: - Map

    private var mapArea: some View {
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, interactionModes: [.pan, .zoom])
                .overlay(radiusOverlay)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { mapSize = proxy.size }
                            .onChange(of: proxy.size) { mapSize = $0 }
                    }
                )
                .allowsHitTesting(!isSaving)
                .accessibilityLabel("Place map")
                .accessibilityValue("Circle radius \(Place.radiusSpoken(radiusMetres))")

            VStack(spacing: FMSpacing.sm) {
                if let banner {
                    bannerView(banner)
                } else if isShowingResults {
                    resultsView
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, FMSpacing.lg)
            .padding(.top, FMSpacing.sm)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isShowingResults)

            useMyLocationButton
                .padding(FMSpacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .clipped()
    }

    /// Fixed centre pin and the radius circle, over the map but never in the way of its gestures.
    private var radiusOverlay: some View {
        ZStack {
            Circle()
                .fill(Color.fm.accent.opacity(0.15))
                .overlay(Circle().stroke(Color.fm.accent, lineWidth: 2))
                .frame(width: circleDiameter, height: circleDiameter)
            centrePin
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// SF `mappin` with its tip on the map centre (the saved coordinate) and a 6 pt dot under the tip.
    private var centrePin: some View {
        ZStack {
            Circle()
                .fill(Color.fm.accent)
                .frame(width: 6, height: 6)
            Image(systemName: "mappin")
                .font(.system(size: 32))
                .foregroundColor(Color.fm.accent)
                .frame(height: 40, alignment: .bottom)
                .offset(y: -20)
        }
    }

    private var useMyLocationButton: some View {
        Button {
            useMyLocation()
        } label: {
            ZStack {
                if isLocating {
                    ProgressView()
                } else {
                    Image(systemName: "location.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
            .background(.thinMaterial, in: Circle())
            .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        }
        .accessibilityLabel("Use my location")
        .disabled(isSaving)
    }

    @ViewBuilder
    private func bannerView(_ banner: EditorBanner) -> some View {
        switch banner {
        case .locationOff:
            InfoBanner(
                systemImage: "location.slash",
                title: "Location is off",
                message: "Search for an address, or turn it on in Settings.",
                style: .warning,
                actionTitle: "Open Settings",
                action: { openSettings() }
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
            .onTapGesture { self.banner = nil }
        case .error(let message):
            ErrorBanner(message: message)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
                .onTapGesture { self.banner = nil }
                .accessibilityAction(named: "Dismiss") { self.banner = nil }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        switch search.phase {
        case .idle, .searching:
            EmptyView()
        case .noResults:
            Text("No results. Try a street or suburb.")
                .font(.subheadline)
                .foregroundColor(Color.fm.textSecondary)
                .padding(.horizontal, FMSpacing.lg)
                .frame(maxWidth: .infinity, minHeight: FMSize.minTapTarget, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
        case .failed(let message):
            ErrorBanner(message: message)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
                .onTapGesture { showsResults = false }
                .accessibilityAction(named: "Dismiss") { showsResults = false }
        case .results(let results):
            // Short lists size to their rows; long ones scroll inside half the map height.
            ViewThatFits(in: .vertical) {
                resultRows(results)
                ScrollView {
                    resultRows(results)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
            .frame(maxHeight: max(mapSize.height * 0.5, FMSize.minTapTarget), alignment: .top)
        }
    }

    private func resultRows(_ results: [PlaceSearchModel.Result]) -> some View {
        VStack(spacing: 0) {
            ForEach(results) { result in
                Button {
                    select(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.body)
                            .foregroundColor(Color.fm.textPrimary)
                            .lineLimit(1)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.footnote)
                                .foregroundColor(Color.fm.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, FMSpacing.lg)
                    .padding(.vertical, FMSpacing.xs)
                    .frame(maxWidth: .infinity, minHeight: FMSize.minTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if result.id != results.last?.id {
                    Divider()
                        .padding(.leading, FMSpacing.lg)
                }
            }
        }
    }

    // MARK: - Bottom panel

    /// At accessibility sizes the panel scrolls, capped at half the screen, so the map keeps half.
    @ViewBuilder
    private func bottomPanel(maxHeight: CGFloat) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                panelContent
            }
            .frame(maxHeight: maxHeight)
            .background(Color.fm.background)
        } else {
            panelContent
                .background(Color.fm.background)
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            radiusHeader
            radiusSlider
            nameField
            chips
        }
        .padding(FMSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isSaving)
    }

    /// "Radius   150 m". Hidden from VoiceOver: the slider speaks the same label and value.
    private var radiusHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Radius")
                Spacer()
                Text(Place.radiusText(radiusMetres))
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Radius")
                Text(Place.radiusText(radiusMetres))
                    .monospacedDigit()
            }
        }
        .font(.subheadline)
        .accessibilityHidden(true)
    }

    private var radiusSlider: some View {
        Slider(
            value: $radius,
            in: Double(Place.radiusRange.lowerBound)...Double(Place.radiusRange.upperBound),
            step: Double(Place.radiusStep)
        ) {
            Text("Radius")
        } minimumValueLabel: {
            Text("\(Place.radiusRange.lowerBound)")
                .font(.caption2)
                .accessibilityHidden(true)
        } maximumValueLabel: {
            Text("\(Place.radiusRange.upperBound)")
                .font(.caption2)
                .accessibilityHidden(true)
        } onEditingChanged: { editing in
            if !editing {
                zoomOutIfCircleTooBig()
            }
        }
        .accessibilityValue(Place.radiusSpoken(radiusMetres))
    }

    private var nameField: some View {
        TextField("Name", text: $name)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($focus, equals: .name)
            .onSubmit { focus = nil }
            .padding(.horizontal, FMSpacing.md)
            .frame(minHeight: FMSize.minTapTarget)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Home / School / Work. Wraps to a second line when the row does not fit (large text).
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FMSpacing.sm) {
                ForEach(Self.presets, id: \.self) { preset in
                    chip(preset)
                }
            }
            VStack(alignment: .leading, spacing: FMSpacing.sm) {
                ForEach(Self.presets, id: \.self) { preset in
                    chip(preset)
                }
            }
        }
    }

    /// A chip tap sets the name; the icon follows the name.
    private func chip(_ preset: PlaceIcon) -> some View {
        let selected = icon == preset
        let title = preset.presetName ?? ""
        return Button {
            name = title
        } label: {
            Label(title, systemImage: preset.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? Color.fm.onAccent : Color.fm.accent)
                .padding(.horizontal, FMSpacing.lg)
                .frame(minHeight: FMSize.minTapTarget)
                .background(Capsule().fill(selected ? Color.fm.accent : Color.clear))
                .overlay(Capsule().stroke(Color.fm.accent, lineWidth: selected ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Actions

    /// Zoom kept; the list and keyboard close; the query stays; the name is not changed.
    private func select(_ result: PlaceSearchModel.Result) {
        showsResults = false
        focus = nil
        move(to: MKCoordinateRegion(center: result.coordinate, span: region.span))
    }

    /// One fix, then recentre (zoom kept). Denied -> the Location is off banner; the button stays
    /// enabled so a tap always explains itself.
    private func useMyLocation() {
        guard !isLocating else { return }
        banner = nil
        if locationService.isDenied {
            banner = .locationOff
            return
        }
        isLocating = true
        Task { @MainActor in
            defer { isLocating = false }
            do {
                let fix = try await locationService.requestCurrentLocation()
                move(to: MKCoordinateRegion(center: fix.coordinate, span: region.span))
            } catch LocationError.denied, LocationError.restricted {
                banner = .locationOff
            } catch is CancellationError {
                // Signed out mid-fix (the editor is going away), or an SOS took the fix over.
            } catch {
                banner = .error(error.userMessage)
            }
        }
    }

    /// If the circle is wider than the map's short side after a slider change, zoom out to 80 % of it.
    private func zoomOutIfCircleTooBig() {
        let shortSide = Double(min(mapSize.width, mapSize.height))
        guard shortSide > 1, Double(circleDiameter) > shortSide else { return }
        let metresPerPoint = 2 * radius / (0.8 * shortSide)
        move(to: MKCoordinateRegion(
            center: region.center,
            latitudinalMeters: metresPerPoint * Double(mapSize.height),
            longitudinalMeters: metresPerPoint * Double(mapSize.width)
        ))
    }

    /// Reduce Motion: no animated recentre or zoom.
    private func move(to newRegion: MKCoordinateRegion) {
        if reduceMotion {
            region = newRegion
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                region = newRegion
            }
        }
    }

    private func cancel() {
        if hasChanges {
            showDiscardDialog = true
        } else {
            dismiss()
        }
    }

    /// Local checks first (name, 10-place limit, reachability), then the write with a 10 s timeout.
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // UTF-16 units, as the rules count them.
        guard (1...Place.nameLimit).contains(trimmed.utf16.count) else {
            fail(PlaceError.invalidName)
            focus = .name
            return
        }
        // A retried save's own place (shown at once by the listener) doesn't count towards the limit.
        if isNew, appState.places.filter({ $0.id != newPlaceId }).count >= Place.maxPerFamily {
            fail(PlaceError.limitReached)
            return
        }
        guard locationSync.isOnline else {
            fail(PlaceError.network)
            return
        }
        let placeId: String
        if isNew {
            guard let id = newPlaceId ?? appState.newPlaceId() else {
                fail(PlaceError.saveFailed)
                return
            }
            newPlaceId = id
            placeId = id
        } else {
            placeId = ""
        }
        let draft = PlaceDraft(
            name: trimmed,
            icon: PlaceIcon.matching(name: trimmed),
            coordinate: region.center,
            radius: radiusMetres
        )
        let target = self.target
        let appState = self.appState
        focus = nil
        banner = nil
        isSaving = true
        Task { @MainActor in
            do {
                try await withTimeout(
                    nanoseconds: Self.saveTimeoutNanoseconds,
                    timeoutError: PlaceError.saveFailed
                ) {
                    switch target {
                    case .new:
                        try await appState.addPlace(draft, placeId: placeId)
                    case .edit(let place):
                        try await appState.updatePlace(place, with: draft)
                    }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                isSaving = false
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        banner = .error(error.userMessage)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// First zoom makes the circle 60 % of the map width. The latitude span is asked for smaller so the
    /// width is what MapKit fits to (any map taller than half its width).
    private static func openingRegion(centre: CLLocationCoordinate2D, radius: Int) -> MKCoordinateRegion {
        let across = 2 * Double(radius) / 0.6
        return MKCoordinateRegion(center: centre, latitudinalMeters: across * 0.5, longitudinalMeters: across)
    }
}
