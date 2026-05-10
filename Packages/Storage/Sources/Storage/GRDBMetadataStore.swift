import Foundation
import GRDB
import Core

/// GRDB-реализация `MetadataStore`. Один `DatabasePool` на БД (один файл на
/// аккаунт). WAL включён, foreign keys включены. Тела писем не хранятся.
public actor GRDBMetadataStore: MetadataStore {
    /// Публикуется `nonisolated` — `DatabasePool` сам потокобезопасен (Sendable),
    /// а pool устанавливается единожды в init. Это позволяет внешним модулям
    /// (AI/RulesRepository) создавать свои actor'ы поверх той же БД без
    /// лишнего hop'а через актёра.
    public nonisolated let pool: DatabasePool

    public init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        self.pool = try DatabasePool(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        Schema.registerAll(&migrator)
        try migrator.migrate(self.pool)
    }

    // MARK: - MetadataStore

    public func upsert(_ messages: [Message]) async throws {
        try await pool.write { db in
            for chunk in messages.chunked(size: 500) {
                for msg in chunk {
                    try Self.upsertMessage(msg, into: db)
                }
            }
        }
    }

    public func messages(in mailbox: Mailbox.ID, page: Page) async throws -> [Message] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE mailbox_id = ?
                ORDER BY date DESC
                LIMIT ? OFFSET ?
                """,
                arguments: [mailbox.rawValue, page.limit, page.offset]
            )
            return try rows.map(Self.decodeMessage)
        }
    }

    public func delete(messageIDs: [Message.ID]) async throws {
        guard !messageIDs.isEmpty else { return }
        try await pool.write { db in
            // SQLite ограничивает число параметров до 999; разбиваем на чанки по 500.
            for chunk in messageIDs.chunked(size: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let args = StatementArguments(chunk.map { $0.rawValue })
                try db.execute(
                    sql: "DELETE FROM message WHERE id IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    // MARK: - Account / Mailbox / Thread — служебные методы для v1

    public func upsert(_ account: Account) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, email, display_name, kind, host, port, security, username)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    email = excluded.email,
                    display_name = excluded.display_name,
                    kind = excluded.kind,
                    host = excluded.host,
                    port = excluded.port,
                    security = excluded.security,
                    username = excluded.username
                """,
                arguments: [
                    account.id.rawValue, account.email, account.displayName,
                    account.kind.rawValue, account.host, Int(account.port),
                    account.security.rawValue, account.username
                ]
            )
        }
    }

    public func upsert(_ mailbox: Mailbox) async throws {
        try await pool.write { db in
            try Self.upsertMailbox(mailbox, parent: nil, into: db)
        }
    }

    public func upsert(_ thread: MessageThread) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO thread (id, account_id, subject, last_date)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    subject = excluded.subject,
                    last_date = excluded.last_date
                """,
                arguments: [
                    thread.id.rawValue, thread.accountID.rawValue,
                    thread.subject, thread.lastDate
                ]
            )
        }
    }

    public func account(id: Account.ID) async throws -> Account? {
        try await pool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT * FROM account WHERE id = ?",
                arguments: [id.rawValue]
            ).map(Self.decodeAccount)
        }
    }

    public func mailboxCount(accountID: Account.ID) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM mailbox WHERE account_id = ?",
                arguments: [accountID.rawValue]
            ) ?? 0
        }
    }

    public func message(id: Message.ID) async throws -> Message? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT * FROM message WHERE id = ?",
                arguments: [id.rawValue]
            ) else { return nil }
            return try Self.decodeMessage(row)
        }
    }

    public func updateImportance(messageID id: Message.ID, to importance: Importance) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE message SET importance = ? WHERE id = ?",
                arguments: [importance.rawValue, id.rawValue]
            )
        }
    }

    public func messageCount(in mailbox: Mailbox.ID) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM message WHERE mailbox_id = ?",
                arguments: [mailbox.rawValue]
            ) ?? 0
        }
    }

    /// Проверка инварианта: ни в одной таблице/колонке не сохранено тело письма.
    /// Используется тестом `privacyInvariants`.
    ///
    /// Таблица `signature` намеренно исключена: её колонка `body` содержит
    /// текст *подписи* пользователя (пользовательские настройки), а не тело письма —
    /// это допустимо по инварианту CLAUDE.md.
    public func hasAnyBodyColumn() async throws -> Bool {
        // Таблицы-исключения: их `body`-колонки — пользовательские настройки,
        // не тела писем.
        let excludedTables: Set<String> = ["signature"]

        return try await pool.read { db in
            let columns = try Row.fetchAll(db, sql: """
                SELECT m.name AS table_name, p.name AS column_name
                FROM sqlite_master m
                JOIN pragma_table_info(m.name) p
                WHERE m.type = 'table'
                """
            )
            for row in columns {
                let tableName = (row["table_name"] as String?) ?? ""
                guard !excludedTables.contains(tableName.lowercased()) else { continue }
                let col = (row["column_name"] as String?) ?? ""
                // ai_snippet — разрешённый AI-сниппет (≤150 символов), не тело письма.
                if ["body", "html", "text_body", "attachments_data"].contains(col.lowercased()) {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Private encode/decode

    private static func upsertMessage(_ msg: Message, into db: Database) throws {
        // Принудительно усекаем preview до 500 символов — инвариант "тела не на диск".
        let safePreview = msg.preview.map { String($0.prefix(500)) }
        let toJSON = try Self.encodeAddresses(msg.to)
        let ccJSON = try Self.encodeAddresses(msg.cc)
        try db.execute(sql: """
            INSERT INTO message
                (id, account_id, mailbox_id, uid, message_id, thread_id,
                 subject, from_address, from_name, to_json, cc_json,
                 date, preview, size, flags, importance)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mailbox_id = excluded.mailbox_id,
                uid = excluded.uid,
                message_id = excluded.message_id,
                thread_id = excluded.thread_id,
                subject = excluded.subject,
                from_address = excluded.from_address,
                from_name = excluded.from_name,
                to_json = excluded.to_json,
                cc_json = excluded.cc_json,
                date = excluded.date,
                preview = excluded.preview,
                size = excluded.size,
                flags = excluded.flags,
                importance = excluded.importance
            """,
            arguments: [
                msg.id.rawValue, msg.accountID.rawValue, msg.mailboxID.rawValue,
                Int(msg.uid), msg.messageID, msg.threadID?.rawValue,
                msg.subject, msg.from?.address, msg.from?.name,
                toJSON, ccJSON,
                msg.date, safePreview, msg.size,
                Int(msg.flags.rawValue),
                msg.importance.rawValue
            ]
        )
    }

    private static func upsertMailbox(_ mailbox: Mailbox, parent: Mailbox.ID?, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO mailbox
                (id, account_id, name, path, role, unread_count, total_count,
                 uid_validity, parent_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                path = excluded.path,
                role = excluded.role,
                unread_count = excluded.unread_count,
                total_count = excluded.total_count,
                uid_validity = excluded.uid_validity,
                parent_id = excluded.parent_id
            """,
            arguments: [
                mailbox.id.rawValue, mailbox.accountID.rawValue,
                mailbox.name, mailbox.path, mailbox.role.rawValue,
                mailbox.unreadCount, mailbox.totalCount,
                mailbox.uidValidity.map { Int($0) }, parent?.rawValue
            ]
        )
        for child in mailbox.children {
            try upsertMailbox(child, parent: mailbox.id, into: db)
        }
    }

    private static func decodeAccount(_ row: Row) -> Account {
        Account(
            id: Account.ID(row["id"]),
            email: row["email"],
            displayName: row["display_name"],
            kind: Account.Kind(rawValue: row["kind"]) ?? .imap,
            host: row["host"],
            port: UInt16(row["port"] as Int),
            security: Account.Security(rawValue: row["security"]) ?? .tls,
            username: row["username"]
        )
    }

    private static func decodeMessage(_ row: Row) throws -> Message {
        let to = try decodeAddresses(row["to_json"])
        let cc = try decodeAddresses(row["cc_json"])
        let from: MailAddress? = {
            if let addr = row["from_address"] as String? {
                return MailAddress(address: addr, name: row["from_name"])
            }
            return nil
        }()
        return Message(
            id: Message.ID(row["id"]),
            accountID: Account.ID(row["account_id"]),
            mailboxID: Mailbox.ID(row["mailbox_id"]),
            uid: UInt32(row["uid"] as Int),
            messageID: row["message_id"],
            threadID: (row["thread_id"] as String?).map { MessageThread.ID($0) },
            subject: row["subject"],
            from: from,
            to: to,
            cc: cc,
            date: row["date"],
            preview: row["preview"],
            size: row["size"],
            flags: MessageFlags(rawValue: UInt32(row["flags"] as Int)),
            importance: Importance(rawValue: row["importance"] as String) ?? .unknown
        )
    }

    private static func encodeAddresses(_ addresses: [MailAddress]) throws -> String {
        let data = try JSONEncoder().encode(addresses)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeAddresses(_ json: String) throws -> [MailAddress] {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return [] }
        return try JSONDecoder().decode([MailAddress].self, from: data)
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
