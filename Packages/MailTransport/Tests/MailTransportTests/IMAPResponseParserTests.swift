#if canImport(XCTest)
import XCTest
@testable import MailTransport

final class IMAPResponseParserTests: XCTestCase {

    func testParsesUntagged() {
        let line = IMAPParser.parse("* OK Hello there")
        guard case .untagged(let u) = line else {
            XCTFail("Expected untagged"); return
        }
        XCTAssertEqual(u.raw, "OK Hello there")
        XCTAssertEqual(u.kind, "OK")
    }

    func testParsesTaggedOK() {
        let line = IMAPParser.parse("a001 OK CAPABILITY completed")
        guard case .tagged(let t) = line else {
            XCTFail("Expected tagged"); return
        }
        XCTAssertEqual(t.tag, "a001")
        XCTAssertEqual(t.status, .ok)
        XCTAssertEqual(t.text, "CAPABILITY completed")
    }

    func testParsesTaggedNO() {
        let line = IMAPParser.parse("a002 NO Invalid credentials")
        guard case .tagged(let t) = line else {
            XCTFail("Expected tagged"); return
        }
        XCTAssertEqual(t.status, .no)
    }

    func testParsesContinuation() {
        let line = IMAPParser.parse("+ Ready for literal")
        if case .continuation(let s) = line {
            XCTAssertEqual(s, "Ready for literal")
        } else {
            XCTFail("Expected continuation")
        }
    }

    func testListEntryParsing() {
        let u = IMAPUntaggedResponse(raw: "LIST (\\HasNoChildren \\UnMarked) \"/\" \"INBOX\"")
        let entry = ListEntry.parse(u)
        XCTAssertEqual(entry?.flags, ["\\HasNoChildren", "\\UnMarked"])
        XCTAssertEqual(entry?.delimiter, "/")
        XCTAssertEqual(entry?.path, "INBOX")
    }

    func testListEntryWithNilDelimiter() {
        let u = IMAPUntaggedResponse(raw: "LIST (\\Noselect) NIL \"ROOT\"")
        let entry = ListEntry.parse(u)
        XCTAssertNil(entry?.delimiter)
        XCTAssertEqual(entry?.path, "ROOT")
    }

    func testSelectResultParsing() {
        let untagged = [
            IMAPUntaggedResponse(raw: "FLAGS (\\Answered \\Flagged \\Seen)"),
            IMAPUntaggedResponse(raw: "42 EXISTS"),
            IMAPUntaggedResponse(raw: "3 RECENT"),
            IMAPUntaggedResponse(raw: "OK [UIDVALIDITY 1234567] UIDs valid"),
            IMAPUntaggedResponse(raw: "OK [UIDNEXT 555] Predicted next UID")
        ]
        let result = SelectResult.parse(untagged: untagged, taggedText: "OK [READ-WRITE] SELECT completed")
        XCTAssertEqual(result.exists, 42)
        XCTAssertEqual(result.recent, 3)
        XCTAssertEqual(result.uidValidity, 1234567)
        XCTAssertEqual(result.uidNext, 555)
        XCTAssertEqual(result.flags, ["\\Answered", "\\Flagged", "\\Seen"])
        XCTAssertFalse(result.readOnly)
    }

    func testSelectReadOnly() {
        let result = SelectResult.parse(
            untagged: [IMAPUntaggedResponse(raw: "0 EXISTS")],
            taggedText: "OK [READ-ONLY] EXAMINE completed"
        )
        XCTAssertTrue(result.readOnly)
    }

    func testQuoteEscapesSpecials() {
        XCTAssertEqual(IMAPConnection.quote("hello"), "\"hello\"")
        XCTAssertEqual(IMAPConnection.quote("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(IMAPConnection.quote("a\\b"), "\"a\\\\b\"")
    }

    func testTagGeneratorIsSequential() async {
        let gen = IMAPTagGenerator()
        let t1 = await gen.next()
        let t2 = await gen.next()
        let t3 = await gen.next()
        XCTAssertEqual(t1, "a0001")
        XCTAssertEqual(t2, "a0002")
        XCTAssertEqual(t3, "a0003")
    }
}
#endif
