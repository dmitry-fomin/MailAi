import Foundation
import GRDB
import Core

/// Максимальная длина snippet (символов) — только plain-text часть тела письма.
/// Snippet хранится в FTS5-таблице `message_snippet_fts` и никогда не попадает
/// в `message`-таблицу, логи или git (инвариант CLAUDE.md).
private let snippetMaxLength = 500

/// FTS5-индекс для полнотекстового поиска по метаданным и snippet письма.
///
/// Индексирует:
/// - `subject`   — тема письма
/// - `from_addr` — адрес отправителя
/// - `from_name` — имя отправителя
/// - `to_addr`   — адреса получателей (через пробел)
/// - `snippet`   — первые \(snippetMaxLength) символов plain-text тела (только в памяти,
///                 передаётся явно при вызове `index(message:snippet:)`)
///
/// Использует таблицу `message_snippet_fts` (SchemaV8).
/// Существующий `LocalSearcher` / `GRDBSearchService` (таблица `message_fts` из SchemaV3)
/// работает независимо и не затрагивается.
///
/// ## Потокобезопасность
/// Актор сериализует все операции записи. Чтение выполняется параллельно через
/// `DatabasePool.read`, который не блокирует запись (WAL).
public actor FullTextSearchIndex {

    // MARK: - Dependencies

    private let pool: DatabasePool

    // MARK: - Init

    /// - Parameter pool: Тот же `DatabasePool`, что открыт в `GRDBMetadataStore`.
    ///   Миграция SchemaV8 должна быть применена до первого использования.
    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Public API

    /// Добавляет или обновляет запись в FTS5-индексе.
    ///
    /// - Parameters:
    ///   - message: Метаданные письма (subject, from, to и т.д.).
    ///   - snippet: Первые \(snippetMaxLength) символов plain-text тела (опционально).
    ///             Тело письма передаётся только через этот параметр и никогда не
    ///             сохраняется отдельно от FTS5-строки. Если nil — поле snippet пустое.
    public func index(message: Message, snippet: String? = nil) async throws {
        let trimmedSnippet = snippet.map { String($0.prefix(snippetMaxLength)) } ?? ""
        let toAddr = message.to.map(\.address).joined(separator: " ")
        let fromAddr = message.from?.address ?? ""
        let fromName = message.from?.name ?? ""
        let subject = message.subject
        let messageID = message.id.rawValue

        try await pool.write { db in
            // Удаляем существующую запись (FTS5 не поддерживает UPDATE напрямую).
            try db.execute(
                sql: """
                    DELETE FROM message_snippet_fts WHERE message_id = ?;
                    """,
                arguments: [messageID]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_snippet_fts
                        (message_id, subject, from_addr, from_name, to_addr, snippet)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """,
                arguments: [messageID, subject, fromAddr, fromName, toAddr, trimmedSnippet]
            )
        }
    }

    /// Поиск по FTS5-индексу. Возвращает идентификаторы совпавших писем,
    /// отсортированные по релевантности (rank FTS5), до `limit` результатов.
    ///
    /// - Parameters:
    ///   - query: Строка поиска. Поддерживает операторы FTS5 (prefix `*`, кавычки для фразы).
    ///            Пустая строка возвращает пустой массив без обращения к БД.
    ///   - limit: Максимальное число результатов (по умолчанию 200).
    /// - Returns: Массив `Message.ID` в порядке убывания релевантности.
    public func search(query: String, limit: Int = 200) async throws -> [Message.ID] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // FTS5-запрос: добавляем суффиксный `*` для prefix-search на последнем токене.
        let ftsQuery = Self.buildFTSQuery(trimmed)

        return try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT message_id
                    FROM message_snippet_fts
                    WHERE message_snippet_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?;
                    """,
                arguments: [ftsQuery, limit]
            )
            return rows.compactMap { row -> Message.ID? in
                guard let raw = row["message_id"] as String? else { return nil }
                return Message.ID(raw)
            }
        }
    }

    /// Удаляет запись из FTS5-индекса.
    ///
    /// - Parameter messageID: Идентификатор письма. Если записи нет — no-op.
    public func delete(messageID: Message.ID) async throws {
        let raw = messageID.rawValue
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM message_snippet_fts WHERE message_id = ?;",
                arguments: [raw]
            )
        }
    }

    // MARK: - Private helpers

    /// Формирует FTS5 MATCH-строку из пользовательского ввода.
    ///
    /// Стратегия:
    /// - Если запрос уже содержит FTS5-операторы (`"`, `*`, `AND`, `OR`, `NOT`) —
    ///   передаём как есть.
    /// - Иначе — оборачиваем каждый токен в кавычки и добавляем `*` к последнему,
    ///   чтобы поддержать prefix-search при live-вводе. Токены объединяем через AND.
    private static func buildFTSQuery(_ input: String) -> String {
        // Если есть FTS5-специальные символы — не трогаем.
        let fts5Operators = ["\"", " AND ", " OR ", " NOT ", "*"]
        if fts5Operators.contains(where: { input.contains($0) }) {
            return input
        }

        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return input }

        var parts: [String] = []
        for (idx, token) in tokens.enumerated() {
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            if idx == tokens.count - 1 {
                // Последний токен — prefix search.
                parts.append("\"\(escaped)\"*")
            } else {
                parts.append("\"\(escaped)\"")
            }
        }
        return parts.joined(separator: " AND ")
    }
}
