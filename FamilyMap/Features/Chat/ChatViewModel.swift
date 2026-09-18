import Foundation
import Network
import UIKit

/// The family thread (DESIGN-SPEC §13.4): live window + earlier pages + my unsent messages,
/// turned into rows (day separators, grouped bubbles, SOS cards).
@MainActor
final class ChatViewModel: ObservableObject {
    enum Delivery: Equatable {
        case sent
        /// Write in flight: 60 % opacity, "Sending…".
        case sending
        /// Offline, rejected or 10 s timeout: "Not sent. Tap to retry."
        case failed
    }

    struct Bubble: Equatable {
        let message: ChatMessage
        let delivery: Delivery
        let isMine: Bool
        let isFirstInGroup: Bool
        let isLastInGroup: Bool
    }

    enum Row: Identifiable, Equatable {
        case day(Date)
        case sos(ChatMessage, isMine: Bool)
        case bubble(Bubble)

        var id: String {
            switch self {
            case .day(let date): return "day-\(Int(date.timeIntervalSince1970))"
            case .sos(let message, _): return message.id
            case .bubble(let bubble): return bubble.message.id
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    /// False until the first snapshot (or error): the list shows a centred spinner.
    @Published private(set) var hasLoaded = false
    /// Shows the "Load earlier" row.
    @Published private(set) var hasEarlier = false
    @Published private(set) var isLoadingEarlier = false
    @Published private(set) var isOnline = true
    /// Listener or "Load earlier" failure, already mapped through `error.userMessage`.
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastMessageId: String?
    @Published private(set) var lastMessageIsMine = false
    @Published var draft = ""

    private static let sendTimeoutNanoseconds: UInt64 = 10_000_000_000
    /// Consecutive messages from one sender within this gap share a group.
    private static let groupGap: TimeInterval = 5 * 60

    private struct Outgoing {
        var message: ChatMessage
        let sender: AppUser
        var failed: Bool
    }

    private var familyId: String?
    private var myUid: String?
    private var chatService: ChatService?
    private var cancelListener: ListenerCancel?
    private var pathMonitor: NWPathMonitor?

    /// The latest listener snapshot, oldest first.
    private var live: [ChatMessage] = []
    /// Earlier pages, plus messages that have scrolled out of the live window.
    private var older: [String: ChatMessage] = [:]
    /// My messages not yet confirmed by the server. Sends are transactions (never queued offline), so
    /// the listener shows no pending copy: these draw the Sending / Failed bubbles.
    private var outbox: [String: Outgoing] = [:]
    private var hasPaged = false
    private var listeningSince = Date()

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
        !trimmedDraft.isEmpty
    }

    // MARK: - Lifecycle

    func start(familyId: String?, myUid: String?, chatService: ChatService) {
        guard let familyId, let myUid else { return }
        if familyId != self.familyId || myUid != self.myUid {
            stop()
            reset()
        }
        self.familyId = familyId
        self.myUid = myUid
        self.chatService = chatService
        startPathMonitor()
        guard cancelListener == nil else { return }
        listeningSince = Date()
        cancelListener = chatService.observeRecentMessages(familyId: familyId) { [weak self] event in
            Task { @MainActor in
                self?.handle(event, familyId: familyId)
            }
        }
    }

    /// Sends already in flight keep going; their result shows when the tab is back.
    func stop() {
        cancelListener?()
        cancelListener = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func reset() {
        live = []
        older = [:]
        outbox = [:]
        hasPaged = false
        hasLoaded = false
        hasEarlier = false
        errorMessage = nil
        rows = []
        lastMessageId = nil
        lastMessageIsMine = false
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "FamilyMap.Chat.path"))
        pathMonitor = monitor
    }

    // MARK: - Snapshots

    private func handle(_ event: ChatFeedEvent, familyId: String) {
        guard familyId == self.familyId else { return }
        switch event {
        case .failure(let error):
            // Firestore ends a listener after an error; the next appear attaches a new one.
            cancelListener?()
            cancelListener = nil
            errorMessage = error.userMessage
            hasLoaded = true
        case .messages(let messages, let isFull):
            announceNewSOS(in: messages)
            acknowledgeNewSOS(in: messages, familyId: familyId)
            let newIds = Set(messages.map(\.id))
            let previousIds = Set(live.filter { !$0.isPending }.map(\.id))
            if isFull, !previousIds.isEmpty, previousIds.isDisjoint(with: newIds) {
                // The window jumped (e.g. 150 messages arrived while the tab was away): messages may be
                // missing between the old window and this one. Drop everything older so Load earlier
                // continues from this window's oldest message; no silent gap.
                older = [:]
                hasPaged = false
            } else {
                for message in live where !newIds.contains(message.id) && !message.isPending {
                    older[message.id] = message
                }
            }
            live = messages
            for message in messages where !message.isPending {
                outbox[message.id] = nil
            }
            if !hasPaged {
                hasEarlier = isFull
            }
            errorMessage = nil
            hasLoaded = true
            rebuild()
        }
    }

    /// §7: a new SOS card is announced on arrival. Only messages created after the listener started
    /// count, so the first load (or the server filling in a thin offline cache) announces nothing.
    private func announceNewSOS(in messages: [ChatMessage]) {
        let seen = Set(live.map(\.id))
        for message in messages where message.type == .sos && message.senderId != myUid {
            guard !seen.contains(message.id), message.createdAt > listeningSince else { continue }
            UIAccessibility.post(notification: .announcement, argument: "\(message.senderName) sent an SOS")
        }
    }

    /// Stage 9: an SOS from someone else that arrives while the thread is open is acknowledged, so
    /// the server stops repeating the alert to me. Only while the app is on screen.
    private func acknowledgeNewSOS(in messages: [ChatMessage], familyId: String) {
        guard let myUid, let chatService, UIApplication.shared.applicationState == .active else { return }
        let seen = Set(live.map(\.id))
        let now = Date()
        for message in messages where !seen.contains(message.id) && message.needsSOSAck(myUid: myUid, now: now) {
            let messageId = message.id
            Task {
                await chatService.acknowledgeSOS(familyId: familyId, messageId: messageId)
            }
        }
    }

    // MARK: - Sending

    /// Field clears and the bubble shows at once; the button never waits on the network.
    func send(sender: AppUser?) {
        let text = trimmedDraft
        guard !text.isEmpty, let sender, let familyId, let myUid, let chatService else { return }
        let id = chatService.newMessageId(familyId: familyId)
        let message = ChatMessage(
            id: id,
            senderId: myUid,
            senderName: ChatLimits.storedName(sender.name),
            text: ChatLimits.clamp(text),
            createdAt: Date(),
            isPending: true
        )
        outbox[id] = Outgoing(message: message, sender: sender, failed: false)
        draft = ""
        deliver(id)
    }

    func retry(_ id: String) {
        deliver(id)
    }

    /// Local only: the message was never sent. Sends are transactions, so nothing is left in
    /// Firestore's queue to land later.
    func delete(_ id: String) {
        outbox[id] = nil
        rebuild()
    }

    /// Typing stops at 1000 characters.
    func clampDraft(_ text: String) {
        let clamped = ChatLimits.clamp(text)
        if clamped != text {
            draft = clamped
        }
    }

    /// Offline goes straight to failed (nothing is queued). The ID is reused, so a retry can't post twice.
    private func deliver(_ id: String) {
        guard var item = outbox[id], let familyId, let chatService else { return }
        item.failed = false
        outbox[id] = item
        rebuild()
        guard isOnline else {
            markFailed(id)
            return
        }
        let text = item.message.text
        let sender = item.sender
        Task {
            do {
                try await withTimeout(
                    nanoseconds: Self.sendTimeoutNanoseconds,
                    timeoutError: ChatError.timedOut
                ) {
                    try await chatService.send(text: text, familyId: familyId, sender: sender, messageId: id)
                }
                self.markSent(id, familyId: familyId)
            } catch {
                self.markFailed(id)
            }
        }
    }

    private func markSent(_ id: String, familyId: String) {
        guard familyId == self.familyId, let item = outbox.removeValue(forKey: id) else { return }
        // Keep it on screen even if the listener is paused (another tab); the snapshot replaces it.
        if !live.contains(where: { $0.id == id && !$0.isPending }) {
            var sent = item.message
            sent.isPending = false
            older[id] = sent
        }
        rebuild()
    }

    private func markFailed(_ id: String) {
        guard outbox[id] != nil else { return }
        outbox[id]?.failed = true
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        rebuild()
    }

    // MARK: - Earlier pages

    /// Fetches the previous page once. The caller restores the scroll position.
    func loadEarlier() async {
        guard hasEarlier, !isLoadingEarlier, let familyId, let chatService else { return }
        let confirmed = (Array(older.values) + live).filter { !$0.isPending }
        guard let oldest = confirmed.min(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) else { return }
        guard isOnline else {
            // The offline banner is already showing.
            return
        }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let page = try await chatService.loadEarlier(familyId: familyId, before: oldest)
            guard familyId == self.familyId else { return }
            for message in page {
                older[message.id] = message
            }
            hasPaged = true
            hasEarlier = page.count >= ChatLimits.pageSize
            errorMessage = nil
            rebuild()
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: - Rows

    private func rebuild() {
        var byId = older
        for message in live {
            byId[message.id] = message
        }
        var deliveries: [String: Delivery] = [:]
        for (id, item) in outbox {
            if let known = byId[id], !known.isPending { continue }
            if byId[id] == nil {
                byId[id] = item.message
            }
            deliveries[id] = item.failed ? .failed : .sending
        }

        let messages = byId.values
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }

        let calendar = Calendar.current
        // continues[i]: message i joins the group of message i - 1.
        var continues = [Bool](repeating: false, count: messages.count)
        for index in messages.indices.dropFirst() {
            let previous = messages[index - 1]
            let current = messages[index]
            continues[index] = previous.type == .normal
                && current.type == .normal
                && previous.senderId == current.senderId
                && calendar.isDate(previous.createdAt, inSameDayAs: current.createdAt)
                && current.createdAt.timeIntervalSince(previous.createdAt) <= Self.groupGap
        }

        var result: [Row] = []
        var lastDay: Date?
        for (index, message) in messages.enumerated() {
            let day = calendar.startOfDay(for: message.createdAt)
            if day != lastDay {
                result.append(.day(day))
                lastDay = day
            }
            let isMine = message.senderId == myUid
            if message.type == .sos {
                result.append(.sos(message, isMine: isMine))
                continue
            }
            let isLast = index + 1 >= messages.count || !continues[index + 1]
            result.append(.bubble(Bubble(
                message: message,
                delivery: deliveries[message.id] ?? (message.isPending ? .sending : .sent),
                isMine: isMine,
                isFirstInGroup: !continues[index],
                isLastInGroup: isLast
            )))
        }

        rows = result
        lastMessageId = messages.last?.id
        lastMessageIsMine = messages.last?.senderId == myUid
    }
}
