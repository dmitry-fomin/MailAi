import Foundation
import GRDB

/// Миграция v9: таблица `offline_action_queue` для MailAi-d0bz.
///
/// Хранит ожидающие действия пользователя (mark read/unread, delete, move,
/// flag) при недоступном соединении. Поля тел писем не хранятся.
/// Conflict resolution: последнее действие над одним messageID выигрывает —
/// реализуется через замену строки при совпадении (messageID, actionType).
public enum SchemaV9 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9: offline_action_queue") { db in
            try db.execute(sql: """
                CREATE TABLE offline_action_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    message_id TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    action_type TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    attempt_count INTEGER NOT NULL DEFAULT 0
                );
                """)
            // FIFO-индекс для выборки по аккаунту в порядке поступления.
            try db.execute(sql: """
                CREATE INDEX idx_offline_action_account
                    ON offline_action_queue(account_id, id);
                """)
        }
    }
}
