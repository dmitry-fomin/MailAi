import Foundation
import Core
import Secrets

/// Провайдер данных для Exchange-аккаунта через EWS.
/// Реализует `AccountDataProvider` + `MailActionsProvider`.
public final class EWSAccountDataProvider: AccountDataProvider, MailActionsProvider, @unchecked Sendable {
    public let account: Account
    private let client: EWSClient
    /// Кеш EWS folder ID → Mailbox. Обновляется при каждом `mailboxes()`.
    private let folderCache = FolderCache()

    public init(account: Account, client: EWSClient) {
        self.account = account
        self.client = client
    }

    public static func make(
        account: Account,
        ewsURL: URL,
        secrets: any SecretsStore
    ) async throws -> EWSAccountDataProvider {
        guard let password = try await secrets.password(forAccount: account.id) else {
            throw MailError.keychain(.unknown)
        }
        let client = EWSClient(ewsURL: ewsURL, username: account.username, password: password)
        return EWSAccountDataProvider(account: account, client: client)
    }

    // MARK: - AccountDataProvider

    public func mailboxes() async throws -> [Mailbox] {
        // Получаем стандартные папки + дерево корневой папки
        let distinguished: [EWSDistinguishedFolderID] = [
            .inbox, .sentitems, .drafts, .deleteditems, .junkemail
        ]
        let folders = try await client.getFolders(ids: distinguished)
        var mailboxes = folders.map { makeMailbox(from: $0) }

        // Дочерние папки inbox — ищем именно Inbox по displayName (case-insensitive),
        // а не первую попавшуюся папку (порядок ответа от Exchange не гарантирован).
        let inboxFolder = folders.first(where: {
            Self.guessRole(displayName: $0.displayName) == .inbox
        }) ?? folders.first(where: { $0.displayName.lowercased() == "inbox" })
        var childFolders: [EWSFolder] = []
        if let inboxFolder {
            childFolders = (try? await client.findSubfolders(parentID: inboxFolder.id)) ?? []
            let childMailboxes = childFolders.map { makeMailbox(from: $0) }
            if !childMailboxes.isEmpty {
                // Добавляем как плоский список (UI рендерит без вложенности пока)
                mailboxes.append(contentsOf: childMailboxes)
            }
        }

        // Передаём все EWSFolder в кеш — маппинг происходит по folder.id, а не по позиции.
        let allEWSFolders = folders + childFolders
        await folderCache.update(from: mailboxes, ewsFolders: allEWSFolders)
        return mailboxes
    }

    public func messages(in mailboxID: Mailbox.ID, page: Page) -> AsyncThrowingStream<[Message], any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let ewsFolderID = await folderCache.ewsFolderID(for: mailboxID) else {
                        // Папка не найдена в кеше — fallback: mailboxID.rawValue как EWS ID
                        let result = try await self.client.findItems(
                            folderID: mailboxID.rawValue,
                            offset: page.offset,
                            maxCount: page.limit
                        )
                        await self.cacheItemRefs(result.items, in: mailboxID)
                        let msgs = result.items.map { self.makeMessage(from: $0, mailboxID: mailboxID) }
                        continuation.yield(msgs)
                        continuation.finish()
                        return
                    }
                    let result = try await self.client.findItems(
                        folderID: ewsFolderID,
                        offset: page.offset,
                        maxCount: page.limit
                    )
                    await self.cacheItemRefs(result.items, in: mailboxID)
                    let msgs = result.items.map { self.makeMessage(from: $0, mailboxID: mailboxID) }
                    continuation.yield(msgs)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func body(for messageID: Message.ID) -> AsyncThrowingStream<ByteChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
                        throw MailError.messageNotFound(messageID)
                    }
                    let mimeData = try await self.client.getItemMIME(itemID: ewsID, changeKey: ck)
                    // Стримим чанками по 64 КБ
                    let chunkSize = 65536
                    var offset = 0
                    let bytes = [UInt8](mimeData)
                    while offset < bytes.count {
                        let end = min(offset + chunkSize, bytes.count)
                        continuation.yield(ByteChunk(bytes: Array(bytes[offset..<end])))
                        offset = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func threads(in mailboxID: Mailbox.ID) async throws -> [MessageThread] {
        // EWS не имеет нативного threading API — возвращаем пустой список;
        // UI-уровень собирает треды по заголовкам (как для IMAP).
        return []
    }

    // MARK: - MailActionsProvider

    public func delete(messageID: Message.ID) async throws {
        guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
            throw MailError.messageNotFound(messageID)
        }
        try await client.deleteItem(itemID: ewsID, changeKey: ck, moveToDeletedItems: true)
        await folderCache.removeItem(messageID: messageID)
    }

    public func archive(messageID: Message.ID) async throws {
        guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
            throw MailError.messageNotFound(messageID)
        }
        // Архивируем в папку «Архив» (deleteditems — fallback если нет archivemsgfolderroot)
        var targetFolderID: String?
        if let archiveFolders = try? await client.getFolders(ids: [.archive]) {
            targetFolderID = archiveFolders.first?.id
        }
        if targetFolderID == nil {
            if let deletedFolders = try? await client.getFolders(ids: [.deleteditems]) {
                targetFolderID = deletedFolders.first?.id
            }
        }
        guard let targetFolderID else {
            throw MailError.mailboxNotFound(Mailbox.ID("archive"))
        }
        try await client.moveItem(itemID: ewsID, changeKey: ck, toFolderID: targetFolderID)
        await folderCache.removeItem(messageID: messageID)
    }

    public func setRead(_ read: Bool, messageID: Message.ID) async throws {
        guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
            throw MailError.messageNotFound(messageID)
        }
        try await client.setReadFlag(read, itemID: ewsID, changeKey: ck)
    }

    public func setFlagged(_ flagged: Bool, messageID: Message.ID) async throws {
        guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
            throw MailError.messageNotFound(messageID)
        }
        try await client.setFlaggedFlag(flagged, itemID: ewsID, changeKey: ck)
    }

    public func moveToMailbox(messageID: Message.ID, targetMailboxID: Mailbox.ID) async throws {
        guard let (ewsID, ck) = await folderCache.ewsItemRef(for: messageID) else {
            throw MailError.messageNotFound(messageID)
        }
        guard let targetFolderID = await folderCache.ewsFolderID(for: targetMailboxID) else {
            throw MailError.mailboxNotFound(targetMailboxID)
        }
        try await client.moveItem(itemID: ewsID, changeKey: ck, toFolderID: targetFolderID)
        await folderCache.removeItem(messageID: messageID)
    }

    // MARK: - Store item refs for body/actions

    func cacheItemRefs(_ items: [EWSItem], in mailboxID: Mailbox.ID) async {
        await folderCache.storeItems(items, mailboxID: mailboxID, accountID: account.id)
    }

    // MARK: - Mapping helpers

    private func makeMailbox(from folder: EWSFolder) -> Mailbox {
        let role = Self.guessRole(displayName: folder.displayName)
        let path = folder.displayName
        let id = Mailbox.ID(folder.id)
        return Mailbox(
            id: id,
            accountID: account.id,
            name: folder.displayName,
            path: path,
            role: role,
            unreadCount: folder.unreadCount,
            totalCount: folder.totalCount,
            uidValidity: nil
        )
    }

    private func makeMessage(from item: EWSItem, mailboxID: Mailbox.ID) -> Message {
        let flags = makeFlags(from: item)
        let importance = makeImportance(from: item.importance)
        // EWS не даёт uid (uint32) — используем хеш от EWS item ID
        let uid = UInt32(truncatingIfNeeded: abs(item.id.hashValue))
        let messageID = Message.ID(item.id)
        return Message(
            id: messageID,
            accountID: account.id,
            mailboxID: mailboxID,
            uid: uid,
            messageID: item.internetMessageID,
            threadID: nil,
            subject: item.subject,
            from: item.from.map { MailAddress(address: $0.address, name: $0.name) },
            to: item.toRecipients.map { MailAddress(address: $0.address, name: $0.name) },
            cc: item.ccRecipients.map { MailAddress(address: $0.address, name: $0.name) },
            date: item.dateReceived,
            preview: nil,
            size: item.size,
            flags: flags,
            importance: importance,
            listUnsubscribe: item.listUnsubscribeHeader,
            listUnsubscribePost: item.listUnsubscribePostHeader
        )
    }

    private func makeFlags(from item: EWSItem) -> MessageFlags {
        var flags: MessageFlags = []
        if item.isRead { flags.insert(.seen) }
        if item.hasAttachments { flags.insert(.hasAttachment) }
        return flags
    }

    private func makeImportance(from importance: String) -> Importance {
        // EWS importance (High/Normal/Low) maps to AI-driven Importance.
        // AI pack will re-score later; treat High as important, rest as unknown.
        switch importance.lowercased() {
        case "high": return .important
        default: return .unknown
        }
    }

    private static func guessRole(displayName: String) -> Mailbox.Role {
        switch displayName.lowercased() {
        case let s where s.contains("inbox") || s.contains("входящ"): return .inbox
        case let s where s.contains("sent") || s.contains("отправлен"): return .sent
        case let s where s.contains("draft") || s.contains("черновик"): return .drafts
        case let s where s.contains("deleted") || s.contains("удалён") || s.contains("корзина"): return .trash
        case let s where s.contains("junk") || s.contains("spam") || s.contains("спам"): return .spam
        case let s where s.contains("archive") || s.contains("архив"): return .archive
        default: return .custom
        }
    }
}

// MARK: - FolderCache (actor)

/// Потокобезопасный кеш: mailbox.id ↔ EWS folder ID, message.id ↔ (ewsItemID, changeKey).
private actor FolderCache {
    private var folderIDMap: [Mailbox.ID: String] = [:]   // Mailbox.ID → EWS folder id
    private var itemRefs: [Message.ID: (String, String)] = [:]  // Message.ID → (ewsItemID, changeKey)

    func update(from mailboxes: [Mailbox], ewsFolders: [EWSFolder]) {
        // Строим словарь EWS folder.id → EWSFolder для маппинга по ID, а не по позиции.
        // Mailbox.ID создаётся из folder.id (см. makeMailbox), поэтому ключ совпадает.
        let folderByID = Dictionary(uniqueKeysWithValues: ewsFolders.map { ($0.id, $0) })
        for mailbox in mailboxes {
            // Mailbox.ID.rawValue == EWSFolder.id (см. makeMailbox)
            if let folder = folderByID[mailbox.id.rawValue] {
                folderIDMap[mailbox.id] = folder.id
            }
        }
    }

    func ewsFolderID(for mailboxID: Mailbox.ID) -> String? {
        folderIDMap[mailboxID] ?? mailboxID.rawValue
    }

    func ewsItemRef(for messageID: Message.ID) -> (String, String)? {
        // Message.ID.rawValue — это сам EWS item ID, ChangeKey хранится отдельно
        return itemRefs[messageID]
    }

    func storeItems(_ items: [EWSItem], mailboxID: Mailbox.ID, accountID: Account.ID) {
        for item in items {
            let msgID = Message.ID(item.id)
            itemRefs[msgID] = (item.id, item.changeKey)
        }
    }

    func removeItem(messageID: Message.ID) {
        itemRefs.removeValue(forKey: messageID)
    }
}
