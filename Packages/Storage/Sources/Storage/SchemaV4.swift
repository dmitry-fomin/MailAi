import Foundation
import GRDB

/// Миграции v4: кеш AI-ответов, AI-метаданные сообщений, отложенные письма.
///
/// Приватный инвариант:
/// - `ai_cache.result_json` — обработанный AI-ответ (суммаризация), NOT сырое тело письма.
/// - `message.ai_snippet` — AI-сгенерированный snippet, NOT исходный preview/body.
/// - `snoozed_messages` — только идентификаторы и временны́е метки.
/// Никаких тел писем, subject, from, HTML на диске (инвариант CLAUDE.md).
public enum SchemaV4 {

    // MARK: - V4a: ai_cache

    static func registerV4a(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4a: ai_cache") { db in
            try db.execute(sql: """
                CREATE TABLE ai_cache (
                    id TEXT PRIMARY KEY NOT NULL,
                    feature TEXT NOT NULL,
                    cache_key TEXT NOT NULL,
                    result_json TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    expires_at DATETIME NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX idx_ai_cache_lookup ON ai_cache(feature, cache_key);
                """)
        }
    }

    // MARK: - V4b: AI columns on message

    static func registerV4b(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4b: message AI columns") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN ai_snippet TEXT;")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN category TEXT;")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN tone TEXT;")
        }
    }

    // MARK: - V4c: snoozed_messages

    static func registerV4c(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4c: snoozed_messages") { db in
            try db.execute(sql: """
                CREATE TABLE snoozed_messages (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    snooze_until DATETIME NOT NULL,
                    original_mailbox_id TEXT NOT NULL,
                    created_at DATETIME NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX idx_snoozed_until ON snoozed_messages(snooze_until);
                """)
        }
    }

    // MARK: - Register all

    /// Регистрирует миграции V4a, V4b, V4c в указанном мигрейторе.
    public static func register(_ migrator: inout DatabaseMigrator) {
        registerV4a(&migrator)
        registerV4b(&migrator)
        registerV4c(&migrator)
    }
}
