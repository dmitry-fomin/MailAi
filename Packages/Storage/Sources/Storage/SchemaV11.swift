import Foundation
import GRDB

/// Миграция v11: таблица VIP-отправителей.
///
/// MailAi-tq1r: VIP-список — email-адреса отправителей, письма которых
/// всегда показываются в VIP Inbox и не подавляются правилами фильтрации.
///
/// Таблица `vip_sender`:
/// - `email` — нижний регистр, PRIMARY KEY.
/// - `display_name` — отображаемое имя (опционально, для UI).
/// - `added_at` — метка времени добавления.
public enum SchemaV11 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11: vip_sender") { db in
            try db.execute(sql: """
                CREATE TABLE vip_sender (
                    email        TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT,
                    added_at     TEXT NOT NULL DEFAULT (datetime('now'))
                );
                """)
            // Индекс не нужен — поиск по PRIMARY KEY.
        }
    }
}
