#if canImport(XCTest)
import XCTest
@testable import MailTransport

final class IMAPFetchParserTests: XCTestCase {

    func testTokenizerParsesAtoms() throws {
        let tokens = try IMAPValueTokenizer.parse("UID 12345 FLAGS")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0], .atom("UID"))
        XCTAssertEqual(tokens[1], .number(12345))
        XCTAssertEqual(tokens[2], .atom("FLAGS"))
    }

    func testTokenizerParsesQuotedWithEscapes() throws {
        let tokens = try IMAPValueTokenizer.parse("\"hello \\\"world\\\"\" \"a\\\\b\"")
        XCTAssertEqual(tokens, [.quoted("hello \"world\""), .quoted("a\\b")])
    }

    func testTokenizerParsesNil() throws {
        let tokens = try IMAPValueTokenizer.parse("NIL nil Nil")
        XCTAssertEqual(tokens, [.nilValue, .nilValue, .nilValue])
    }

    func testTokenizerParsesNestedLists() throws {
        let tokens = try IMAPValueTokenizer.parse("((a b) (c (d e)) NIL)")
        guard case .list(let outer) = tokens[0] else { XCTFail("expected list"); return }
        XCTAssertEqual(outer.count, 3)
    }

    func testTokenizerParsesLiteral() throws {
        let input = "{5}\r\nhello"
        let tokens = try IMAPValueTokenizer.parse(input)
        XCTAssertEqual(tokens, [.literal("hello")])
    }

    func testTokenizerHandlesLiteralWithNewlines() throws {
        let input = "{12}\r\nline1\r\nline2"
        let tokens = try IMAPValueTokenizer.parse(input)
        XCTAssertEqual(tokens, [.literal("line1\r\nline2")])
    }

    func testFlagsParseSystemFlags() {
        let parsed = IMAPMessageFlags.parse(["\\Seen", "\\Flagged", "$Important"])
        XCTAssertTrue(parsed.system.contains(.seen))
        XCTAssertTrue(parsed.system.contains(.flagged))
        XCTAssertEqual(parsed.keywords, ["$Important"])
    }

    func testFetchUIDOnly() throws {
        let raw = "1 FETCH (UID 4321)"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.sequenceNumber, 1)
        XCTAssertEqual(r.uid, 4321)
    }

    func testFetchFlagsAndSize() throws {
        let raw = "12 FETCH (FLAGS (\\Seen \\Answered) RFC822.SIZE 4096 UID 998877)"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.sequenceNumber, 12)
        XCTAssertEqual(r.uid, 998877)
        XCTAssertEqual(r.rfc822Size, 4096)
        XCTAssertTrue(r.flags.contains(.seen))
        XCTAssertTrue(r.flags.contains(.answered))
    }

    func testFetchInternalDate() throws {
        let raw = "5 FETCH (INTERNALDATE \"17-Apr-2026 10:30:42 +0300\" UID 100)"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.internalDate, "17-Apr-2026 10:30:42 +0300")
        XCTAssertEqual(r.uid, 100)
    }

    // ENVELOPE tests across providers/edge-cases

    func testEnvelopeSimpleGmail() throws {
        let raw = "* 1 FETCH (UID 1 ENVELOPE (\"Tue, 17 Apr 2026 10:30:42 +0300\" \"Hello\" ((\"Alice\" NIL \"alice\" \"gmail.com\")) ((\"Alice\" NIL \"alice\" \"gmail.com\")) ((\"Alice\" NIL \"alice\" \"gmail.com\")) ((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<msg-1@gmail.com>\"))"
        let untagged = IMAPUntaggedResponse(raw: String(raw.dropFirst(2)))
        let r = try IMAPFetchResponse.parse(untagged)
        XCTAssertEqual(r.envelope?.subject, "Hello")
        XCTAssertEqual(r.envelope?.from.first?.address, "alice@gmail.com")
        XCTAssertEqual(r.envelope?.to.first?.address, "bob@example.com")
        XCTAssertEqual(r.envelope?.messageID, "<msg-1@gmail.com>")
    }

    func testEnvelopeYandexCyrillicEncoded() throws {
        let raw = "1 FETCH (ENVELOPE (\"Wed, 16 Apr 2026 12:00:00 +0300\" \"=?UTF-8?B?0J/RgNC40LLQtdGCINC80LjRgA==?=\" ((\"=?utf-8?B?0J7Qu9C10LM=?=\" NIL \"oleg\" \"yandex.ru\")) NIL NIL ((NIL NIL \"team\" \"yandex.ru\")) NIL NIL NIL \"<a@yandex.ru>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.subject, "Привет мир")
        XCTAssertEqual(r.envelope?.from.first?.address, "oleg@yandex.ru")
        XCTAssertEqual(r.envelope?.to.first?.mailbox, "team")
    }

    func testEnvelopeMailRuQEncoded() throws {
        let raw = "2 FETCH (ENVELOPE (\"Thu, 10 Apr 2026 09:15:00 +0300\" \"=?utf-8?Q?Re=3A_=D0=A2=D0=B5=D1=81=D1=82?=\" ((\"=?utf-8?Q?=D0=98=D0=B2=D0=B0=D0=BD?=\" NIL \"ivan\" \"mail.ru\")) NIL NIL ((NIL NIL \"support\" \"mail.ru\")) NIL NIL \"<prev@mail.ru>\" \"<x@mail.ru>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.subject, "Re: Тест")
        XCTAssertEqual(r.envelope?.from.first?.name, "Иван")
        XCTAssertEqual(r.envelope?.inReplyTo, "<prev@mail.ru>")
        XCTAssertEqual(r.envelope?.messageID, "<x@mail.ru>")
    }

    func testEnvelopeMultipleRecipients() throws {
        let raw = "3 FETCH (ENVELOPE (NIL \"Group msg\" ((\"S\" NIL \"s\" \"x.com\")) ((\"S\" NIL \"s\" \"x.com\")) ((\"S\" NIL \"s\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")(\"B\" NIL \"b\" \"x.com\")(\"C\" NIL \"c\" \"x.com\")) ((\"D\" NIL \"d\" \"y.com\")) NIL NIL \"<g1@x.com>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.to.count, 3)
        XCTAssertEqual(r.envelope?.cc.count, 1)
        XCTAssertNil(r.envelope?.date)
    }

    func testEnvelopeAllNilExceptSubject() throws {
        let raw = "4 FETCH (ENVELOPE (NIL \"Just subject\" NIL NIL NIL NIL NIL NIL NIL NIL))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.subject, "Just subject")
        XCTAssertTrue(r.envelope?.from.isEmpty == true)
        XCTAssertNil(r.envelope?.messageID)
    }

    func testEnvelopeSubjectWithEscapedQuote() throws {
        let raw = "5 FETCH (ENVELOPE (NIL \"a \\\"quoted\\\" word\" NIL NIL NIL NIL NIL NIL NIL \"<id@x>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.subject, "a \"quoted\" word")
    }

    func testEnvelopeWithLiteralSubject() throws {
        let raw = "6 FETCH (ENVELOPE (\"Mon, 01 Apr 2026 00:00:00 +0000\" {12}\r\nLong subject ((\"X\" NIL \"x\" \"a.io\")) NIL NIL ((\"Y\" NIL \"y\" \"a.io\")) NIL NIL NIL \"<id@a.io>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.subject, "Long subject")
    }

    func testEnvelopeFastMail() throws {
        let raw = "7 FETCH (UID 555 FLAGS (\\Seen) ENVELOPE (\"Sun, 14 Apr 2026 08:00:00 +0000\" \"FastMail digest\" ((\"FastMail\" NIL \"noreply\" \"fastmail.com\")) ((\"FastMail\" NIL \"noreply\" \"fastmail.com\")) NIL ((\"User\" NIL \"user\" \"fastmail.com\")) NIL NIL NIL \"<digest-001@fastmail.com>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.uid, 555)
        XCTAssertTrue(r.flags.contains(.seen))
        XCTAssertEqual(r.envelope?.from.first?.host, "fastmail.com")
    }

    // BODYSTRUCTURE

    func testBodyStructureSimplePlainText() throws {
        let raw = "1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 2279 48))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        guard case .singlePart(let part) = r.bodyStructure! else { XCTFail("expected single"); return }
        XCTAssertEqual(part.mimeType, "text/plain")
        XCTAssertEqual(part.parameters["charset"], "UTF-8")
        XCTAssertEqual(part.size, 2279)
        XCTAssertEqual(part.encoding, "7BIT")
    }

    func testBodyStructureMultipartAlternative() throws {
        let raw = "1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 5)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 500 12) \"ALTERNATIVE\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        guard case .multiPart(let mp) = r.bodyStructure! else { XCTFail("expected mp"); return }
        XCTAssertEqual(mp.subtype, "ALTERNATIVE")
        XCTAssertEqual(mp.parts.count, 2)
    }

    func testBodyStructureMixedWithAttachment() throws {
        let raw = "1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 4)(\"APPLICATION\" \"PDF\" (\"NAME\" \"doc.pdf\") NIL NIL \"BASE64\" 12345 NIL) \"MIXED\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        guard case .multiPart(let mp) = r.bodyStructure! else { XCTFail("expected mp"); return }
        XCTAssertEqual(mp.subtype, "MIXED")
        XCTAssertEqual(mp.parts.count, 2)
        guard case .singlePart(let pdf) = mp.parts[1] else { XCTFail("expected pdf"); return }
        XCTAssertEqual(pdf.mimeType, "application/pdf")
        XCTAssertEqual(pdf.parameters["name"], "doc.pdf")
        XCTAssertEqual(pdf.encoding, "BASE64")
    }

    func testBodyStructureNestedMultipart() throws {
        let raw = "1 FETCH (BODYSTRUCTURE (((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 50 2)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 200 8) \"ALTERNATIVE\")(\"IMAGE\" \"PNG\" (\"NAME\" \"a.png\") NIL NIL \"BASE64\" 9000 NIL) \"MIXED\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        guard case .multiPart(let mixed) = r.bodyStructure! else { XCTFail("expected mp"); return }
        XCTAssertEqual(mixed.subtype, "MIXED")
        XCTAssertEqual(mixed.parts.count, 2)
        guard case .multiPart(let alt) = mixed.parts[0] else { XCTFail("expected alt"); return }
        XCTAssertEqual(alt.subtype, "ALTERNATIVE")
        XCTAssertEqual(alt.parts.count, 2)
    }

    func testCombinedFetchGmail() throws {
        let raw = "10 FETCH (UID 99 FLAGS (\\Seen) RFC822.SIZE 1024 INTERNALDATE \"01-Jan-2026 12:00:00 +0000\" ENVELOPE (\"Wed, 01 Jan 2026 12:00:00 +0000\" \"Hi\" ((\"A\" NIL \"a\" \"g.com\")) ((\"A\" NIL \"a\" \"g.com\")) ((\"A\" NIL \"a\" \"g.com\")) ((\"B\" NIL \"b\" \"g.com\")) NIL NIL NIL \"<x@g.com>\") BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 100 5))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.uid, 99)
        XCTAssertEqual(r.rfc822Size, 1024)
        XCTAssertEqual(r.internalDate, "01-Jan-2026 12:00:00 +0000")
        XCTAssertEqual(r.envelope?.subject, "Hi")
        XCTAssertNotNil(r.bodyStructure)
    }

    func testFlagsResponseUntagged() throws {
        let untagged = IMAPUntaggedResponse(raw: "20 FETCH (FLAGS (\\Deleted \\Seen $Forwarded))")
        let r = try IMAPFetchResponse.parse(untagged)
        XCTAssertTrue(r.flags.contains(.deleted))
        XCTAssertTrue(r.flags.contains(.seen))
        XCTAssertEqual(r.keywords, ["$Forwarded"])
    }

    func testMalformedFetchThrows() {
        XCTAssertThrowsError(try IMAPFetchResponse.parse(raw: "garbage line"))
        XCTAssertThrowsError(try IMAPFetchResponse.parse(raw: "1 NOTFETCH (UID 1)"))
    }

    func testHeaderDecoderQuotedPrintable() {
        let s = IMAPHeaderDecoder.decode("=?utf-8?Q?caf=C3=A9?=")
        XCTAssertEqual(s, "café")
    }

    func testHeaderDecoderBase64() {
        let s = IMAPHeaderDecoder.decode("=?UTF-8?B?0J/RgNC40LLQtdGC?=")
        XCTAssertEqual(s, "Привет")
    }

    func testHeaderDecoderMixedWords() {
        let s = IMAPHeaderDecoder.decode("=?utf-8?Q?Hello?= =?utf-8?Q?_World?=")
        XCTAssertEqual(s, "Hello World")
    }

    func testAddressGroupSyntaxIgnored() throws {
        let raw = "1 FETCH (ENVELOPE (NIL \"x\" ((\"A\" NIL \"a\" \"x.com\")) NIL NIL ((NIL NIL \"undisclosed-recipients\" NIL)) NIL NIL NIL \"<m@x>\"))"
        let r = try IMAPFetchResponse.parse(raw: raw)
        XCTAssertEqual(r.envelope?.to.first?.mailbox, "undisclosed-recipients")
        XCTAssertNil(r.envelope?.to.first?.host)
    }

    func testParserParsesUntagged() {
        let line = IMAPParser.parse("* OK Hello")
        if case .untagged(let u) = line { XCTAssertEqual(u.kind, "OK") } else { XCTFail() }
    }
}
#endif
