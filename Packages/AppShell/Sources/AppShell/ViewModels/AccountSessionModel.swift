import Foundation
import Core
import AI
import Network

/// Состояние одного окна-аккаунта. Держит выбранную папку, список писем
/// выбранной папки и открытое письмо. Полное тело — только в памяти, пока
/// письмо открыто (см. CLAUDE.md / CONSTITUTION.md).
@MainActor
public final class AccountSessionModel: ObservableObject {
    public let account: Account
    public let provider: any AccountDataProvider
    public let selectionPersistence: any SelectionPersistence
    public let searchService: (any SearchService)?
    /// AI-5: опциональный движок правил. Используется UI'ем (drag-to-rule)
    /// для создания правил на основе письма. Если `nil`, drag-to-rule
    /// показывает только информационное сообщение.
    public let ruleEngine: RuleEngine?
    /// AI-5: опциональная очередь классификации. Когда задана —
    /// `AccountWindowScene` рисует `ClassificationProgressBar`,
    /// привязанный к её снапшотам.
    public let classificationQueue: ClassificationQueue?

    @Published public private(set) var mailboxes: [Mailbox] = []
    @Published public var selectedMailboxID: Mailbox.ID? {
        didSet {
            // A8: персистим выбор папки сразу, чтобы при падении/relaunch
            // восстановить состояние.
            guard oldValue != selectedMailboxID else { return }
            selectionPersistence.setSelectedMailbox(selectedMailboxID, for: account.id)
        }
    }
    @Published public private(set) var messages: [Message] = []
    @Published public var selectedMessageID: Message.ID?
    @Published public private(set) var openBody: MessageBody?
    @Published public private(set) var isLoadingMailboxes: Bool = false
    @Published public private(set) var isLoadingMessages: Bool = false
    @Published public private(set) var lastError: MailError?
    @Published public private(set) var isOffline: Bool = false

    /// Строка в поисковом поле окна. Пустая строка — обычный режим
    /// (listMode == .mailbox). Непустая — подтягивается searchResults.
    @Published public var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            performSearch()
        }
    }
    @Published public private(set) var searchResults: [Message] = []
    @Published public private(set) var isSearching: Bool = false

    private var messagesTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var monitorTask: Task<Void, Never>?

    public init(
        account: Account,
        provider: any AccountDataProvider,
        selectionPersistence: any SelectionPersistence = InMemorySelectionPersistence(),
        searchService: (any SearchService)? = nil,
        ruleEngine: RuleEngine? = nil,
        classificationQueue: ClassificationQueue? = nil
    ) {
        self.account = account
        self.provider = provider
        self.selectionPersistence = selectionPersistence
        self.searchService = searchService
        self.ruleEngine = ruleEngine
        self.classificationQueue = classificationQueue
    }

    public func loadMailboxes() async {
        isLoadingMailboxes = true
        defer { isLoadingMailboxes = false }
        do {
            let list = try await provider.mailboxes()
            mailboxes = list
            if selectedMailboxID == nil {
                // A8: предпочитаем сохранённый выбор, иначе — INBOX/первый.
                let restored = selectionPersistence.selectedMailbox(for: account.id)
                if let id = restored, list.contains(where: { $0.id == id }) {
                    selectedMailboxID = id
                } else {
                    selectedMailboxID = list.first(where: { $0.role == .inbox })?.id ?? list.first?.id
                }
            }
            if let mailbox = selectedMailboxID { await loadMessages(for: mailbox) }
        } catch let err as MailError {
            lastError = err
        } catch {
            lastError = .network(.unknown)
        }
    }

    public func loadMessages(for mailboxID: Mailbox.ID, pageLimit: Int = 200) async {
        messagesTask?.cancel()
        isLoadingMessages = true
        messages = []
        let provider = self.provider
        let task = Task { [weak self] in
            var accumulated: [Message] = []
            do {
                for try await page in provider.messages(in: mailboxID, page: .init(offset: 0, limit: pageLimit)) {
                    accumulated.append(contentsOf: page)
                    let snapshot = accumulated
                    await MainActor.run { [weak self] in
                        self?.messages = snapshot
                    }
                    if Task.isCancelled { return }
                }
            } catch let err as MailError {
                await MainActor.run { [weak self] in self?.lastError = err }
            } catch {
                await MainActor.run { [weak self] in self?.lastError = .network(.unknown) }
            }
            await MainActor.run { [weak self] in self?.isLoadingMessages = false }
        }
        messagesTask = task
    }

    /// Открывает письмо: подписывается на стрим тела, собирает в память,
    /// публикует как `openBody`. При закрытии письма — тело уходит в nil.
    public func open(messageID: Message.ID?) {
        bodyTask?.cancel()
        openBody = nil
        guard let id = messageID else { return }
        let provider = self.provider
        bodyTask = Task { [weak self] in
            var bytes: [UInt8] = []
            do {
                for try await chunk in provider.body(for: id) {
                    bytes.append(contentsOf: chunk.bytes)
                    if Task.isCancelled { return }
                }
            } catch {
                await MainActor.run { [weak self] in self?.lastError = .network(.unknown) }
                return
            }
            let text = String(bytes: bytes, encoding: .utf8) ?? ""
            let body = MessageBody(messageID: id, content: .plain(text))
            await MainActor.run { [weak self] in
                self?.openBody = body
            }
        }
    }

    /// Освобождает открытое тело и отменяет фоновые таски — инвариант
    /// «тело живёт только пока письмо открыто».
    public func closeSession() {
        messagesTask?.cancel()
        bodyTask?.cancel()
        searchTask?.cancel()
        openBody = nil
        messages = []
        searchResults = []
    }

    /// Debounced-поиск (200 мс) через `searchService`. Игнорирует пустой
    /// запрос — тогда UI возвращается к обычному списку папки.
    private func performSearch() {
        searchTask?.cancel()
        let raw = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        guard let service = searchService else {
            return
        }
        let accountID = account.id
        let mailboxID = selectedMailboxID
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let hits = try await service.search(
                    rawQuery: raw,
                    accountID: accountID,
                    mailboxID: mailboxID,
                    limit: 200
                )
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.searchResults = hits
                    self?.isSearching = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isSearching = false
                }
            }
        }
    }

    // MARK: - Mail-3: действия из ReaderToolbar

    /// Возвращает true, если provider поддерживает server-side действия
    /// (LiveAccountDataProvider). Mock-провайдер их не реализует — UI
    /// рисует кнопки, но клик no-op.
    public var supportsActions: Bool {
        provider is any MailActionsProvider
    }

    public enum MailAction: Sendable, Equatable {
        case delete
        case archive
        case toggleRead
        case toggleFlag
        case moveToMailbox(Mailbox.ID)
    }

    /// Выполняет действие над текущим открытым письмом (`selectedMessageID`).
    /// Обновляет локальные `messages`/`openBody` и ошибки кладёт в `lastError`.
    public func perform(_ action: MailAction) async {
        guard let actions = provider as? any MailActionsProvider else { return }
        guard let messageID = selectedMessageID,
              let current = messages.first(where: { $0.id == messageID }) else {
            return
        }
        do {
            switch action {
            case .delete:
                try await actions.delete(messageID: messageID)
                removeFromList(messageID: messageID)
                openBody = nil
                bodyTask?.cancel()
            case .archive:
                try await actions.archive(messageID: messageID)
                removeFromList(messageID: messageID)
                openBody = nil
                bodyTask?.cancel()
            case .toggleRead:
                let desired = !current.flags.contains(.seen)
                try await actions.setRead(desired, messageID: messageID)
                updateFlags(messageID: messageID) { flags in
                    if desired { flags.insert(.seen) } else { flags.remove(.seen) }
                }
            case .toggleFlag:
                let desired = !current.flags.contains(.flagged)
                try await actions.setFlagged(desired, messageID: messageID)
                updateFlags(messageID: messageID) { flags in
                    if desired { flags.insert(.flagged) } else { flags.remove(.flagged) }
                }
            case .moveToMailbox(let targetID):
                try await actions.moveToMailbox(messageID: messageID, targetMailboxID: targetID)
                removeFromList(messageID: messageID)
                openBody = nil
                bodyTask?.cancel()
            }
        } catch let err as MailError {
            lastError = err
        } catch {
            lastError = .network(.unknown)
        }
    }

    private func removeFromList(messageID: Message.ID) {
        messages.removeAll(where: { $0.id == messageID })
        if selectedMessageID == messageID {
            selectedMessageID = messages.first?.id
        }
    }

    // MARK: - MailAi-791: Network Monitoring

    public func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitorTask = Task { [weak self] in
            let stream = AsyncStream<NWPath> { continuation in
                monitor.pathUpdateHandler = { continuation.yield($0) }
                monitor.start(queue: DispatchQueue(label: "network.monitor"))
            }
            for await path in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let wasOffline = self.isOffline
                    self.isOffline = path.status != .satisfied
                    if wasOffline && !self.isOffline {
                        if let id = self.selectedMailboxID {
                            Task { await self.loadMessages(for: id) }
                        }
                    }
                }
            }
        }
    }

    public func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        monitorTask?.cancel()
        pathMonitor = nil
        monitorTask = nil
    }

    private func updateFlags(messageID: Message.ID, mutate: (inout MessageFlags) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let original = messages[index]
        var flags = original.flags
        mutate(&flags)
        messages[index] = Message(
            id: original.id,
            accountID: original.accountID,
            mailboxID: original.mailboxID,
            uid: original.uid,
            messageID: original.messageID,
            threadID: original.threadID,
            subject: original.subject,
            from: original.from,
            to: original.to,
            cc: original.cc,
            date: original.date,
            preview: original.preview,
            size: original.size,
            flags: flags,
            importance: original.importance
        )
    }
}
