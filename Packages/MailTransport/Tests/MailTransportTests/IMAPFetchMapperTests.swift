#if canImport(XCTest)
import XCTest
import Core
import Storage
@testable import MailTransport

final class IMAPFetchMapperTests: XCTestCase {
    let accountID = Account.ID("acc-1")
    let mailboxID = Mailbox.ID("INBOX")

    func testMapsBasicFetchToMessage() throws {
        let raw = "10 FETCH (UID 99 FLAGS (\\Seen) RFC822.SIZE 1024 INTERNALDATE \"01-Jan-2026 12:00:00 +0000\" ENVELOPE (\"Wed, 01 Jan 2026 12:00:00 +0000\" \"Hi\" ((\"A\" NIL \"a\" \"g.com\")) ((\"A\" NIL \"a\" \"g.com\")) ((\"A\" NIL \"a\" \"g.com\")) ((\"B\" NIL \"b\" \"g.com\")) NIL NIL NIL \"<x@g.com>\") BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 5))"
        let fetch = try IMAPFetchResponse.parse(raw: raw)
        let msg = try XCTUnwrap(IMAPFetchMapper.toMessage(fetch, accountID: accountID, mailboxID: mailboxID))

        XCTAssertEqual(msg.uid, 99)
        XCTAssertEqual(msg.subject, "Hi")
        XCTAssertEqual(msg.size, 1024)
        XCTAssertEqual(msg.from?.address, "a@g.com")
        XCTAssertEqual(msg.from?.name, "A")
        XCTAssertEqual(msg.to.first?.address, "b@g.com")
        XCTAssertEqual(msg.messageID, "<x@g.com>")
        XCTAssertTrue(msg.flags.contains(.seen))
        XCTAssertFalse(msg.flags.contains(.hasAttachment))
    }

    func testReturnsNilWithoutUID() throws {
        let raw = "1 FETCH (FLAGS (\\Seen))"
        let fetch = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertNil(IMAPFetchMapper.toMessage(fetch, accountID: accountID, mailboxID: mailboxID))
    }

    func testAttachmentFlagFromBodyStructure() throws {
        let raw = "1 FETCH (UID 5 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 4)(\"APPLICATION\" \"PDF\" (\"NAME\" \"doc.pdf\") NIL NIL \"BASE64\" 12345 NIL) \"MIXED\"))"
        let fetch = try IMAPFetchResponse.parse(raw: raw)
        let msg = try XCTUnwrap(IMAPFetchMapper.toMessage(fetch, accountID: accountID, mailboxID: mailboxID))
        XCTAssertTrue(msg.flags.contains(.hasAttachment))
    }

    func testInternalDateParsed() throws {
        let raw = "1 FETCH (UID 1 INTERNALDATE \"17-Apr-2026 10:30:42 +0000\")"
        let fetch = try IMAPFetchResponse.parse(raw: raw)
        let msg = try XCTUnwrap(IMAPFetchMapper.toMessage(fetch, accountID: accountID, mailboxID: mailboxID))
        let expected = IMAPFetchMapper.parseInternalDate("17-Apr-2026 10:30:42 +0000")!
        XCTAssertEqual(msg.date, expected)
    }

    func testUIDFetchCommandFormatting() {
        XCTAssertEqual(IMAPFetchAttributes.uidFetchCommand(range: .all),
                       "UID FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)")
        XCTAssertEqual(IMAPFetchAttributes.uidFetchCommand(range: .range(100...200)),
                       "UID FETCH 100:200 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)")
    }

    func testBatchUpsertIntoInMemoryStore() async throws {
        let rawLines = [
            "1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE \"01-Apr-2026 10:00:00 +0000\" ENVELOPE (NIL \"a\" ((\"X\" NIL \"x\" \"m\")) NIL NIL ((\"Y\" NIL \"y\" \"m\")) NIL NIL NIL \"<1@m>\"))",
            "2 FETCH (UID 2 FLAGS () INTERNALDATE \"02-Apr-2026 10:00:00 +0000\" ENVELOPE (NIL \"b\" ((\"X\" NIL \"x\" \"m\")) NIL NIL ((\"Y\" NIL \"y\" \"m\")) NIL NIL NIL \"<2@m>\"))",
            "3 FETCH (UID 3 FLAGS (\\Flagged) INTERNALDATE \"03-Apr-2026 10:00:00 +0000\" ENVELOPE (NIL \"c\" ((\"X\" NIL \"x\" \"m\")) NIL NIL ((\"Y\" NIL \"y\" \"m\")) NIL NIL NIL \"<3@m>\"))"
        ]
        let fetches = try rawLines.map { try IMAPFetchResponse.parse(raw: $0) }
        let messages = fetches.compactMap {
            IMAPFetchMapper.toMessage($0, accountID: accountID, mailboxID: mailboxID)
        }
        XCTAssertEqual(messages.count, 3)

        let store = InMemoryMetadataStore()
        try await store.upsert(messages)
        let got = try await store.messages(in: mailboxID, page: Page(offset: 0, limit: 100))
        XCTAssertEqual(got.count, 3)
    }
}
#endif
