import Foundation
import GRDB

/// Миграция v2: таблицы AI-pack — `rule`, `classification_log` — плюс индекс
/// `message.importance`.
///
/// Приватный инвариант: `classification_log` содержит **только** техническую
/// телеметрию (hash, model, токены, duration, код ошибки). Никаких subject,
/// from, body. Проверяется тестом `PrivacyInvariantsTests`.
public enum SchemaV2 {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2: rules + classification_log") { db in
            try db.create(table: "rule") { t in
                t.primaryKey("id", .text).notNull()
                t.column("text", .text).notNull()
                t.column("intent", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("created_at", .datetime).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_rule_enabled",
                          on: "rule",
                          columns: ["enabled"])

            try db.create(table: "classification_log") { t in
                t.primaryKey("id", .text).notNull()
                t.column("message_id_hash", .text).notNull()
                t.column("model", .text).notNull()
                t.column("tokens_in", .integer).notNull()
                t.column("tokens_out", .integer).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("confidence", .double).notNull()
                t.column("matched_rule_id", .text)
                t.column("error_code", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_classification_log_hash",
                          on: "classification_log",
                          columns: ["message_id_hash"])
            try db.create(index: "idx_classification_log_created",
                          on: "classification_log",
                          columns: ["created_at"])

            try db.create(index: "idx_message_importance",
                          on: "message",
                          columns: ["account_id", "importance"])
        }
    }
}
