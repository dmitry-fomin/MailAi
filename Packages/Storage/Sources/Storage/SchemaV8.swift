import Foundation
import GRDB

/// Миграция v8: расширенный FTS5-индекс `message_snippet_fts` для `FullTextSearchIndex`.
///
/// Это standalone (не external-content) таблица, которая хранит:
///   - `message_id` — строковый идентификатор сообщения (PK)
///   - `subject`    — тема письма
///   - `from_addr`  — адрес отправителя
///   - `from_name`  — имя отправителя
///   - `to_addr`    — адреса получателей (конкатенация через пробел)
///   - `snippet`    — первые 500 символов plain-text тела (передаётся из памяти)
///
/// Тело письма хранится здесь ТОЛЬКО в виде snippet ≤ 500 символов.
/// Полный HTML/тело письма никогда не пишется ни в эту таблицу, ни в любую другую
/// (инвариант CLAUDE.md: тела писем не хранятся на диске).
///
/// Используется `FullTextSearchIndex` актором. FTS5-таблица `message_fts` (v3)
/// остаётся для `LocalSearcher` / `GRDBSearchService` — они работают независимо.
public enum SchemaV8 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8: message_snippet_fts for FullTextSearchIndex") { db in
            // Standalone FTS5: хранит собственные данные (не external-content),
            // потому что snippet берётся из памяти при indexing, а не из message-таблицы.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS message_snippet_fts USING fts5(
                    message_id UNINDEXED,
                    subject,
                    from_addr,
                    from_name,
                    to_addr,
                    snippet,
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
        }
    }
}
