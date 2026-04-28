import Foundation
import GRDB
import Core

/// Трекер ожидания ответов на исходящие письма.
///
/// ## Жизненный цикл
/// 1. После отправки — `trackIfNeeded(message:bodySnippet:)` анализирует письмо через AI.
///    Если письмо ожидает ответа — запись попадает в `follow_up_queue`.
/// 2. Периодически (например, каждые 15 минут) — `checkOverdue()` возвращает
///    просроченные записи, по которым нет ответа в треде.
/// 3. Пользователь закрывает вручную — `resolve(messageID:)`.
/// 4. При получении ответа — `resolveIfReplied(threadID:afterDate:)`.
///
/// ## Приватность
/// - В AI уходит только тема + первые 300 символов тела (только в памяти).
/// - В БД хранятся только идентификаторы и временны́е метки.
/// - Тела писем никогда не пишутся на диск (инвариант CLAUDE.md).
public actor FollowUpTracker {

    // MARK: - Dependencies

    private let pool: DatabasePool
    private let analyzer: any AIFollowUpAnalyzer

    // MARK: - Init

    /// - Parameters:
    ///   - pool: Тот же `DatabasePool`, что открыт в `GRDBMetadataStore`.
    ///           Таблица `follow_up_queue` создаётся в SchemaV7.
    ///   - analyzer: AI-анализатор (обычно `FollowUpAnalyzerImpl`).
    public init(pool: DatabasePool, analyzer: any AIFollowUpAnalyzer) {
        self.pool = pool
        self.analyzer = analyzer
    }

    // MARK: - Public API

    /// Анализирует исходящее письмо и, если ожидается ответ,
    /// добавляет запись в очередь.
    ///
    /// - Parameters:
    ///   - message:     Метаданные отправленного письма.
    ///   - bodySnippet: Первые 300 символов plain-text тела (только в памяти).
    /// - Returns: `FollowUpEntry` если письмо добавлено в очередь, иначе nil.
    @discardableResult
    public func trackIfNeeded(
        message: Message,
        bodySnippet: String
    ) async throws -> FollowUpEntry? {
        let snippet = String(bodySnippet.prefix(300))
        let analysis = try await analyzer.analyze(
            subject: message.subject,
            bodySnippet: snippet
        )
        guard analysis.expectsReply, let days = analysis.daysToFollowUp else {
            return nil
        }
        let dueDate = Calendar.current.date(
            byAdding: .day,
            value: days,
            to: message.date
        ) ?? message.date.addingTimeInterval(Double(days) * 86_400)

        let entry = FollowUpEntry(
            messageID: message.id,
            sentDate: message.date,
            dueDate: dueDate,
            threadID: message.threadID,
            isResolved: false
        )
        try await upsert(entry)
        return entry
    }

    /// Возвращает все просроченные, нерешённые записи (dueDate <= now).
    public func checkOverdue(now: Date = Date()) async throws -> [FollowUpEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM follow_up_queue
                WHERE is_resolved = 0 AND due_date <= ?
                ORDER BY due_date ASC
                """, arguments: [now])
            return rows.map(Self.decode)
        }
    }

    /// Возвращает все нерешённые записи (в т.ч. ещё не просроченные).
    public func pending() async throws -> [FollowUpEntry] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM follow_up_queue
                WHERE is_resolved = 0
                ORDER BY due_date ASC
                """)
            return rows.map(Self.decode)
        }
    }

    /// Помечает запись как разрешённую (ответ получен или пользователь закрыл вручную).
    public func resolve(messageID: Message.ID, at date: Date = Date()) async throws {
        let raw = messageID.rawValue
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE follow_up_queue
                SET is_resolved = 1, resolved_at = ?
                WHERE message_id = ? AND is_resolved = 0
                """, arguments: [date, raw])
        }
    }

    /// Разрешает все нерешённые записи для треда, если в тред пришёл ответ
    /// после даты отправки.
    ///
    /// Вызывается при получении нового письма в треде.
    public func resolveIfReplied(
        threadID: MessageThread.ID,
        replyDate: Date
    ) async throws {
        let rawThread = threadID.rawValue
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE follow_up_queue
                SET is_resolved = 1, resolved_at = ?
                WHERE thread_id = ?
                  AND is_resolved = 0
                  AND sent_date < ?
                """, arguments: [replyDate, rawThread, replyDate])
        }
    }

    /// Удаляет запись из очереди (например, при удалении письма).
    public func remove(messageID: Message.ID) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM follow_up_queue WHERE message_id = ?
                """, arguments: [messageID.rawValue])
        }
    }

    // MARK: - Private

    private func upsert(_ entry: FollowUpEntry) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO follow_up_queue
                    (message_id, sent_date, due_date, thread_id,
                     is_resolved, resolved_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET
                    due_date = excluded.due_date,
                    is_resolved = excluded.is_resolved
                """, arguments: [
                    entry.messageID.rawValue,
                    entry.sentDate,
                    entry.dueDate,
                    entry.threadID?.rawValue,
                    entry.isResolved ? 1 : 0,
                    entry.resolvedAt,
                    entry.createdAt
                ])
        }
    }

    private static func decode(_ row: Row) -> FollowUpEntry {
        let mid  = Message.ID(row["message_id"] as String? ?? "")
        let sent = row["sent_date"] as Date? ?? Date()
        let due  = row["due_date"]  as Date? ?? Date()
        let tid  = (row["thread_id"] as String?).map { MessageThread.ID($0) }
        let resolved    = (row["is_resolved"] as Int64? ?? 0) != 0
        let resolvedAt  = row["resolved_at"] as Date?
        let createdAt   = row["created_at"]  as Date? ?? Date()
        return FollowUpEntry(
            messageID: mid,
            sentDate: sent,
            dueDate: due,
            threadID: tid,
            isResolved: resolved,
            resolvedAt: resolvedAt,
            createdAt: createdAt
        )
    }
}

// MARK: - FollowUpAnalyzerImpl

/// Конкретная реализация `AIFollowUpAnalyzer` через OpenRouter.
///
/// Анализирует исходящее письмо и определяет: ожидает ли оно ответа.
/// В AI уходит только subject + первые 300 символов тела.
public actor FollowUpAnalyzerImpl: AIFollowUpAnalyzer {

    private let provider: any AIProvider
    private var cachedSystemPrompt: String?

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    public func analyze(subject: String, bodySnippet: String) async throws -> FollowUpAnalysis {
        let system = try await resolveSystemPrompt()
        let user = "Subject: \(subject)\n\nMessage: \(String(bodySnippet.prefix(300)))"

        var responseText = ""
        for try await chunk in provider.complete(
            system: system,
            user: user,
            streaming: false,
            maxTokens: 100
        ) {
            responseText += chunk
        }

        return parseResponse(responseText)
    }

    // MARK: - Private

    private func resolveSystemPrompt() async throws -> String {
        if let cached = cachedSystemPrompt { return cached }
        let base = try await PromptStore.shared.load(id: "follow_up")
        let prompt = """
            \(base)

            Respond with ONLY valid JSON: {"expectsReply": true/false, "daysToFollowUp": 1|3|7|14|null}
            - Set "expectsReply" to true if the email clearly awaits a reply.
            - Set "daysToFollowUp" to null if "expectsReply" is false.
            - Choose days: 1 (urgent), 3 (normal), 7 (relaxed), 14 (low priority).
            No explanation, just JSON.
            """
        cachedSystemPrompt = prompt
        return prompt
    }

    private func parseResponse(_ text: String) -> FollowUpAnalysis {
        guard let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return FollowUpAnalysis(expectsReply: false, daysToFollowUp: nil)
        }

        let expectsReply = dict["expectsReply"] as? Bool ?? false
        let days = dict["daysToFollowUp"] as? Int
        return FollowUpAnalysis(
            expectsReply: expectsReply,
            daysToFollowUp: expectsReply ? (days ?? 3) : nil
        )
    }
}
