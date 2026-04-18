#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
@testable import Storage

final class RulesAndLogTests: XCTestCase {

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

    // MARK: - Schema v2

    func testV2TablesExist() async throws {
        let tables: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table'"
            )
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(tables.contains("rule"))
        XCTAssertTrue(tables.contains("classification_log"))
    }

    func testClassificationLogHasNoPIIColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(classification_log)")
                .map { ($0["name"] as String).lowercased() }
        }
        // Инвариант приватности: в логе нет subject / from / body / snippet
        for forbidden in ["subject", "from", "from_address", "from_name", "to", "body", "snippet"] {
            XCTAssertFalse(columns.contains(forbidden),
                           "classification_log must not contain \(forbidden)")
        }
        // Зато нужные колонки есть
        for required in ["id", "message_id_hash", "model", "tokens_in", "tokens_out",
                          "duration_ms", "confidence", "matched_rule_id", "error_code", "created_at"] {
            XCTAssertTrue(columns.contains(required), "missing \(required)")
        }
    }

    // MARK: - RulesRepository

    func testRulesCRUD() async throws {
        let repo = RulesRepository(pool: store.pool)
        let rule = Rule(
            text: "от boss@me.com — важное",
            intent: .markImportant,
            source: .manual
        )
        try await repo.upsert(rule)

        var all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.text, "от boss@me.com — важное")

        try await repo.setEnabled(id: rule.id, enabled: false)
        let active = try await repo.active()
        XCTAssertTrue(active.isEmpty)
        all = try await repo.all()
        XCTAssertEqual(all.count, 1)

        try await repo.delete(id: rule.id)
        all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRulesUpsertUpdates() async throws {
        let repo = RulesRepository(pool: store.pool)
        let r1 = Rule(
            text: "v1 text", intent: .markImportant, source: .manual
        )
        try await repo.upsert(r1)

        let r2 = Rule(
            id: r1.id, text: "v2 text", intent: .markUnimportant,
            enabled: true, createdAt: r1.createdAt, source: .manual
        )
        try await repo.upsert(r2)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.text, "v2 text")
        XCTAssertEqual(all.first?.intent, .markUnimportant)
    }

    // MARK: - ClassificationLog

    func testLogAppendAndRecent() async throws {
        let log = ClassificationLog(pool: store.pool)
        for i in 0..<5 {
            let entry = AuditEntry(
                messageIdHash: "hash-\(i)",
                model: "test/model",
                tokensIn: 100, tokensOut: 20, durationMs: 300,
                confidence: 0.8
            )
            try await log.append(entry)
        }
        let recent = try await log.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
    }

    func testLogMonthStats() async throws {
        let log = ClassificationLog(pool: store.pool)
        for i in 0..<3 {
            try await log.append(AuditEntry(
                messageIdHash: "h\(i)", model: "m", tokensIn: 100,
                tokensOut: 20, durationMs: 300, confidence: 0.8
            ))
        }
        try await log.append(AuditEntry(
            messageIdHash: "h-err", model: "m", tokensIn: 50, tokensOut: 0,
            durationMs: 100, confidence: 0, errorCode: "429"
        ))
        let stats = try await log.monthStats()
        XCTAssertEqual(stats.totalRequests, 4)
        XCTAssertEqual(stats.tokensIn, 350)
        XCTAssertEqual(stats.tokensOut, 60)
        XCTAssertEqual(stats.failures, 1)
    }
}
#endif
