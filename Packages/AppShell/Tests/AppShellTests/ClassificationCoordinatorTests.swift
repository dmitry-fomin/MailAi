#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
import Storage
import AI
@testable import AppShell

/// Stub AIProvider, отдающий заранее заданный JSON.
struct StubProvider: AIProvider {
    let payload: String
    func complete(system: String, user: String, streaming: Bool, maxTokens: Int = 200)
        -> AsyncThrowingStream<String, any Error> {
        let p = payload
        return AsyncThrowingStream { continuation in
            continuation.yield(p)
            continuation.finish()
        }
    }
}

final class ClassificationCoordinatorTests: XCTestCase {

    private var dbURL: URL!
    private var store: GRDBMetadataStore!
    private var accountID: Account.ID!
    private var mailboxID: Mailbox.ID!

    override func setUp() async throws {
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mailai-ct-\(UUID().uuidString).sqlite")
        store = try GRDBMetadataStore(url: dbURL)
        let account = Account(
            id: .init("acc-coord"), email: "u@me.com", displayName: nil,
            kind: .imap, host: "i.m", port: 993, security: .tls, username: "u"
        )
        try await store.upsert(account)
        accountID = account.id
        let mbox = Mailbox(
            id: .init("mb-inbox"), accountID: account.id,
            name: "INBOX", path: "INBOX", role: .inbox,
            unreadCount: 0, totalCount: 0, uidValidity: 1
        )
        try await store.upsert(mbox)
        mailboxID = mbox.id
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func makeMessage(id: String, subject: String = "s", from: String = "a@b.com") -> Message {
        Message(
            id: .init(id),
            accountID: accountID,
            mailboxID: mailboxID,
            uid: 1, messageID: "\(id)@test", threadID: nil,
            subject: subject,
            from: MailAddress(address: from, name: nil),
            to: [MailAddress(address: "u@me.com", name: nil)],
            cc: [], date: Date(), preview: nil, size: 0,
            flags: [], importance: .unknown
        )
    }

    func testCoordinatorPersistsImportanceAndLogs() async throws {
        let msg = makeMessage(id: "m1")
        try await store.upsert([msg])

        let pool = store.pool
        let log = ClassificationLog(pool: pool)
        let rules = RuleEngine(repository: RulesRepository(pool: pool))
        let provider = StubProvider(payload: #"{"importance":"unimportant","confidence":0.77,"reasoning":"marketing"}"#)
        let classifier = Classifier(provider: provider, model: "stub/model")
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 1)

        let coord = ClassificationCoordinator(
            store: store, rules: rules, classifier: classifier, log: log, queue: queue
        ) { _ in
            ("тело письма, короткое для теста", "text/plain")
        }

        await coord.enqueue(messageIDs: [msg.id])
        await coord.runUntilDrained()

        let updated = try await store.message(id: msg.id)
        XCTAssertEqual(updated?.importance, .unimportant)

        let recent = try await log.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.model, "stub/model")
        XCTAssertNil(recent.first?.errorCode)
    }

    func testFailureRecordsErrorCodeAndDoesNotUpdateImportance() async throws {
        let msg = makeMessage(id: "m2")
        try await store.upsert([msg])

        let pool = store.pool
        let log = ClassificationLog(pool: pool)
        let rules = RuleEngine(repository: RulesRepository(pool: pool))
        let provider = StubProvider(payload: "garbage not json")
        let classifier = Classifier(provider: provider, model: "stub/model")
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 1)

        let coord = ClassificationCoordinator(
            store: store, rules: rules, classifier: classifier, log: log, queue: queue
        ) { _ in ("body", "text/plain") }

        await coord.enqueue(messageIDs: [msg.id])
        await coord.runUntilDrained()

        let updated = try await store.message(id: msg.id)
        XCTAssertEqual(updated?.importance, .unknown)

        let recent = try await log.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.errorCode, "malformed_json")
    }

    func testPrivacyInvariantsNoPIIInLog() async throws {
        let secretSubject = "SECRET_SUBJECT_XYZ_9ec3"
        let secretFrom = "secret.sender@hidden.example"
        let secretBody = "SECRET_BODY_LOREM_IPSUM_AAAA_BBBB"

        let msg = makeMessage(id: "pi-1", subject: secretSubject, from: secretFrom)
        try await store.upsert([msg])

        let pool = store.pool
        let log = ClassificationLog(pool: pool)
        let rules = RuleEngine(repository: RulesRepository(pool: pool))
        let provider = StubProvider(payload: #"{"importance":"unimportant","confidence":0.9,"reasoning":"test"}"#)
        let classifier = Classifier(provider: provider, model: "stub/model")
        let queue = ClassificationQueue(batchSize: 5, maxParallel: 1)

        let coord = ClassificationCoordinator(
            store: store, rules: rules, classifier: classifier, log: log, queue: queue
        ) { _ in (secretBody, "text/plain") }

        await coord.enqueue(messageIDs: [msg.id])
        await coord.runUntilDrained()

        // (1) classification_log не содержит ни subject, ни from, ни body
        let entries = try await log.recent(limit: 10)
        let serialized = try JSONEncoder().encode(entries)
        let text = String(data: serialized, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(secretSubject), "log leaked subject")
        XCTAssertFalse(text.contains(secretFrom), "log leaked from")
        XCTAssertFalse(text.contains(secretBody), "log leaked body")

        // (2) Прямой grep по всей таблице classification_log
        let logDump = try await pool.read { db -> String in
            try Row.fetchAll(db, sql: "SELECT * FROM classification_log")
                .map { String(describing: $0) }
                .joined(separator: "\n")
        }
        XCTAssertFalse(logDump.contains(secretSubject))
        XCTAssertFalse(logDump.contains(secretFrom))
        XCTAssertFalse(logDump.contains(secretBody))

        // (3) Subject/from допустимы в таблице message (по документации), но body — НЕТ
        let msgDump = try await pool.read { db -> String in
            try Row.fetchAll(db, sql: "SELECT * FROM message")
                .map { String(describing: $0) }
                .joined(separator: "\n")
        }
        XCTAssertTrue(msgDump.contains(secretSubject), "subject must live in message table")
        XCTAssertTrue(msgDump.contains(secretFrom), "from must live in message table")
        XCTAssertFalse(msgDump.contains(secretBody), "BODY MUST NEVER BE IN STORAGE")
    }
}

#endif
