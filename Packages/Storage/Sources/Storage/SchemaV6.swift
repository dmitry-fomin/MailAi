import Foundation
import GRDB

/// Миграция v6: исправление UNIQUE-индекса на `message_id`.
///
/// Проблема v1: `idx_message_id_unique` создан без `ON CONFLICT IGNORE`,
/// поэтому дублирующийся `message_id` (одно письмо в нескольких папках)
/// бросает исключение и прерывает весь upsert-батч.
///
/// Решение: убрать UNIQUE-ограничение — дедупликация происходит
/// на уровне PK (`id`) через `ON CONFLICT(id) DO UPDATE` в upsertMessage.
/// Обычный индекс сохраняет производительность поиска по message_id.
public enum SchemaV6 {

    public static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6: message_id index non-unique") { db in
            // Удаляем старый UNIQUE-индекс.
            try db.execute(sql: "DROP INDEX IF EXISTS idx_message_id_unique;")
            // Создаём обычный (non-unique) индекс — производительность та же,
            // но дубль message_id не прерывает батч.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_message_id
                    ON message(message_id)
                    WHERE message_id IS NOT NULL;
                """)
        }
    }
}
