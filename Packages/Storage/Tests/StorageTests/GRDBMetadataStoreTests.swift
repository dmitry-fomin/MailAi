#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
@testable import Storage

// MARK: - Helpers

enum TestFactory {
    static func tempDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mailai-\(UUID().uuidString).sqlite")
    }

    static func account(id: String = "acc-1") -> Account {
        Account(
            id: .init(id),
            email: "user@example.com",
            displayName: "User",
            kind: .imap,
            host: "imap.example.com",
            port: 993,
            security: .tls,
            username: "user@example.com"
        )
    }

    static func inbox(account: Account.ID, id: String = "mb-inbox") -> Mailbox {
        Mailbox(
            id: .init(id),
            accountID: account,
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            unreadCount: 0,
            totalCount: 0,
            uidValidity: 1
        )
    }

    static func message(
        id: String,
        account: Account.ID,
        mailbox: Mailbox.ID,
        uid: UInt32,
        date: Date = Date(),
        subject: String = "Subject",
        threadID: MessageThread.ID? = nil,
        importance: Importance = .unknown
    ) -> Message {
        Message(
            id: .init(id),
            accountID: account,
            mailboxID: mailbox,
            uid: uid,
            messageID: "\(id)@test",
            threadID: threadID,
            subject: subject,
            from: MailAddress(address: "sender@example.com", name: "Sender"),
            to: [MailAddress(address: "user@example.com", name: nil)],
            cc: [],
            date: date,
            preview: "preview",
            size: 1024,
            flags: [.seen],
            importance: importance
        )
    }
}

final class GRDBMetadataStoreTests: XCTestCase {

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

    func testMigrationCreatesExpectedTables() async throws {
        let tables: Set<String> = try await store.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
            )
            return Set(rows.map { $0["name"] as String })
        }
        XCTAssertTrue(tables.contains("account"))
        XCTAssertTrue(tables.contains("mailbox"))
        XCTAssertTrue(tables.contains("message"))
        XCTAssertTrue(tables.contains("thread"))
        XCTAssertTrue(tables.contains("settings"))
    }

    func testNoBodyColumnsExist() async throws {
        let any = try await store.hasAnyBodyColumn()
        XCTAssertFalse(any)
    }

    func testUpsertAndQueryMessages() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)

        let now = Date()
        let messages = (0..<5).map { i in
            TestFactory.message(
                id: "m\(i)",
                account: account.id,
                mailbox: mailbox.id,
                uid: UInt32(100 + i),
                date: now.addingTimeInterval(Double(i))
            )
        }
        try await store.upsert(messages)

        let fetched = try await store.messages(in: mailbox.id, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(fetched.count, 5)
        XCTAssertEqual(fetched.first?.id, .init("m4"))
        XCTAssertEqual(fetched.last?.id, .init("m0"))
    }

    func testUpsertIsIdempotentAndUpdates() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)

        var msg = TestFactory.message(
            id: "m1", account: account.id, mailbox: mailbox.id, uid: 1, subject: "v1"
        )
        try await store.upsert([msg])

        msg = TestFactory.message(
            id: "m1", account: account.id, mailbox: mailbox.id, uid: 1,
            subject: "v2", importance: .important
        )
        try await store.upsert([msg])

        let fetched = try await store.messages(in: mailbox.id, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.subject, "v2")
        XCTAssertEqual(fetched.first?.importance, .important)
    }

    func testPagination() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)

        let base = Date()
        let messages = (0..<25).map { i in
            TestFactory.message(
                id: "m\(i)", account: account.id, mailbox: mailbox.id,
                uid: UInt32(i), date: base.addingTimeInterval(Double(i))
            )
        }
        try await store.upsert(messages)

        let page1 = try await store.messages(in: mailbox.id, page: Page(offset: 0, limit: 10))
        let page2 = try await store.messages(in: mailbox.id, page: Page(offset: 10, limit: 10))
        let page3 = try await store.messages(in: mailbox.id, page: Page(offset: 20, limit: 10))
        XCTAssertEqual(page1.count, 10)
        XCTAssertEqual(page2.count, 10)
        XCTAssertEqual(page3.count, 5)
        XCTAssertTrue(Set(page1.map(\.id)).isDisjoint(with: Set(page2.map(\.id))))
    }

    func testDeleteRemovesMessages() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)

        let messages = (0..<3).map { i in
            TestFactory.message(id: "m\(i)", account: account.id, mailbox: mailbox.id, uid: UInt32(i))
        }
        try await store.upsert(messages)
        try await store.delete(messageIDs: [.init("m0"), .init("m2")])

        let remaining = try await store.messages(in: mailbox.id, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, .init("m1"))
    }

    func testCascadeDeleteOnAccount() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)
        let msg = TestFactory.message(id: "m0", account: account.id, mailbox: mailbox.id, uid: 1)
        try await store.upsert([msg])

        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [account.id.rawValue])
        }

        let mailboxCount = try await store.mailboxCount(accountID: account.id)
        let msgCount = try await store.messageCount(in: mailbox.id)
        XCTAssertEqual(mailboxCount, 0)
        XCTAssertEqual(msgCount, 0)
    }

    func testThreadUpsertAndLink() async throws {
        let account = TestFactory.account()
        try await store.upsert(account)
        let mailbox = TestFactory.inbox(account: account.id)
        try await store.upsert(mailbox)

        let threadID = MessageThread.ID("t1")
        let thread = MessageThread(
            id: threadID, accountID: account.id,
            subject: "Tread", messageIDs: [.init("m1"), .init("m2")],
            lastDate: Date()
        )
        try await store.upsert(thread)

        let msg = TestFactory.message(
            id: "m1", account: account.id, mailbox: mailbox.id, uid: 1, threadID: threadID
        )
        try await store.upsert([msg])

        let fetched = try await store.messages(in: mailbox.id, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(fetched.first?.threadID, threadID)
    }

    func testWalAndForeignKeysArePragmasSet() async throws {
        let (journal, fk): (String, Int) = try await store.pool.read { db in
            let j = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
            let f = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
            return (j, f)
        }
        XCTAssertEqual(journal.lowercased(), "wal")
        XCTAssertEqual(fk, 1)
    }

    func testAccountRoundTrip() async throws {
        let account = TestFactory.account(id: "acc-42")
        try await store.upsert(account)
        let fetched = try await store.account(id: account.id)
        XCTAssertEqual(fetched?.email, "user@example.com")
        XCTAssertEqual(fetched?.port, 993)
        XCTAssertEqual(fetched?.kind, .imap)
    }
}
#endif
