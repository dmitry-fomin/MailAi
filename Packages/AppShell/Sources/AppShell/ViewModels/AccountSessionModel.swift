import Foundation
import Core

/// Состояние одного окна-аккаунта. Держит выбранную папку, список писем
/// выбранной папки и открытое письмо. Полное тело — только в памяти, пока
/// письмо открыто (см. CLAUDE.md / CONSTITUTION.md).
@MainActor
public final class AccountSessionModel: ObservableObject {
    public let account: Account
    public let provider: any AccountDataProvider
    public let selectionPersistence: any SelectionPersistence

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

    private var messagesTask: Task<Void, Never>?
    private var bodyTask: Task<Void, Never>?

    public init(
        account: Account,
        provider: any AccountDataProvider,
        selectionPersistence: any SelectionPersistence = InMemorySelectionPersistence()
    ) {
        self.account = account
        self.provider = provider
        self.selectionPersistence = selectionPersistence
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
        openBody = nil
        messages = []
    }
}
