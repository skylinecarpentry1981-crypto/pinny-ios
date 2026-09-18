import SwiftUI
import PhotosUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var passService: PassService
    @EnvironmentObject private var photoService: PhotoService
    @StateObject private var deleteFlow = DeleteAccountViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPaywall = false
    @State private var isRestoring = false
    @State private var notifyOnCheckIn = true
    @State private var isSavingNotify = false
    @State private var isRequestingNotifications = false
    @State private var showNameAlert = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @State private var showSignOutDialog = false
    @State private var errorMessage: String?

    private var currentName: String {
        appState.currentUser?.name ?? ""
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Profile") {
                profilePhotoRow
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text("Change photo")
                        .foregroundColor(Color.fm.accent)
                }
                .disabled(isUpdatingPhoto)
                if appState.currentUser?.photoURL != nil {
                    Button(role: .destructive) {
                        removePhoto()
                    } label: {
                        Text("Remove photo")
                            .foregroundColor(Color.fm.sosRedText)
                    }
                    .disabled(isUpdatingPhoto)
                }
                Button {
                    draftName = currentName
                    showNameAlert = true
                } label: {
                    HStack(spacing: FMSpacing.md) {
                        Text("Display name")
                            .foregroundColor(Color.fm.textPrimary)
                        Spacer()
                        if isSavingName {
                            ProgressView()
                        } else {
                            Text(currentName)
                                .foregroundColor(Color.fm.textSecondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                    }
                }
                .disabled(isSavingName)
            }

            if let status = appState.notificationStatus {
                notificationsSection(status)
            }

            familyPassSection

            Section("Privacy") {
                Text("Your location and battery level are shared with your family only when you open Pinny, tap Refresh or Check in, or send an SOS. There is no background tracking. Delete your account at any time to remove your account and location data. Your profile photo is visible to people who use Pinny with you.")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
                if let privacyURL = URL(string: "https://pinny-family-4vea.web.app/privacy") {
                    Link("Privacy Policy", destination: privacyURL)
                }
                if let supportURL = URL(string: "https://pinny-family-4vea.web.app/support") {
                    Link("Support", destination: supportURL)
                }
            }

            Section {
                Button(role: .destructive) {
                    showSignOutDialog = true
                } label: {
                    Text("Sign out")
                        .foregroundColor(Color.fm.sosRedText)
                }
                Button(role: .destructive) {
                    deleteFlow.begin()
                } label: {
                    Text("Delete account")
                        .foregroundColor(Color.fm.sosRedText)
                }
            } header: {
                Text("Account")
            } footer: {
                Text(versionLabel)
                    .font(.caption2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, FMSpacing.lg)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            notifyOnCheckIn = appState.currentUser?.notifyOnCheckIn ?? true
        }
        .onChange(of: selectedPhoto) { item in
            if let item {
                changePhoto(item)
            }
        }
        .onChange(of: appState.currentUser?.notifyOnCheckIn) { stored in
            // Follow the user doc (e.g. changed on another phone), but never mid-save.
            if let stored, !isSavingNotify {
                notifyOnCheckIn = stored
            }
        }
        .alert("Display name", isPresented: $showNameAlert) {
            TextField("Name", text: $draftName)
                .textContentType(.name)
            Button("Save") { saveName() }
                // Rules count UTF-16 units (an emoji counts 2+).
                .disabled(trimmedDraft.isEmpty || trimmedDraft.utf16.count > 40)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown to your family on the map and in chat.")
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutDialog, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                appState.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your family and messages stay. Sign back in any time.")
        }
        .alert("Delete your account?", isPresented: Binding(
            get: { deleteFlow.isAlertPresented },
            set: { if !$0, deleteFlow.step == .confirm1 { deleteFlow.cancel() } }
        )) {
            Button("Cancel", role: .cancel) { deleteFlow.cancel() }
            Button("Continue", role: .destructive) { deleteFlow.acceptFirstConfirmation() }
        } message: {
            Text("This deletes your account, name, last location and removes you from your family. Messages you've sent stay in the family chat. This can't be undone.")
        }
        .sheet(isPresented: Binding(
            get: { deleteFlow.isSheetPresented },
            set: { if !$0 { deleteFlow.cancel() } }
        )) {
            DeleteAccountSheet(viewModel: deleteFlow)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(appState)
                .environmentObject(passService)
                .presentationDetents([.large])
        }
    }

    // MARK: - Profile photo (STAGE-8-CONTRACT §3)

    private var isUpdatingPhoto: Bool {
        photoService.state == .uploading
    }

    /// 80 pt avatar, centred; a spinner covers it while uploading or removing.
    private var profilePhotoRow: some View {
        HStack {
            Spacer()
            ZStack {
                AvatarView(name: currentName, photoURL: appState.currentUser?.photoURL, size: 80)
                if isUpdatingPhoto {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 80, height: 80)
            .accessibilityLabel(isUpdatingPhoto ? "Updating photo" : "Profile photo")
            Spacer()
        }
        .padding(.vertical, FMSpacing.sm)
        .listRowBackground(Color.clear)
    }

    /// Reads the picked image (the picker runs out of process, no permission prompt), uploads it,
    /// then clears the selection so the same photo can be picked again.
    private func changePhoto(_ item: PhotosPickerItem) {
        guard !isUpdatingPhoto else { return }
        errorMessage = nil
        Task { @MainActor in
            defer { selectedPhoto = nil }
            let data: Data?
            do {
                data = try await item.loadTransferable(type: Data.self)
            } catch {
                data = nil
            }
            guard let data else {
                errorMessage = AppError.photoUpdateFailed
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            await photoService.upload(imageData: data)
            finishPhotoUpdate()
        }
    }

    private func removePhoto() {
        guard !isUpdatingPhoto else { return }
        errorMessage = nil
        Task { @MainActor in
            await photoService.remove()
            finishPhotoUpdate()
        }
    }

    /// Success haptic, or the banner + error haptic; the users/{uid} listener updates the avatar itself.
    private func finishPhotoUpdate() {
        if case .failed(let message) = photoService.state {
            errorMessage = message
            photoService.reset()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: - Family Pass (STAGE-7-CONTRACT §4)

    private var hasPass: Bool {
        appState.currentUser?.hasPass ?? false
    }

    /// Status row (tap → paywall; "You're all set" when active) and Restore, always available.
    private var familyPassSection: some View {
        Section {
            Button {
                showPaywall = true
            } label: {
                HStack {
                    Text("Family Pass")
                        .foregroundColor(Color.fm.textPrimary)
                    Spacer()
                    Text(hasPass ? "Active" : "Not purchased")
                        .foregroundColor(hasPass ? Color.fm.accent : Color.fm.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                }
            }
            .accessibilityLabel("Family Pass, \(hasPass ? "active" : "not purchased")")
            Button {
                restorePurchases()
            } label: {
                HStack {
                    Text("Restore purchases")
                        .foregroundColor(Color.fm.accent)
                    if isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRestoring)
        } header: {
            Text("Family Pass")
        } footer: {
            Text(hasPass
                 ? "One purchase unlocks one family. Tied to your Apple ID."
                 : "Needed only to create a family. Joining with a code is free.")
        }
    }

    private func restorePurchases() {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        Task { @MainActor in
            defer { isRestoring = false }
            await passService.restore()
            if case .failed(let message) = passService.state {
                errorMessage = message
                passService.reset()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Pinny \(version) (\(build))"
    }

    // MARK: - Notifications (DESIGN-SPEC §13.2)

    /// Rows follow the system permission, re-read on every return to the foreground (MainTabView).
    @ViewBuilder
    private func notificationsSection(_ status: UNAuthorizationStatus) -> some View {
        if status.allowsAlerts {
            Section {
                Toggle(isOn: Binding(
                    get: { notifyOnCheckIn },
                    set: { setNotifyOnCheckIn($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check-in alerts")
                        Text("When someone opens Pinny or checks in.")
                            .font(.footnote)
                            .foregroundColor(Color.fm.textSecondary)
                    }
                }
                .disabled(isSavingNotify)
                // Shown only while notifications are allowed: "always on" would be untrue otherwise.
                HStack {
                    Text("SOS alerts")
                    Spacer()
                    Text("Always on")
                        .foregroundColor(Color.fm.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Notifications")
            } footer: {
                Text("SOS alerts can't be turned off — that's the point.")
            }
        } else if status == .denied {
            Section {
                HStack {
                    Text("Notifications are off")
                    Spacer()
                    Button("Open Settings") {
                        openNotificationSettings()
                    }
                    .frame(minHeight: FMSize.minTapTarget)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Turn them on so you don't miss an SOS.")
            }
        } else {
            Section {
                Button {
                    requestNotifications()
                } label: {
                    HStack {
                        Text("Turn on notifications")
                            .foregroundColor(Color.fm.accent)
                        if isRequestingNotifications {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRequestingNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Get check-in and SOS alerts from your family.")
            }
        }
    }

    /// Saves at once. Offline (checked first) or a failed / timed-out write flips the toggle back to
    /// the user doc's value (the write is a transaction, so nothing is left queued to land later).
    private func setNotifyOnCheckIn(_ enabled: Bool) {
        guard enabled != notifyOnCheckIn, !isSavingNotify else { return }
        errorMessage = nil
        notifyOnCheckIn = enabled
        guard appState.locationSync.isOnline else {
            notifyOnCheckIn = !enabled
            errorMessage = AppError.offline
            return
        }
        isSavingNotify = true
        Task { @MainActor in
            defer { isSavingNotify = false }
            do {
                try await appState.setNotifyOnCheckIn(enabled)
            } catch {
                // The listener's value, not a guess: it is what the server has.
                notifyOnCheckIn = appState.currentUser?.notifyOnCheckIn ?? !enabled
                errorMessage = FamilyError.from(error) == .network ? AppError.offline : "Couldn't save. Try again."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func requestNotifications() {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        Task { @MainActor in
            await appState.requestNotificationPermission()
            isRequestingNotifications = false
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func saveName() {
        let name = trimmedDraft.clamped(toUTF16: 40)
        guard !name.isEmpty, name != currentName else { return }
        isSavingName = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSavingName = false }
            do {
                try await appState.updateName(name)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
