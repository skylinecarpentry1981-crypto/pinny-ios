import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var deleteFlow = DeleteAccountViewModel()
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
                Button {
                    draftName = currentName
                    showNameAlert = true
                } label: {
                    HStack(spacing: FMSpacing.md) {
                        AvatarView(name: currentName, photoURL: appState.currentUser?.photoURL, size: 40)
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

            Section("Privacy") {
                Text("Your location and battery level are shared with your family only when you open Pinny, tap Refresh or Check in, or send an SOS. There is no background tracking. Delete your account at any time to remove your account and location data.")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
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
