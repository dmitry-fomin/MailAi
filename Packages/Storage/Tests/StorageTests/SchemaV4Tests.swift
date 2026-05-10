#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
@testable import Storage

/// Проверяет, что миграции V4a, V4b, V4c проходят без ошибок
/// и создают ожидаемые таблицы / колонки.
final class SchemaV4Tests: XCTestCase {

    private var url: URL!
    private var store: GRDBMetadataStore!

    override func setUp() async throws {
        url = TestFactory.tempDatabaseURL()
        store = try GRDBMetadataStore(url: url)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - V4a: ai_cache

    func testV4aAiCacheTableExists() async throws {
        let tables: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(tables.contains("ai_cache"), "ai_cache table must exist after V4a")
    }

    func testV4aAiCacheColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(ai_cache)")
                .map { ($0["name"] as String).lowercased() }
        }
        for required in ["id", "feature", "cache_key", "result_json", "created_at", "expires_at"] {
            XCTAssertTrue(columns.contains(required), "ai_cache missing column: \(required)")
        }
    }

    func testV4aAiCacheIndex() async throws {
        let indices: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(indices.contains("idx_ai_cache_lookup"), "idx_ai_cache_lookup must exist")
    }

    // MARK: - V4b: message AI columns

    func testV4bMessageAIColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(message)")
                .map { ($0["name"] as String).lowercased() }
        }
        for required in ["ai_snippet", "category", "tone"] {
            XCTAssertTrue(columns.contains(required), "message missing AI column: \(required)")
        }
    }

    // MARK: - V4c: snoozed_messages

    func testV4cSnoozedMessagesTableExists() async throws {
        let tables: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(tables.contains("snoozed_messages"), "snoozed_messages table must exist after V4c")
    }

    func testV4cSnoozedMessagesColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(snoozed_messages)")
                .map { ($0["name"] as String).lowercased() }
        }
        for required in ["message_id", "snooze_until", "original_mailbox_id", "created_at"] {
            XCTAssertTrue(columns.contains(required), "snoozed_messages missing column: \(required)")
        }
    }

    func testV4cSnoozedMessagesIndex() async throws {
        let indices: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(indices.contains("idx_snoozed_until"), "idx_snoozed_until must exist")
    }

    // MARK: - Инвариант приватности

    func testAiCacheHasNoPIIColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(ai_cache)")
                .map { ($0["name"] as String).lowercased() }
        }
        // ai_cache не должен содержать сырые тела писем или адреса
        for forbidden in ["body", "html", "from", "from_address", "to", "subject"] {
            XCTAssertFalse(columns.contains(forbidden),
                           "ai_cache must not contain \(forbidden)")
        }
    }

    func testSnoozedMessagesHasNoPIIColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(snoozed_messages)")
                .map { ($0["name"] as String).lowercased() }
        }
        for forbidden in ["body", "html", "subject", "from", "from_address", "to"] {
            XCTAssertFalse(columns.contains(forbidden),
                           "snoozed_messages must not contain \(forbidden)")
        }
    }
}
#endif
