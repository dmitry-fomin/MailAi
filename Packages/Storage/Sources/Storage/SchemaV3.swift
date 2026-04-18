import Foundation
import GRDB

/// Миграция v3: FTS5-индекс над метаданными писем. В индексе — ТОЛЬКО
/// `subject`, `from_address`, `from_name`, `preview`. Тела/HTML/вложения
/// никогда не попадают сюда (инвариант CLAUDE.md).
///
/// Индекс — `external content`-таблица, ссылается на `message.rowid`, чтобы
/// не дублировать данные. Триггеры держат индекс в синхроне с `message`
/// при INSERT/UPDATE/DELETE.
public enum SchemaV3 {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3: FTS5 index over message metadata") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    subject, from_address, from_name, preview,
                    content='message', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)

            // Первичная загрузка из существующих сообщений.
            try db.execute(sql: """
                INSERT INTO message_fts(rowid, subject, from_address, from_name, preview)
                SELECT rowid,
                       COALESCE(subject, ''),
                       COALESCE(from_address, ''),
                       COALESCE(from_name, ''),
                       COALESCE(preview, '')
                FROM message;
                """)

            // Триггеры: держим message_fts в синхроне с message.
            try db.execute(sql: """
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, subject, from_address, from_name, preview)
                    VALUES (new.rowid,
                            COALESCE(new.subject, ''),
                            COALESCE(new.from_address, ''),
                            COALESCE(new.from_name, ''),
                            COALESCE(new.preview, ''));
                END;
                """)

            try db.execute(sql: """
                CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, subject, from_address, from_name, preview)
                    VALUES('delete', old.rowid,
                           COALESCE(old.subject, ''),
                           COALESCE(old.from_address, ''),
                           COALESCE(old.from_name, ''),
                           COALESCE(old.preview, ''));
                END;
                """)

            try db.execute(sql: """
                CREATE TRIGGER message_au AFTER UPDATE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, subject, from_address, from_name, preview)
                    VALUES('delete', old.rowid,
                           COALESCE(old.subject, ''),
                           COALESCE(old.from_address, ''),
                           COALESCE(old.from_name, ''),
                           COALESCE(old.preview, ''));
                    INSERT INTO message_fts(rowid, subject, from_address, from_name, preview)
                    VALUES (new.rowid,
                            COALESCE(new.subject, ''),
                            COALESCE(new.from_address, ''),
                            COALESCE(new.from_name, ''),
                            COALESCE(new.preview, ''));
                END;
                """)
        }
    }
}
