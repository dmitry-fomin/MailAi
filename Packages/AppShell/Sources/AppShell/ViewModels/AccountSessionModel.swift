import Foundation
import Core
import AI
import Network
import Storage

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
    /// MailAi-nmo4: опциональный координатор фоновой синхронизации.
    /// Когда задан — `AccountWindowScene` показывает индикатор синхронизации в тулбаре.
    public let syncCoordinator: BackgroundSyncCoordinator?
    /// MailAi-d0bz: опциональная офлайн-очередь действий. Когда задана —
    /// действия ставятся в очередь при отсутствии соединения и применяются при
    /// восстановлении. Conflict resolution: последнее действие выигрывает.
    public let offlineActionQueue: OfflineActionQueue?

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
    /// БАГ-5: хранит последний Task восстановления соединения, чтобы отменять
    /// предыдущий при быстром мигании сети (race condition).
    private var networkRecoveryTask: Task<Void, Never>?

    public init(
        account: Account,
        provider: any AccountDataProvider,
        selectionPersistence: any SelectionPersistence = InMemorySelectionPersistence(),
        searchService: (any SearchService)? = nil,
        ruleEngine: RuleEngine? = nil,
        classificationQueue: ClassificationQueue? = nil,
        syncCoordinator: BackgroundSyncCoordinator? = nil,
        offlineActionQueue: OfflineActionQueue? = nil
    ) {
        self.account = account
        self.provider = provider
        self.selectionPersistence = selectionPersistence
        self.searchService = searchService
        self.ruleEngine = ruleEngine
        self.classificationQueue = classificationQueue
        self.syncCoordinator = syncCoordinator
        self.offlineActionQueue = offlineActionQueue
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
        // БАГ-1: isLoadingMessages сбрасывается через withTaskCancellationHandler,
        // чтобы вечный спиннер не оставался при отмене Task.
        let task = Task { [weak self] in
            await withTaskCancellationHandler {
                var accumulated: [Message] = []
                do {
                    for try await page in provider.messages(in: mailboxID, page: .init(offset: 0, limit: pageLimit)) {
                        accumulated.append(contentsOf: page)
                        let snapshot = accumulated
                        await MainActor.run { [weak self] in
                            self?.messages = snapshot
                        }
                        if Task.isCancelled { break }
                    }
                } catch let err as MailError {
                    await MainActor.run { [weak self] in self?.lastError = err }
                } catch {
                    await MainActor.run { [weak self] in self?.lastError = .network(.unknown) }
                }
                await MainActor.run { [weak self] in self?.isLoadingMessages = false }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.isLoadingMessages = false }
            }
        }
        messagesTask = task
    }

    /// Открывает письмо: стримит MIME-тело, парсит структуру (plain/html/вложения),
    /// авто-помечает прочитанным. Тело живёт только в памяти пока письмо открыто.
    public func open(messageID: Message.ID?) {
        bodyTask?.cancel()
        bodyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.openBody = nil
            guard let id = messageID else { return }
            let provider = self.provider
            var bytes: [UInt8] = []
            do {
                for try await chunk in provider.body(for: id) {
                    bytes.append(contentsOf: chunk.bytes)
                    if Task.isCancelled { return }
                }
            } catch {
                self.lastError = .network(.unknown)
                return
            }
            self.openBody = MIMEBodyParser.parse(bytes: bytes, messageID: id)

            // Авто-пометка прочитанным при открытии письма
            if let actions = provider as? any MailActionsProvider,
               let msg = self.messages.first(where: { $0.id == id }),
               !msg.flags.contains(.seen) {
                try? await actions.setRead(true, messageID: id)
                self.updateFlags(messageID: id) { $0.insert(.seen) }
            }
        }
    }

    /// Загружает байты конкретного MIME-вложения. Данные не кешируются.
    public func downloadAttachment(_ attachment: Attachment) async throws -> Data {
        return try await provider.attachmentBytes(for: attachment, messageID: attachment.messageID)
    }

    /// Освобождает открытое тело и отменяет фоновые таски — инвариант
    /// «тело живёт только пока письмо открыто».
    public func closeSession() {
        messagesTask?.cancel()
        bodyTask?.cancel()
        searchTask?.cancel()
        networkRecoveryTask?.cancel()
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

    // MARK: - MailAi-spo9: Archive

    /// Архивирует несколько писем (batch-вариант).
    ///
    /// Перемещает письма в папку Archive из `mailboxes`. Используется из
    /// `BatchActionController` и по keyboard shortcut `E` (как в Apple Mail).
    /// Одиночное архивирование — через `perform(.archive)`.
    public func archive(messageIDs: [Message.ID]) async {
        guard let actions = provider as? any MailActionsProvider else { return }
        guard !messageIDs.isEmpty else { return }

        do {
            for id in messageIDs {
                if Task.isCancelled { break }
                try await actions.archive(messageID: id)
                removeFromList(messageID: id)
            }
        } catch let err as MailError {
            lastError = err
        } catch {
            lastError = .network(.unknown)
        }
    }

    // MARK: - MailAi-9fi0: Trash Restore

    /// Восстанавливает письма из Trash обратно в указанную папку.
    ///
    /// Вызывает `MailActionsProvider.restore(messageIDs:to:)`, затем
    /// убирает письма из текущего списка (так как мы находимся в Trash)
    /// и обновляет `lastError` при ошибке.
    ///
    /// - Parameters:
    ///   - messageIDs: Идентификаторы писем для восстановления.
    ///   - targetMailboxID: Папка назначения. Если `nil` — используется Inbox.
    public func restore(
        messageIDs: [Message.ID],
        to targetMailboxID: Mailbox.ID? = nil
    ) async {
        guard let actions = provider as? any MailActionsProvider else { return }
        guard !messageIDs.isEmpty else { return }

        let destination: Mailbox.ID
        if let target = targetMailboxID {
            destination = target
        } else if let inbox = mailboxes.first(where: { $0.role == .inbox }) {
            destination = inbox.id
        } else {
            lastError = .network(.unknown)
            return
        }

        do {
            try await actions.restore(messageIDs: messageIDs, to: destination)
            for id in messageIDs {
                removeFromList(messageID: id)
            }
        } catch let err as MailError {
            lastError = err
        } catch {
            lastError = .network(.unknown)
        }
    }

    /// Возвращает `true`, если текущая папка — Trash.
    public var isInTrash: Bool {
        guard let selectedID = selectedMailboxID else { return false }
        return mailboxes.first(where: { $0.id == selectedID })?.role == .trash
    }

    // MARK: - Internal helpers for BatchActionController

    /// Публичный вариант `removeFromList` — используется `BatchActionController`
    /// для обновления локального списка после batch-операций.
    public func removeFromListPublic(messageID: Message.ID) {
        removeFromList(messageID: messageID)
    }

    /// Публичный вариант `updateFlags` — используется `BatchActionController`
    /// для оптимистичного обновления флагов после batch-операций.
    public func updateFlagsPublic(messageID: Message.ID, mutate: (inout MessageFlags) -> Void) {
        updateFlags(messageID: messageID, mutate: mutate)
    }

    // MARK: - MailAi-791: Network Monitoring

    public func startNetworkMonitoring() {
        // БАГ-2: останавливаем предыдущий монитор перед созданием нового.
        pathMonitor?.cancel()
        monitorTask?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitorTask = Task { [weak self] in
            let stream = AsyncStream<NWPath> { continuation in
                monitor.pathUpdateHandler = { continuation.yield($0) }
                monitor.start(queue: DispatchQueue(label: "network.monitor"))
                // БАГ-2: останавливаем NWPathMonitor при завершении стрима.
                continuation.onTermination = { _ in monitor.cancel() }
            }
            for await path in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let wasOffline = self.isOffline
                    self.isOffline = path.status != .satisfied
                    if wasOffline && !self.isOffline {
                        if let id = self.selectedMailboxID {
                            // БАГ-5: отменяем предыдущий Task восстановления,
                            // чтобы быстрое мигание сети не создавало конкурирующих Task.
                            self.networkRecoveryTask?.cancel()
                            self.networkRecoveryTask = Task {
                                // MailAi-d0bz: применяем накопленные офлайн-действия
                                // перед перезагрузкой писем.
                                await self.applyOfflineQueue()
                                await self.loadMessages(for: id)
                            }
                        }
                    }
                }
            }
        }
    }

    public func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        monitorTask?.cancel()
        networkRecoveryTask?.cancel()
        pathMonitor = nil
        monitorTask = nil
        networkRecoveryTask = nil
    }

    // MARK: - MailAi-d0bz: Offline Queue

    /// Применяет накопленные офлайн-действия при восстановлении соединения.
    /// Вызывается из `networkRecoveryTask` сразу после появления сети.
    private func applyOfflineQueue() async {
        guard let queue = offlineActionQueue,
              let actions = provider as? any MailActionsProvider else { return }
        let accountID = account.id
        await queue.applyPending(for: accountID, actions: actions)
    }

    /// Ставит действие в офлайн-очередь (используется из `perform` и batch API
    /// когда `isOffline == true` и `offlineActionQueue` задана).
    public func enqueueOffline(
        messageID: Message.ID,
        action: OfflineActionType,
        payload: [String: String] = [:]
    ) {
        guard let queue = offlineActionQueue else { return }
        let accountID = account.id
        Task {
            try? await queue.enqueue(
                messageID: messageID,
                accountID: accountID,
                action: action,
                payload: payload
            )
        }
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
