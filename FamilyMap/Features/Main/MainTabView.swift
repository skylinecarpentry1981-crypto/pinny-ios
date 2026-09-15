import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var locationSync: LocationSync
    @Environment(\.scenePhase) private var scenePhase
    /// The priming sheet is offered once per install (DESIGN-SPEC §13.1); "Not now" is final.
    @AppStorage("didOfferNotificationPriming") private var didOfferPriming = false
    @State private var showPriming = false

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                MapView()
            }
            .tabItem { Label("Map", systemImage: "map.fill") }
            .tag(MainTab.map)

            NavigationStack {
                ChatView()
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(MainTab.chat)

            NavigationStack {
                FamilyView()
            }
            .tabItem { Label("Family", systemImage: "person.2.fill") }
            .tag(MainTab.family)
        }
        // This view only exists while authState == .ready. Share once on open and on every return
        // to the foreground (LocationSync throttles auto-shares to one per 2 minutes).
        .task {
            if scenePhase == .active {
                await locationSync.shareIfNeeded()
            }
        }
        .task {
            await appState.refreshNotificationStatus()
            offerPrimingIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await locationSync.shareIfNeeded() }
            // Coming back from iOS Settings: the Settings rows follow the new permission.
            Task { await appState.refreshNotificationStatus() }
        }
        .onChange(of: locationService.authorizationStatus) { _ in
            offerPrimingIfNeeded()
        }
        .onChange(of: appState.notificationStatus) { _ in
            offerPrimingIfNeeded()
        }
        .onChange(of: appState.selectedTab) { _ in
            offerPrimingIfNeeded()
        }
        .sheet(isPresented: $showPriming) {
            NotificationPrimingView()
                .environmentObject(appState)
        }
    }

    /// Once, over the Map tab, after the location prompt was answered (whatever the answer) and only
    /// while notification permission is still undecided, so two permission asks never stack.
    private func offerPrimingIfNeeded() {
        guard !didOfferPriming,
              !showPriming,
              appState.authState == .ready,
              appState.selectedTab == .map,
              appState.notificationStatus == .notDetermined,
              locationService.authorizationStatus != .notDetermined else { return }
        didOfferPriming = true
        showPriming = true
    }
}
