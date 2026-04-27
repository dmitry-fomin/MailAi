#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
@testable import Storage

final class SignaturesRepositoryTests: XCTestCase {

    private var url: URL!
    private var store: GRDBMetadataStore!
    private var repo: SignaturesRepository!

    override func setUp() async throws {
        url = TestFactory.tempDatabaseURL()
        store = try GRDBMetadataStore(url: url)
        repo = SignaturesRepository(pool: store.pool)
    }

    override func tearDown() async throws {
        repo = nil
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Schema

    func testSignatureTableExists() async throws {
        let tables: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(tables.contains("signature"), "signature table must exist after V5")
    }

    func testSignatureColumns() async throws {
        let columns: [String] = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(signature)")
                .map { ($0["name"] as String).lowercased() }
        }
        for required in ["id", "name", "body", "is_default"] {
            XCTAssertTrue(columns.contains(required), "signature missing column: \(required)")
        }
    }

    // MARK: - CRUD

    func testAllEmptyInitially() async throws {
        let sigs = try await repo.all()
        XCTAssertTrue(sigs.isEmpty)
    }

    func testUpsertInsert() async throws {
        let sig = Signature(id: .init("sig-1"), name: "Рабочая", body: "С уважением, Дмитрий")
        try await repo.upsert(sig)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, sig.id)
        XCTAssertEqual(all[0].name, "Рабочая")
        XCTAssertEqual(all[0].body, "С уважением, Дмитрий")
        XCTAssertFalse(all[0].isDefault)
    }

    func testUpsertUpdate() async throws {
        let sig = Signature(id: .init("sig-upd"), name: "Старое", body: "Старое тело")
        try await repo.upsert(sig)

        let updated = Signature(id: sig.id, name: "Новое", body: "Новое тело", isDefault: true)
        try await repo.upsert(updated)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].name, "Новое")
        XCTAssertEqual(all[0].body, "Новое тело")
        XCTAssertTrue(all[0].isDefault)
    }

    func testDelete() async throws {
        let sig1 = Signature(id: .init("sig-del-1"), name: "A", body: "a")
        let sig2 = Signature(id: .init("sig-del-2"), name: "B", body: "b")
        try await repo.upsert(sig1)
        try await repo.upsert(sig2)

        try await repo.delete(id: sig1.id)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, sig2.id)
    }

    func testDeleteNonExistentIsNoOp() async throws {
        try await repo.delete(id: .init("does-not-exist"))
        let all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - setDefault

    func testSetDefaultClearsOthers() async throws {
        let s1 = Signature(id: .init("sd-1"), name: "A", body: "a", isDefault: false)
        let s2 = Signature(id: .init("sd-2"), name: "B", body: "b", isDefault: false)
        let s3 = Signature(id: .init("sd-3"), name: "C", body: "c", isDefault: false)
        try await repo.upsert(s1)
        try await repo.upsert(s2)
        try await repo.upsert(s3)

        try await repo.setDefault(id: s2.id)

        let all = try await repo.all()
        let defaults = all.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults[0].id, s2.id)
    }

    func testSetDefaultTwiceChangesDefault() async throws {
        let s1 = Signature(id: .init("sc-1"), name: "A", body: "a")
        let s2 = Signature(id: .init("sc-2"), name: "B", body: "b")
        try await repo.upsert(s1)
        try await repo.upsert(s2)

        try await repo.setDefault(id: s1.id)
        try await repo.setDefault(id: s2.id)

        let all = try await repo.all()
        let defaults = all.filter(\.isDefault)
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults[0].id, s2.id)
    }

    // MARK: - Sorting

    func testAllSortedByName() async throws {
        let names = ["Зима", "Весна", "Лето", "Осень"]
        for name in names.shuffled() {
            try await repo.upsert(Signature(id: .init(UUID().uuidString), name: name, body: ""))
        }
        let all = try await repo.all()
        let sorted = all.map(\.name)
        XCTAssertEqual(sorted, sorted.sorted())
    }
}
#endif
