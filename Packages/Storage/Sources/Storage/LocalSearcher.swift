import Foundation
import GRDB
import Core

/// Локальный поиск по FTS5-индексу (SchemaV3). Работает на тех же
/// метаданных, что уже лежат в `message` — тела писем не индексируются.
public actor LocalSearcher {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    /// Поиск по аккаунту с ограничением по папке (если задана) и по
    /// разобранному запросу. Возвращает до `limit` совпадений, отсортированных
    /// по `rank` (релевантность FTS5) → `date DESC`.
    public func search(
        query: SearchQuery,
        accountID: Account.ID,
        mailboxID: Mailbox.ID? = nil,
        limit: Int = 200
    ) async throws -> [Message] {
        try await pool.read { db in
            var sql = """
                SELECT m.*
                FROM message AS m
                """
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []

            // FTS-часть: если есть свободный текст или from: — джойним message_fts.
            let freeText = query.freeText.trimmingCharacters(in: .whitespaces)
            if !freeText.isEmpty || query.from != nil {
                sql += " JOIN message_fts AS f ON f.rowid = m.rowid"
                var matchParts: [String] = []
                if !freeText.isEmpty {
                    matchParts.append(Self.quote(freeText) + "*")
                }
                if let from = query.from {
                    matchParts.append("from_address:" + Self.quote(from) + "* OR from_name:" + Self.quote(from) + "*")
                }
                clauses.append("message_fts MATCH ?")
                args.append(matchParts.joined(separator: " "))
            }

            clauses.append("m.account_id = ?")
            args.append(accountID.rawValue)
            if let mailboxID {
                clauses.append("m.mailbox_id = ?")
                args.append(mailboxID.rawValue)
            }
            if query.hasAttachment == true {
                clauses.append("(m.flags & ?) != 0")
                args.append(MessageFlags.hasAttachment.rawValue)
            }
            if let isUnread = query.isUnread {
                if isUnread {
                    clauses.append("(m.flags & ?) = 0")
                } else {
                    clauses.append("(m.flags & ?) != 0")
                }
                args.append(MessageFlags.seen.rawValue)
            }
            if query.isFlagged == true {
                clauses.append("(m.flags & ?) != 0")
                args.append(MessageFlags.flagged.rawValue)
            }
            if let before = query.before {
                clauses.append("m.date < ?")
                args.append(before)
            }
            if let after = query.after {
                clauses.append("m.date >= ?")
                args.append(after)
            }

            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }
            sql += " ORDER BY m.date DESC LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.message(from:))
        }
    }

    /// FTS5 quote: оборачивает строку в двойные кавычки, экранируя кавычки
    /// внутри. `MATCH` принимает exact-phrase в кавычках или prefix через `*`.
    private static func quote(_ input: String) -> String {
        let escaped = input.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Та же карта из `GRDBMetadataStore.messages(in:page:)`; дублируем, чтобы
    /// не расширять публичный API GRDB-слоя. Tests покрывают обе через
    /// общий smoke-сценарий.
    static func message(from row: Row) -> Message {
        let flags = MessageFlags(rawValue: UInt32(row["flags"] as Int64? ?? 0))
        let imp = Importance(rawValue: row["importance"] as String? ?? "") ?? .unknown
        let toJSON = (row["to_json"] as String?) ?? "[]"
        let ccJSON = (row["cc_json"] as String?) ?? "[]"
        let to = (try? JSONDecoder().decode([MailAddress].self, from: Data(toJSON.utf8))) ?? []
        let cc = (try? JSONDecoder().decode([MailAddress].self, from: Data(ccJSON.utf8))) ?? []
        var from: MailAddress?
        if let addr = row["from_address"] as String?, !addr.isEmpty {
            from = MailAddress(address: addr, name: row["from_name"] as String?)
        }
        return Message(
            id: Message.ID(row["id"] as String? ?? ""),
            accountID: Account.ID(row["account_id"] as String? ?? ""),
            mailboxID: Mailbox.ID(row["mailbox_id"] as String? ?? ""),
            uid: UInt32(row["uid"] as Int64? ?? 0),
            messageID: row["message_id"] as String?,
            threadID: (row["thread_id"] as String?).map { MessageThread.ID($0) },
            subject: row["subject"] as String? ?? "",
            from: from,
            to: to,
            cc: cc,
            date: row["date"] as Date? ?? Date(timeIntervalSince1970: 0),
            preview: row["preview"] as String?,
            size: Int(row["size"] as Int64? ?? 0),
            flags: flags,
            importance: imp
        )
    }
}
