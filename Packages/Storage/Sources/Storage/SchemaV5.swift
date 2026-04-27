import Foundation
import GRDB

/// Миграция v5: таблица `signature` — настройки подписей пользователя.
///
/// Инвариант приватности: `body` хранит текст *подписи*, а не тело письма.
/// Подписи — пользовательские настройки (аналог contact/label), поэтому
/// их хранение на диске соответствует политике CLAUDE.md.
public enum SchemaV5 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5: signatures") { db in
            try db.execute(sql: """
                CREATE TABLE signature (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    body TEXT NOT NULL,
                    is_default INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
    }
}
