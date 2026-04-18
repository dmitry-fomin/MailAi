#if canImport(XCTest)
import XCTest
import Foundation
import GRDB
import Core
@testable import Storage

final class RetentionGCTests: XCTestCase {

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

    private func seedAccount() async throws -> Account {
        let account = TestFactory.account()
        try await store.upsert(account)
        try await store.upsert(TestFactory.inbox(account: account.id))
        return account
    }

    private func seedThread(id: String, account: Account.ID, lastDate: Date) async throws -> MessageThread.ID {
        let threadID = MessageThread.ID(id)
        try await store.upsert(MessageThread(
            id: threadID, accountID: account,
            subject: "t", messageIDs: [], lastDate: lastDate
        ))
        return threadID
    }

    func testDeletesMessagesOlderThan6Months() async throws {
        let account = try await seedAccount()
        let now = Date()
        let old = Calendar.current.date(byAdding: .month, value: -7, to: now)!
        let recent = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        let tOld = try await seedThread(id: "t-old", account: account.id, lastDate: old)
        let tRecent = try await seedThread(id: "t-recent", account: account.id, lastDate: recent)

        let oldMsg = TestFactory.message(
            id: "old", account: account.id, mailbox: .init("mb-inbox"),
            uid: 1, date: old, threadID: tOld
        )
        let recentMsg = TestFactory.message(
            id: "recent", account: account.id, mailbox: .init("mb-inbox"),
            uid: 2, date: recent, threadID: tRecent
        )
        try await store.upsert([oldMsg, recentMsg])

        let gc = RetentionGC(pool: store.pool)
        let deleted = try await gc.run(now: now)
        XCTAssertEqual(deleted, 1)

        let survivors = try await store.messageCount(in: .init("mb-inbox"))
        XCTAssertEqual(survivors, 1)
    }

    func testPreservesThreadsWithRecentMessages() async throws {
        let account = try await seedAccount()
        let now = Date()
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let recent = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        let threadID = try await seedThread(id: "t-live", account: account.id, lastDate: recent)
        let oldInLive = TestFactory.message(
            id: "old-in-live", account: account.id, mailbox: .init("mb-inbox"),
            uid: 1, date: yearAgo, threadID: threadID
        )
        let recentInLive = TestFactory.message(
            id: "recent-in-live", account: account.id, mailbox: .init("mb-inbox"),
            uid: 2, date: recent, threadID: threadID
        )
        try await store.upsert([oldInLive, recentInLive])

        let deleted = try await RetentionGC(pool: store.pool).run(now: now)
        XCTAssertEqual(deleted, 0, "Old message in live thread should be preserved")

        let remaining = try await store.messageCount(in: .init("mb-inbox"))
        XCTAssertEqual(remaining, 2)
    }

    func testDeletesDeadThreadsEntirely() async throws {
        let account = try await seedAccount()
        let now = Date()
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let eightMonthsAgo = Calendar.current.date(byAdding: .month, value: -8, to: now)!

        let threadID = try await seedThread(id: "t-dead", account: account.id, lastDate: eightMonthsAgo)
        let m1 = TestFactory.message(
            id: "d1", account: account.id, mailbox: .init("mb-inbox"),
            uid: 1, date: yearAgo, threadID: threadID
        )
        let m2 = TestFactory.message(
            id: "d2", account: account.id, mailbox: .init("mb-inbox"),
            uid: 2, date: eightMonthsAgo, threadID: threadID
        )
        try await store.upsert([m1, m2])

        let deleted = try await RetentionGC(pool: store.pool).run(now: now)
        XCTAssertEqual(deleted, 2)
    }

    func testNullThreadOldMessagesAreDeleted() async throws {
        let account = try await seedAccount()
        let now = Date()
        let old = Calendar.current.date(byAdding: .month, value: -9, to: now)!
        let noThread = TestFactory.message(
            id: "no-t", account: account.id, mailbox: .init("mb-inbox"),
            uid: 1, date: old, threadID: nil
        )
        try await store.upsert([noThread])
        let deleted = try await RetentionGC(pool: store.pool).run(now: now)
        XCTAssertEqual(deleted, 1)
    }

    func testConfigurableRetention() async throws {
        let account = try await seedAccount()
        let now = Date()
        let threeMonths = Calendar.current.date(byAdding: .month, value: -3, to: now)!
        let msg = TestFactory.message(
            id: "m", account: account.id, mailbox: .init("mb-inbox"),
            uid: 1, date: threeMonths, threadID: nil
        )
        try await store.upsert([msg])

        // 6-month retention: message stays (3 < 6)
        let sixMonthsDeleted = try await RetentionGC(pool: store.pool, retentionMonths: 6).run(now: now)
        XCTAssertEqual(sixMonthsDeleted, 0)
        // 1-month retention: message gone (3 > 1)
        let oneMonthDeleted = try await RetentionGC(pool: store.pool, retentionMonths: 1).run(now: now)
        XCTAssertEqual(oneMonthDeleted, 1)
    }
}
#endif
