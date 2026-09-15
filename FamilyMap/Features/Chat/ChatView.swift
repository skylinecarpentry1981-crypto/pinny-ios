import SwiftUI
import UIKit

/// The family thread (DESIGN-SPEC §13.4): newest at the bottom, input bar in the bottom safe area.
struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var inputFocused: Bool

    /// Drives "Just now" / "12 min ago" and the day labels (§8 60 s timer).
    @State private var now = Date()
    @State private var listWidth: CGFloat = 0
    /// Global y of the bottom of the messages and of the top of the input bar.
    @State private var contentBottom: CGFloat = 0
    @State private var inputBarTop: CGFloat = 0
    @State private var isNearBottom = true
    @State private var showNewMessages = false

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let bottomId = "chat-bottom"
    /// §13.4: a new message scrolls into view only within this distance of the bottom.
    private static let nearBottomDistance: CGFloat = 80

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                banner
                content(proxy)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar(proxy)
            }
            .onChange(of: viewModel.lastMessageId) { _ in
                handleNewLastMessage(proxy)
            }
            .onChange(of: inputFocused) { focused in
                // Keep the last message visible above the keyboard.
                guard focused, isNearBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
        .navigationTitle(appState.family?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isOnline)
        .onAppear {
            now = Date()
            startListening()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: appState.currentUser?.familyId) { _ in
            startListening()
        }
        .onChange(of: viewModel.draft) { text in
            viewModel.clampDraft(text)
        }
        .onReceive(minuteTimer) { date in
            now = date
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                now = Date()
            }
        }
    }

    private func startListening() {
        viewModel.start(
            familyId: appState.currentUser?.familyId,
            myUid: appState.currentUser?.id,
            chatService: appState.chatService
        )
    }

    // MARK: - Banner and states

    @ViewBuilder
    private var banner: some View {
        if !viewModel.isOnline {
            ErrorBanner(message: AppError.offline)
                .padding(.horizontal, FMSpacing.lg)
                .padding(.top, FMSpacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let errorMessage = viewModel.errorMessage {
            ErrorBanner(message: errorMessage)
                .padding(.horizontal, FMSpacing.lg)
                .padding(.top, FMSpacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
        if !viewModel.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.rows.isEmpty {
            ChatEmptyState()
        } else {
            messageList(proxy)
        }
    }

    // MARK: - Messages

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        let members = membersById
        return ScrollView {
            VStack(spacing: 0) {
                if viewModel.hasEarlier {
                    loadEarlierRow(proxy)
                }
                ForEach(viewModel.rows) { row in
                    rowView(row, members: members)
                        .id(row.id)
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomId)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ChatContentBottomKey.self, value: geo.frame(in: .global).minY)
                        }
                    )
            }
            .padding(.horizontal, FMSpacing.lg)
            .padding(.bottom, FMSpacing.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { listWidth = geo.size.width }
                    .onChange(of: geo.size.width) { width in listWidth = width }
            }
        )
        .onPreferenceChange(ChatContentBottomKey.self) { value in
            contentBottom = value
            updateNearBottom()
        }
        .onAppear {
            // Opens at the bottom.
            DispatchQueue.main.async {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatViewModel.Row, members: [String: AppUser]) -> some View {
        switch row {
        case .day(let date):
            DaySeparator(title: ChatTime.day(date, now: now))
        case .sos(let message, let isMine):
            SOSMessageCard(
                name: isMine ? "You" : message.senderName,
                isMine: isMine,
                time: ChatTime.clock(message.createdAt),
                canShowOnMap: members[message.senderId]?.lastLocation != nil,
                onShowOnMap: { showOnMap(message.senderId) }
            )
        case .bubble(let bubble):
            MessageBubble(
                bubble: bubble,
                avatar: bubble.isMine ? nil : avatar(for: bubble.message, members: members),
                time: ChatTime.label(for: bubble.message.createdAt, now: now),
                maxBubbleWidth: listWidth > 0 ? (listWidth - 2 * FMSpacing.lg) * 0.75 : 280,
                onRetry: { viewModel.retry(bubble.message.id) },
                onDelete: { viewModel.delete(bubble.message.id) }
            )
        }
    }

    private func loadEarlierRow(_ proxy: ScrollViewProxy) -> some View {
        Button {
            loadEarlier(proxy)
        } label: {
            ZStack {
                Text("Load earlier")
                    .opacity(viewModel.isLoadingEarlier ? 0 : 1)
                if viewModel.isLoadingEarlier {
                    ProgressView()
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(Color.fm.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: FMSize.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingEarlier)
        .accessibilityLabel("Load earlier")
    }

    private var membersById: [String: AppUser] {
        var result: [String: AppUser] = [:]
        for member in appState.members {
            if let id = member.id {
                result[id] = member
            }
        }
        return result
    }

    /// Photo or initials from the members list; a sender who has left gets grey initials from `senderName`.
    private func avatar(for message: ChatMessage, members: [String: AppUser]) -> MessageBubble.Avatar {
        if let member = members[message.senderId] {
            return MessageBubble.Avatar(name: member.name, photoURL: member.photoURL, isFormerMember: false)
        }
        return MessageBubble.Avatar(name: message.senderName, photoURL: nil, isFormerMember: true)
    }

    /// Same hand-off as the Family tab: MapView centres on the member and expands their drawer row.
    private func showOnMap(_ memberId: String) {
        appState.focusMemberId = memberId
        appState.selectedTab = .map
    }

    // MARK: - Scrolling

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        showNewMessages = false
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    /// Mine or near the bottom: scroll. Otherwise: the "New messages" capsule.
    private func handleNewLastMessage(_ proxy: ScrollViewProxy) {
        guard viewModel.lastMessageId != nil else { return }
        if viewModel.lastMessageIsMine || isNearBottom {
            DispatchQueue.main.async {
                scrollToBottom(proxy, animated: true)
            }
        } else {
            showNewMessages = true
        }
    }

    private func updateNearBottom() {
        // Before the input bar is measured, assume the bottom.
        let near = inputBarTop <= 0 || contentBottom - inputBarTop <= Self.nearBottomDistance
        if near != isNearBottom {
            isNearBottom = near
        }
        if near && showNewMessages {
            showNewMessages = false
        }
    }

    /// Keeps the first message that was on screen at the top, so the list doesn't jump.
    private func loadEarlier(_ proxy: ScrollViewProxy) {
        let anchorId = viewModel.rows.first { row in
            if case .day = row { return false }
            return true
        }?.id
        Task { @MainActor in
            await viewModel.loadEarlier()
            if let anchorId {
                proxy.scrollTo(anchorId, anchor: .top)
            }
        }
    }

    // MARK: - Input

    private func inputBar(_ proxy: ScrollViewProxy) -> some View {
        let length = ChatLimits.length(viewModel.draft)
        return HStack(alignment: .bottom, spacing: FMSpacing.sm) {
            TextField("Message", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .focused($inputFocused)
                .padding(.horizontal, FMSpacing.md)
                .padding(.vertical, FMSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.fm.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
                .accessibilityLabel("Message")

            VStack(spacing: 2) {
                if length >= ChatLimits.counterThreshold {
                    Text("\(length)/\(ChatLimits.maxLength)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(length >= ChatLimits.maxLength ? Color.fm.sosRedText : Color.fm.textSecondary)
                        .accessibilityLabel("\(length) of \(ChatLimits.maxLength) characters")
                }
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    viewModel.send(sender: appState.currentUser)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(viewModel.canSend ? Color.fm.accent : Color(uiColor: .tertiaryLabel))
                        .frame(width: FMSize.minTapTarget, height: FMSize.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.sm)
        .background(.bar)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ChatInputBarTopKey.self, value: geo.frame(in: .global).minY)
            }
        )
        .onPreferenceChange(ChatInputBarTopKey.self) { value in
            inputBarTop = value
            updateNearBottom()
        }
        .overlay(alignment: .top) {
            if showNewMessages {
                newMessagesCapsule(proxy)
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + FMSpacing.sm }
                    .transition(.opacity)
            }
        }
    }

    private func newMessagesCapsule(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy, animated: true)
        } label: {
            Label("New messages", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color.fm.onAccent)
                .padding(.horizontal, FMSpacing.lg)
                .frame(minHeight: FMSize.minTapTarget)
                .background(Capsule().fill(Color.fm.accent))
        }
        .buttonStyle(.plain)
    }
}

/// §13.4 empty state; the input bar stays ready below it.
private struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: FMSpacing.md) {
            Image("PinnyMascot")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 72)
                .accessibilityHidden(true)
            Text("Say hi to your family")
                .font(.title3.weight(.semibold))
                .foregroundColor(Color.fm.textPrimary)
                .multilineTextAlignment(.center)
            Text("Everyone in your family sees messages here.")
                .font(.body)
                .foregroundColor(Color.fm.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 280)
        .padding(FMSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatInputBarTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
