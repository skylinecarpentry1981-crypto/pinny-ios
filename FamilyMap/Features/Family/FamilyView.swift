import SwiftUI
import CoreLocation

struct FamilyView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLeaveDialog = false
    @State private var isLeaving = false
    @State private var errorMessage: String?
    @State private var editorTarget: PlaceEditorTarget?
    @State private var placePendingDelete: Place?

    private var myId: String? { appState.currentUser?.id }

    /// Me first, then most recently updated.
    private var sortedMembers: [AppUser] {
        appState.members.sorted { lhs, rhs in
            if lhs.id == myId { return true }
            if rhs.id == myId { return false }
            let l = lhs.lastLocation?.displayDate ?? .distantPast
            let r = rhs.lastLocation?.displayDate ?? .distantPast
            return l > r
        }
    }

    private var isLastMember: Bool {
        appState.members.count <= 1
    }

    private var isAtPlaceLimit: Bool {
        appState.places.count >= Place.maxPerFamily
    }

    /// New place opens on my last shared location, else where the Map tab was looking (DESIGN-SPEC 12.2).
    private var newPlaceCentre: CLLocationCoordinate2D? {
        appState.currentUser?.lastLocation?.coordinate ?? appState.lastMapCentre
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Members (\(appState.members.count))") {
                ForEach(sortedMembers) { member in
                    // Per row (not around the ForEach) so the List still sees separate rows.
                    // Re-renders each minute so "Updated x min ago" and staleness keep ticking.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        MemberRow(member: member, isMe: member.id == myId) {
                            showOnMap(member)
                        }
                    }
                }
            }

            placesSection

            if let code = appState.family?.inviteCode {
                Section {
                    InviteCodeCard(code: code)
                } header: {
                    Text("Invite code")
                } footer: {
                    Text("Anyone with this code can join.")
                }

                if isLastMember {
                    Section {
                        EmptyStateView(
                            systemImage: "person.2",
                            title: "It's just you for now",
                            message: "Share the code above and your family will appear here.",
                            showsMascot: true
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showLeaveDialog = true
                } label: {
                    HStack {
                        Text("Leave family")
                            .foregroundColor(Color.fm.sosRedText)
                        if isLeaving {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLeaving)
            }
        }
        .confirmationDialog("Leave this family?", isPresented: $showLeaveDialog, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                leaveFamily()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isLastMember
                 ? "You're the last member. The family and its chat will be deleted."
                 : "You'll need a new invite code to rejoin.")
        }
        .confirmationDialog(
            placePendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { placePendingDelete != nil },
                set: { if !$0 { placePendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: placePendingDelete
        ) { place in
            Button("Delete", role: .destructive) {
                deletePlace(place)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed for everyone in your family.")
        }
        .fullScreenCover(item: $editorTarget) { target in
            PlaceEditorView(target: target, fallbackCentre: newPlaceCentre)
                .environmentObject(appState)
                .environmentObject(appState.locationService)
                .environmentObject(appState.locationSync)
        }
        .navigationTitle(appState.family?.name ?? "Family")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    /// DESIGN-SPEC 12.1: skeleton until the first snapshot, empty-state text, rows, Add place (hidden at 10).
    private var placesSection: some View {
        Section {
            if !appState.hasLoadedPlaces {
                PlaceSkeletonRow()
            } else {
                if appState.places.isEmpty {
                    Text("Add places like Home or School to see who's there.")
                        .font(.subheadline)
                        .foregroundColor(Color.fm.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(appState.places) { place in
                    PlaceRow(place: place) {
                        editorTarget = .edit(place)
                    }
                    // Not `role: .destructive`: that animates the row away before the confirmation.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            placePendingDelete = place
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                if !isAtPlaceLimit {
                    AddPlaceRow {
                        editorTarget = .new
                    }
                }
            }
        } header: {
            Text(appState.places.isEmpty ? "Places" : "Places (\(appState.places.count))")
        } footer: {
            if isAtPlaceLimit {
                Text("Up to 10 places.")
            }
        }
    }

    /// Reachability first (a queued delete would look done while offline).
    private func deletePlace(_ place: Place) {
        errorMessage = nil
        guard appState.locationSync.isOnline else {
            errorMessage = PlaceError.network.userMessage
            return
        }
        Task { @MainActor in
            do {
                try await appState.deletePlace(place)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// Map tab picks this up: centres on the member (span 0.01 deg), then selects and expands their drawer row.
    private func showOnMap(_ member: AppUser) {
        guard let id = member.id, member.lastLocation != nil else { return }
        appState.focusMemberId = id
        appState.selectedTab = .map
    }

    private func leaveFamily() {
        guard !isLeaving else { return }
        isLeaving = true
        errorMessage = nil
        Task { @MainActor in
            defer { isLeaving = false }
            do {
                try await appState.leaveFamily()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
