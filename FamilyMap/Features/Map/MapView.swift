import SwiftUI
import MapKit
import UIKit

/// A member with a known location, as drawn on the map.
struct MemberPin: Identifiable {
    let id: String
    let member: AppUser
    let point: LocationPoint
    let isMe: Bool
    let isSelected: Bool

    var coordinate: CLLocationCoordinate2D { point.coordinate }

    /// Draw order: stale, fresh, me, and the selected pin last (on top).
    var layer: Int {
        if isSelected { return 3 }
        if isMe { return 2 }
        return point.isStale ? 0 : 1
    }
}

/// One annotation on the Map tab. The iOS 16 `Map` takes a single item list, so places and members
/// share it; places come first so they are added, and drawn, below the member pins.
private enum MapAnnotationItem: Identifiable {
    case place(Place)
    case member(MemberPin)

    var id: String {
        switch self {
        case .place(let place): return "place-\(place.id ?? place.name)"
        case .member(let pin): return "member-\(pin.id)"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .place(let place): return place.coordinate
        case .member(let pin): return pin.coordinate
        }
    }
}

/// Screen-space de-overlap for member pins: pins that would sit closer than `threshold` points at the
/// current zoom are spread evenly on a small circle around their shared centre. Coordinates never
/// change; each pin's view is offset inside its annotation.
enum PinSpread {
    /// Pin diameter (40 pt avatar + 2 pt ring each side).
    static let threshold: Double = 44

    /// View offset per member id. Members that stand alone are absent (no offset).
    static func offsets(for pins: [MemberPin], region: MKCoordinateRegion, mapSize: CGSize) -> [String: CGSize] {
        let width = Double(mapSize.width)
        let height = Double(mapSize.height)
        guard pins.count > 1, width > 1, height > 1,
              region.span.longitudeDelta > 0, region.span.latitudeDelta > 0 else { return [:] }

        // Points per degree of longitude. Mercator: near latitude L a degree of latitude is drawn
        // 1/cos(L) taller. The smaller scale wins, as MapKit fits both spans into the frame.
        let cosCentre = max(cos(region.center.latitude * .pi / 180), 0.01)
        let pointsPerDegree = min(width / region.span.longitudeDelta, height / region.span.latitudeDelta * cosCentre)

        /// Screen vector from `origin` to `coordinate` (y grows downwards).
        func screenVector(from origin: CLLocationCoordinate2D, to coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            let cosLat = max(cos((origin.latitude + coordinate.latitude) / 2 * .pi / 180), 0.01)
            return (
                (coordinate.longitude - origin.longitude) * pointsPerDegree,
                (origin.latitude - coordinate.latitude) * pointsPerDegree / cosLat
            )
        }

        // Stable order by uid, so pins keep their seat on the circle between renders.
        let sorted = pins.sorted { $0.id < $1.id }
        // Single-linkage groups: pins chained together by near neighbours share one label in `group`.
        var group = Array(sorted.indices)
        for i in sorted.indices {
            for j in sorted.indices where j > i && group[j] != group[i] {
                let vector = screenVector(from: sorted[i].coordinate, to: sorted[j].coordinate)
                guard hypot(vector.x, vector.y) < threshold else { continue }
                let from = group[j]
                let to = group[i]
                for k in group.indices where group[k] == from {
                    group[k] = to
                }
            }
        }

        var offsets: [String: CGSize] = [:]
        for label in Set(group) {
            let members = sorted.indices.filter { group[$0] == label }.map { sorted[$0] }
            let count = members.count
            guard count > 1 else { continue }
            let centre = CLLocationCoordinate2D(
                latitude: members.map(\.coordinate.latitude).reduce(0, +) / Double(count),
                longitude: members.map(\.coordinate.longitude).reduce(0, +) / Double(count)
            )
            let radius = count <= 3 ? 26.0 : min(22.0 + 6.0 * Double(count), 60.0)
            // Two pins sit side by side; three or more start at the top and go clockwise.
            let startAngle = count == 2 ? Double.pi : -Double.pi / 2
            for (seat, pin) in members.enumerated() {
                let angle = startAngle + 2 * Double.pi * Double(seat) / Double(count)
                let own = screenVector(from: centre, to: pin.coordinate)
                offsets[pin.id] = CGSize(
                    width: radius * cos(angle) - own.x,
                    height: radius * sin(angle) - own.y
                )
            }
        }
        return offsets
    }
}

/// The map's frame and how much of its top is covered by the top stack (pill, status, banner).
/// Fits and centring aim at the strip between the top stack and the drawer.
struct MapViewport {
    let size: CGSize
    let topInset: CGFloat
}

@MainActor
final class MapViewModel: ObservableObject {
    /// Default region until members load (Sydney).
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    @Published var showSOSSheet = false

    /// After the first fit the camera only moves on Fit everyone or a member selection,
    /// so later snapshots and my own shares never undo the user's pan.
    private var hasFitted = false
    private var centredOnDevice = false

    private static let minSpan: CLLocationDegrees = 0.01
    private static let fitPadding = 1.3

    /// First load: fit the given members. With nobody located, fall back to the device's last known fix.
    func fitOnFirstLoad(
        _ coordinates: [CLLocationCoordinate2D],
        in viewport: MapViewport,
        deviceLocation: CLLocationCoordinate2D?
    ) {
        guard !hasFitted else { return }
        if let fitted = Self.region(fitting: coordinates, in: viewport) {
            region = fitted
            hasFitted = true
        } else if !centredOnDevice, let deviceLocation,
                  let nearMe = Self.region(fitting: [deviceLocation], in: viewport) {
            region = nearMe
            centredOnDevice = true
        }
    }

    func fitEveryone(_ coordinates: [CLLocationCoordinate2D], in viewport: MapViewport) {
        guard let fitted = Self.region(fitting: coordinates, in: viewport) else { return }
        region = fitted
        hasFitted = true
    }

    /// Selecting a member: centre them at span 0.01 deg inside the visible strip.
    func centre(on coordinate: CLLocationCoordinate2D, in viewport: MapViewport) {
        guard let centred = Self.region(fitting: [coordinate], in: viewport) else { return }
        region = centred
        hasFitted = true
    }

    /// Bounding box + 30% padding (min 0.01 deg) placed in the visible strip of the map frame.
    static func region(fitting coordinates: [CLLocationCoordinate2D], in viewport: MapViewport) -> MKCoordinateRegion? {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLng = longitudes.min(), let maxLng = longitudes.max() else { return nil }
        let boxCenterLat = (minLat + maxLat) / 2
        let boxCenterLng = (minLng + maxLng) / 2
        let latNeeded = max((maxLat - minLat) * fitPadding, minSpan)
        let lngNeeded = (maxLng - minLng) * fitPadding

        let width = Double(viewport.size.width)
        let height = Double(viewport.size.height)
        let visibleHeight = height - Double(viewport.topInset)
        guard width > 1, height > 1, visibleHeight > 1 else {
            // Layout not known yet: a plain padded box.
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: boxCenterLat, longitude: boxCenterLng),
                span: MKCoordinateSpan(latitudeDelta: min(latNeeded, 170), longitudeDelta: min(max(lngNeeded, minSpan), 360))
            )
        }

        // Mercator: near latitude L, one degree of latitude is drawn 1/cos(L) taller than one of longitude.
        let cosLat = max(cos(boxCenterLat * .pi / 180), 0.01)
        let visibleLat = max(latNeeded, lngNeeded * (visibleHeight / width) * cosLat)
        let totalLat = min(visibleLat * height / visibleHeight, 170)
        let totalLng = min(totalLat * (width / height) / cosLat, 360)
        // Move the centre north so the box sits in the middle of the visible strip, not under the top stack.
        let centerLat = min(max(boxCenterLat + totalLat * Double(viewport.topInset) / 2 / height, -85), 85)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: boxCenterLng),
            span: MKCoordinateSpan(latitudeDelta: totalLat, longitudeDelta: totalLng)
        )
    }
}

/// Map tab (DESIGN-SPEC 11): full-bleed map, top stack, member drawer and floating SOS.
struct MapView: View {
    var body: some View {
        GeometryReader { geo in
            MapHome(available: geo.size.height, width: geo.size.width, safeTop: geo.safeAreaInsets.top)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

@MainActor
private struct MapHome: View {
    /// Safe-area top to tab-bar top.
    let available: CGFloat
    let width: CGFloat
    let safeTop: CGFloat

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var locationSync: LocationSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var placeNames = PlaceNameResolver()

    @State private var drawerSnap: DrawerSnap = .half
    @State private var dragTranslation: CGFloat = 0
    @State private var selectedMemberId: String?
    /// A fresh token per request, so tapping the same pin again scrolls again.
    @State private var scrollRequest: DrawerScrollRequest?
    /// Measured height of the top stack, from the safe-area top (includes its 8 pt top padding).
    @State private var topStackHeight: CGFloat = 104

    private static let sosSize: CGFloat = 64
    /// The floating SOS fades out over this distance as the drawer approaches full.
    private static let sosFadeDistance: CGFloat = 40

    private var myId: String? { appState.currentUser?.id }

    // MARK: - Layout

    private var settledDrawerHeight: CGFloat {
        DrawerMetrics.height(for: drawerSnap, available: available)
    }

    private var liveDrawerHeight: CGFloat {
        let full = DrawerMetrics.height(for: .full, available: available)
        return min(max(settledDrawerHeight - dragTranslation, DrawerMetrics.collapsedHeight), full)
    }

    /// The map frame ends at the settled drawer top, so MapKit keeps its logo and Legal link visible.
    private func viewport(for snap: DrawerSnap) -> MapViewport {
        let drawer = DrawerMetrics.height(for: snap, available: available)
        return MapViewport(
            size: CGSize(width: width, height: safeTop + available - drawer),
            topInset: safeTop + topStackHeight + FMSpacing.sm
        )
    }

    /// 1 in collapsed/half, fades over the last 40 pt toward full, 0 when it would overlap the top stack.
    private var floatingSOSOpacity: Double {
        let full = DrawerMetrics.height(for: .full, available: available)
        let fade = Double(min(max((full - liveDrawerHeight) / Self.sosFadeDistance, 0), 1))
        let sosTop = available - liveDrawerHeight - FMSpacing.md - Self.sosSize
        return sosTop < topStackHeight ? 0 : fade
    }

    // MARK: - Data

    private var pins: [MemberPin] {
        appState.members
            .compactMap { member -> MemberPin? in
                guard let id = member.id, let point = member.lastLocation else { return nil }
                return MemberPin(id: id, member: member, point: point, isMe: id == myId, isSelected: id == selectedMemberId)
            }
            .sorted { lhs, rhs in
                lhs.layer != rhs.layer ? lhs.layer < rhs.layer : lhs.member.name < rhs.member.name
            }
    }

    /// Saved places first, so they sit below the member pins.
    private var mapItems: [MapAnnotationItem] {
        appState.places.map(MapAnnotationItem.place) + pins.map(MapAnnotationItem.member)
    }

    /// First fit and Fit everyone: fresh members (<= 24 h); everyone located if all are stale.
    private var fitCoordinates: [CLLocationCoordinate2D] {
        let fresh = pins.filter { !$0.point.isStale }
        return (fresh.isEmpty ? pins : fresh).map(\.coordinate)
    }

    private struct DrawerEntry: Identifiable {
        let id: String
        let member: AppUser
        let isMe: Bool
    }

    /// You, then others by latest update (stale fall below fresh), then members without a location.
    private var drawerEntries: [DrawerEntry] {
        appState.members
            .compactMap { member -> DrawerEntry? in
                guard let id = member.id else { return nil }
                return DrawerEntry(id: id, member: member, isMe: id == myId)
            }
            .sorted { lhs, rhs in
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                switch (lhs.member.lastLocation, rhs.member.lastLocation) {
                case let (left?, right?): return left.displayDate > right.displayDate
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.member.name < rhs.member.name
                }
            }
    }

    /// Located members outside every saved place. Only these are reverse-geocoded; a member inside a
    /// place reads "At {place}" and costs no geocoder call.
    private var membersToGeocode: [AppUser] {
        appState.members.filter { member in
            guard let point = member.lastLocation else { return false }
            return placeFor(location: point, places: appState.places) == nil
        }
    }

    /// Changes whenever a geocoded member's rounded coordinate changes, or a member enters or leaves a
    /// saved place; drives reverse geocoding.
    private var placeKeys: [String] {
        membersToGeocode.compactMap { member -> String? in
            guard let point = member.lastLocation else { return nil }
            return "\(member.id ?? "")|\(PlaceNameResolver.key(for: point))"
        }
    }

    /// Drawer place line (STAGE-3.6-CONTRACT §4): "At {place}" > "Near {street}, {suburb}" >
    /// "Near {suburb}" > "Location shared" > "No location yet".
    private func placeLine(for member: AppUser) -> PlaceNameResolver.PlaceName {
        if let point = member.lastLocation, let place = placeFor(location: point, places: appState.places) {
            return PlaceNameResolver.PlaceName(display: "At \(place.name)", spoken: "at \(place.name)")
        }
        return placeNames.place(for: member)
    }

    private var statusText: String? {
        switch locationSync.status {
        case .sharing: return "Sharing…"
        case .shared: return "Shared just now"
        case .idle, .failed: return nil
        }
    }

    private enum MapBanner {
        case locationOff
        case failure(String)
    }

    private var activeBanner: MapBanner? {
        if locationService.isDenied { return .locationOff }
        if let message = locationSync.status.errorMessage { return .failure(message) }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Shows only in the drawer's rounded top corners.
            Color.fm.background
                .ignoresSafeArea(edges: .top)

            mapLayer
                .padding(.bottom, settledDrawerHeight)
                .ignoresSafeArea(edges: .top)
                .accessibilitySortPriority(2)

            drawer
                .frame(height: liveDrawerHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilitySortPriority(0)

            SOSButton {
                viewModel.showSOSSheet = true
            }
            .padding(.trailing, FMSpacing.lg)
            .padding(.bottom, liveDrawerHeight + FMSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .opacity(floatingSOSOpacity)
            .allowsHitTesting(floatingSOSOpacity > 0.5)
            .accessibilityHidden(floatingSOSOpacity < 0.5)
            .accessibilitySortPriority(1)

            topStack
                .accessibilitySortPriority(3)
        }
        .sheet(isPresented: $viewModel.showSOSSheet) {
            // Injected explicitly, whatever a sheet inherits on iOS 16.
            SOSConfirmSheet()
                .environmentObject(appState)
                .environmentObject(locationService)
                .environmentObject(locationSync)
        }
        .onAppear {
            viewModel.fitOnFirstLoad(
                fitCoordinates,
                in: viewport(for: drawerSnap),
                deviceLocation: locationService.lastKnownLocation?.coordinate
            )
            placeNames.resolve(membersToGeocode)
            handleFocusRequest(appState.focusMemberId)
        }
        .onDisappear {
            // Fallback opening centre for a new place (DESIGN-SPEC 12.2).
            appState.lastMapCentre = viewModel.region.center
        }
        .onChange(of: pins.map(\.id).sorted()) { _ in
            viewModel.fitOnFirstLoad(fitCoordinates, in: viewport(for: drawerSnap), deviceLocation: nil)
        }
        .onChange(of: placeKeys) { _ in
            placeNames.resolve(membersToGeocode)
        }
        .onChange(of: appState.focusMemberId) { memberId in
            handleFocusRequest(memberId)
        }
        .onChange(of: scenePhase) { phase in
            // Back in the foreground: place lines that failed (e.g. offline) are tried again.
            if phase == .active {
                placeNames.retryFailures()
            }
        }
    }

    // MARK: - Map

    /// Relative times and staleness on the pins re-render every minute.
    /// The region is published, so this body already re-runs on every zoom and pan step; the pin
    /// spread is worked out here from the live region (a handful of members, so it costs nothing).
    private var mapLayer: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let spread = PinSpread.offsets(
                for: pins,
                region: viewModel.region,
                mapSize: viewport(for: drawerSnap).size
            )
            Map(
                coordinateRegion: $viewModel.region,
                showsUserLocation: false,
                annotationItems: mapItems
            ) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    annotationView(for: item, spread: spread)
                }
            }
        }
    }

    @ViewBuilder
    private func annotationView(for item: MapAnnotationItem, spread: [String: CGSize]) -> some View {
        switch item {
        case .place(let place):
            PlaceAnnotationView(place: place)
        case .member(let pin):
            let offset = spread[pin.id] ?? .zero
            MemberPinView(member: pin.member, point: pin.point, isMe: pin.isMe, isSelected: pin.isSelected) {
                selectFromPin(pin.id)
            }
            // The whole tappable pin (avatar + name) moves. The matching padding grows the annotation
            // symmetrically around the coordinate, so the moved pin stays inside its hit-test bounds.
            .offset(offset)
            .padding(.horizontal, abs(offset.width))
            .padding(.vertical, abs(offset.height))
        }
    }

    // MARK: - Top stack

    private var topStack: some View {
        VStack(spacing: FMSpacing.sm) {
            ZStack {
                familyPill
                    .padding(.horizontal, FMSize.minTapTarget + FMSpacing.sm)
                HStack {
                    Spacer()
                    mapButton(systemImage: "location.fill", label: "Refresh my location") { manualShare() }
                        .disabled(locationSync.status == .sharing)
                }
            }
            .frame(height: FMSize.minTapTarget)

            // In full the drawer header shows the status and the banner moves into the list.
            if drawerSnap != .full {
                ZStack {
                    statusCapsule
                        .padding(.horizontal, FMSize.minTapTarget + FMSpacing.sm)
                    HStack {
                        Spacer()
                        mapButton(systemImage: "person.2.circle", label: "Fit everyone") {
                            viewModel.fitEveryone(fitCoordinates, in: viewport(for: drawerSnap))
                        }
                        .disabled(pins.isEmpty)
                    }
                }
                .frame(height: FMSize.minTapTarget)

                if let banner = activeBanner {
                    bannerView(banner)
                }
            }
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.top, FMSpacing.sm)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TopStackHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(TopStackHeightKey.self) { height in
            topStackHeight = height
        }
    }

    /// Family name as stored. Not interactive (one family per account).
    private var familyPill: some View {
        Text(appState.family?.name ?? "Family")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, FMSpacing.lg)
            .frame(height: 36)
            .background(.thinMaterial, in: Capsule())
            .accessibilityAddTraits(.isHeader)
    }

    /// "Sharing..." while in flight, "Shared just now" for 2 s after success, else hidden.
    @ViewBuilder
    private var statusCapsule: some View {
        if let text = statusText {
            HStack(spacing: FMSpacing.sm) {
                if locationSync.status == .sharing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark")
                        .foregroundColor(Color.fm.accent)
                }
                Text(text)
                    .lineLimit(1)
            }
            .font(.footnote)
            .padding(.horizontal, FMSpacing.md)
            .frame(height: 32)
            .background(.thinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private func mapButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
                .background(.thinMaterial, in: Circle())
                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func bannerView(_ banner: MapBanner) -> some View {
        switch banner {
        case .locationOff:
            InfoBanner(
                systemImage: "location.slash",
                title: "Location is off",
                message: "Turn it on to share where you are with your family.",
                style: .warning,
                actionTitle: "Open Settings",
                action: { openSettings() }
            )
            .floatingOverMap()
        case .failure(let message):
            ErrorBanner(message: message)
                .floatingOverMap()
                .onTapGesture { locationSync.dismissError() }
                .accessibilityAction(named: "Dismiss") { locationSync.dismissError() }
        }
    }

    // MARK: - Drawer

    private var drawer: some View {
        MemberDrawer(
            snap: $drawerSnap,
            dragTranslation: $dragTranslation,
            available: available,
            scrollRequest: scrollRequest
        ) {
            drawerHeader
        } content: {
            drawerList
        }
    }

    private var headerTitle: String {
        if drawerSnap == .full, let statusText { return statusText }
        let count = appState.members.count
        return count <= 1 ? "Just you" : "\(count) people"
    }

    private var drawerHeader: some View {
        HStack {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color.fm.textSecondary)
                .lineLimit(1)
            Spacer()
            // SOS is always one tap away: here whenever the floating button is fading or hidden.
            if floatingSOSOpacity < 1 {
                SOSButton(style: .headerCapsule) {
                    viewModel.showSOSSheet = true
                }
            }
        }
        .padding(.horizontal, FMSpacing.lg)
    }

    /// Rows re-render every minute so "Updated x min ago" keeps ticking.
    private var drawerList: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(spacing: 0) {
                if drawerSnap == .full, let banner = activeBanner {
                    bannerView(banner)
                        .padding(.horizontal, FMSpacing.lg)
                        .padding(.bottom, FMSpacing.sm)
                }

                ForEach(drawerEntries) { entry in
                    DrawerMemberRow(
                        member: entry.member,
                        isMe: entry.isMe,
                        place: placeLine(for: entry.member),
                        isExpanded: entry.id == selectedMemberId,
                        isSharing: locationSync.status == .sharing,
                        onTap: { toggleRow(entry.id) },
                        onOpenInMaps: { openInMaps(entry.member) },
                        onMessage: { appState.selectedTab = .chat },
                        onCheckIn: { manualShare() }
                    )
                    .id(entry.id)
                    Divider()
                        .padding(.leading, 72)
                }

                if appState.members.count == 1, let code = appState.family?.inviteCode {
                    InviteRow(inviteCode: code)
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleRow(_ memberId: String) {
        if selectedMemberId == memberId {
            withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
                selectedMemberId = nil
            }
        } else {
            // Same as a pin tap: a collapsed drawer lifts to half so the expanded row is visible.
            select(memberId, liftDrawer: true)
        }
    }

    /// Pin tap: re-tapping the selected pin deselects (like its row); otherwise select and show.
    private func selectFromPin(_ memberId: String) {
        if selectedMemberId == memberId {
            toggleRow(memberId)
        } else {
            showMember(memberId)
        }
    }

    /// Select, lift a collapsed drawer to half and scroll the row into view. Never deselects.
    private func showMember(_ memberId: String) {
        select(memberId, liftDrawer: true)
        scrollRequest = DrawerScrollRequest(rowId: memberId)
    }

    /// One member at a time: expand their row and centre them (span 0.01 deg) in the visible strip.
    /// Members without a location only expand (no map move), but still lift a collapsed drawer.
    private func select(_ memberId: String, liftDrawer: Bool) {
        withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
            selectedMemberId = memberId
        }
        let lifts = liftDrawer && drawerSnap == .collapsed
        if lifts {
            withAnimation(DrawerMetrics.snapAnimation(reduceMotion: reduceMotion)) {
                drawerSnap = .half
            }
        }
        guard let coordinate = pins.first(where: { $0.id == memberId })?.coordinate else { return }
        if lifts {
            // Centre once the map frame has shrunk for the taller drawer.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                viewModel.centre(on: coordinate, in: viewport(for: .half))
            }
        } else {
            viewModel.centre(on: coordinate, in: viewport(for: drawerSnap))
        }
    }

    /// Family tab or a push asked to show a member: centre now, then select after the tab switch has
    /// landed. A member without a location only expands (no map move; `showMember` skips it).
    private func handleFocusRequest(_ memberId: String?) {
        guard let memberId else { return }
        appState.focusMemberId = nil
        if let coordinate = pins.first(where: { $0.id == memberId })?.coordinate {
            viewModel.centre(on: coordinate, in: viewport(for: drawerSnap))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            showMember(memberId)
        }
    }

    /// Refresh button and Check in: light haptic on tap; the result is announced to VoiceOver, with an
    /// error haptic on failure. Auto shares (foreground) stay silent.
    private func manualShare() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            await locationSync.share(source: .manual)
            switch locationSync.status {
            case .shared:
                UIAccessibility.post(notification: .announcement, argument: "Shared just now")
            case .failed(let message):
                UIAccessibility.post(notification: .announcement, argument: message)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .idle, .sharing:
                break
            }
        }
    }

    /// Apple Maps at the member's coordinate, labelled with their name.
    private func openInMaps(_ member: AppUser) {
        guard let point = member.lastLocation else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
        item.name = member.name
        item.openInMaps(launchOptions: nil)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct TopStackHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Opaque backing for banners drawn over map tiles.
    func floatingOverMap() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: FMRadius.card))
            .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
