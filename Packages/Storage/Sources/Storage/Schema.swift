import Foundation
import GRDB

/// Реестр миграций схемы. Миграции регистрируются строго по возрастанию
/// версии; добавление новых — append-only.
///
/// В БД хранятся **только метаданные**. Любая попытка добавить колонку
/// под тело письма / HTML / вложение — нарушение конституции.
public enum Schema {
    /// Регистрирует все миграции. Вызывается один раз при открытии БД.
    public static func registerAll(_ migrator: inout DatabaseMigrator) {
        registerV1(&migrator)
        SchemaV2.register(&migrator)
        SchemaV3.register(&migrator)
        SchemaV4.register(&migrator)
        SchemaV5.register(&migrator)
        SchemaV6.register(&migrator)
        SchemaV7.register(&migrator)
        SchemaV8.register(&migrator)
        SchemaV9.register(&migrator)
        SchemaV10.register(&migrator)
    }

    static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1: core schema") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text).notNull()
                t.column("email", .text).notNull()
                t.column("display_name", .text)
                t.column("kind", .text).notNull()
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("security", .text).notNull()
                t.column("username", .text).notNull()
            }

            try db.create(table: "mailbox") { t in
                t.primaryKey("id", .text).notNull()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("role", .text).notNull()
                t.column("unread_count", .integer).notNull().defaults(to: 0)
                t.column("total_count", .integer).notNull().defaults(to: 0)
                t.column("uid_validity", .integer)
                t.column("parent_id", .text)
                    .references("mailbox", onDelete: .cascade)
                t.uniqueKey(["account_id", "path"])
            }

            try db.create(table: "thread") { t in
                t.primaryKey("id", .text).notNull()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("subject", .text).notNull()
                t.column("last_date", .datetime).notNull()
            }
            try db.create(index: "idx_thread_last_date",
                          on: "thread",
                          columns: ["account_id", "last_date"])

            try db.create(table: "message") { t in
                t.primaryKey("id", .text).notNull()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("mailbox_id", .text).notNull()
                    .references("mailbox", onDelete: .cascade)
                t.column("uid", .integer).notNull()
                t.column("message_id", .text)
                t.column("thread_id", .text)
                    .references("thread", onDelete: .setNull)
                t.column("subject", .text).notNull()
                t.column("from_address", .text)
                t.column("from_name", .text)
                t.column("to_json", .text).notNull().defaults(to: "[]")
                t.column("cc_json", .text).notNull().defaults(to: "[]")
                t.column("date", .datetime).notNull()
                t.column("preview", .text)
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("flags", .integer).notNull().defaults(to: 0)
                t.column("importance", .text).notNull().defaults(to: "unknown")
                t.uniqueKey(["account_id", "mailbox_id", "uid"])
            }
            try db.create(index: "idx_message_mailbox_date",
                          on: "message",
                          columns: ["account_id", "mailbox_id", "date"])
            try db.create(index: "idx_message_thread",
                          on: "message",
                          columns: ["account_id", "thread_id"])
            try db.create(index: "idx_message_id_unique",
                          on: "message",
                          columns: ["message_id"],
                          options: [.unique])

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }
        }
    }
}
