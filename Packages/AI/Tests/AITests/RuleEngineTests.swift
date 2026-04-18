#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
import Storage
@testable import AI

final class RuleEngineTests: XCTestCase {

    private var url: URL!
    private var store: GRDBMetadataStore!
    private var engine: RuleEngine!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mailai-re-\(UUID().uuidString).sqlite")
        store = try GRDBMetadataStore(url: url)
        engine = RuleEngine(repository: RulesRepository(pool: store.pool))
    }

    override func tearDown() async throws {
        engine = nil
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    func testSaveAndActive() async throws {
        let r1 = Rule(text: "a", intent: .markImportant, enabled: true, source: .manual)
        let r2 = Rule(text: "b", intent: .markUnimportant, enabled: false, source: .manual)
        try await engine.save(r1)
        try await engine.save(r2)

        let active = try await engine.activeRules()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.text, "a")

        let all = try await engine.allRules()
        XCTAssertEqual(all.count, 2)
    }

    func testCacheInvalidationOnSave() async throws {
        let r = Rule(text: "x", intent: .markImportant, enabled: true, source: .manual)
        try await engine.save(r)
        let before = try await engine.activeRules()
        XCTAssertEqual(before.count, 1)

        // Изменим и сохраним — кеш должен обновиться
        try await engine.setEnabled(id: r.id, enabled: false)
        let after = try await engine.activeRules()
        XCTAssertEqual(after.count, 0)
    }

    func testDelete() async throws {
        let r = Rule(text: "d", intent: .markImportant, source: .manual)
        try await engine.save(r)
        try await engine.delete(id: r.id)
        let all = try await engine.allRules()
        XCTAssertTrue(all.isEmpty)
    }
}
#endif
