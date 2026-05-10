import Foundation
import GRDB

/// Миграция v10: добавление `account_id` в таблицу `signature`.
///
/// MailAi-8uz8: подписи теперь могут быть привязаны к конкретному аккаунту
/// (`account_id` — nullable). Существующие подписи получают `NULL` (глобальные).
///
/// `is_default` теперь уникален в рамках аккаунта: для каждого аккаунта
/// (и для глобальных подписей) может быть не более одной подписи по умолчанию.
public enum SchemaV10 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10: signature account_id") { db in
            // SQLite не поддерживает ALTER TABLE ADD CONSTRAINT, поэтому
            // пересоздаём таблицу через rename + create + copy + drop.
            try db.execute(sql: """
                ALTER TABLE signature RENAME TO signature_v9;
                """)
            try db.execute(sql: """
                CREATE TABLE signature (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    body TEXT NOT NULL,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    account_id TEXT
                );
                """)
            try db.execute(sql: """
                INSERT INTO signature (id, name, body, is_default, account_id)
                SELECT id, name, body, is_default, NULL
                FROM signature_v9;
                """)
            try db.execute(sql: """
                DROP TABLE signature_v9;
                """)
            // Индекс для быстрого поиска подписи по умолчанию для аккаунта.
            try db.execute(sql: """
                CREATE INDEX idx_signature_account
                    ON signature(account_id);
                """)
        }
    }
}
