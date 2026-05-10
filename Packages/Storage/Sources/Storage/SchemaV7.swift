import Foundation
import GRDB

/// Миграция v7: таблица `follow_up_queue` для AI-N Follow-up Tracker.
///
/// Хранит только идентификаторы и временны́е метки — без subject, тел, адресов.
/// Инвариант приватности CLAUDE.md соблюдён.
public enum SchemaV7 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7: follow_up_queue") { db in
            try db.execute(sql: """
                CREATE TABLE follow_up_queue (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    sent_date DATETIME NOT NULL,
                    due_date DATETIME NOT NULL,
                    thread_id TEXT,
                    is_resolved INTEGER NOT NULL DEFAULT 0,
                    resolved_at DATETIME,
                    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """)
            try db.execute(sql: """
                CREATE INDEX idx_follow_up_due
                    ON follow_up_queue(due_date)
                    WHERE is_resolved = 0;
                """)
        }
    }
}
