#if canImport(XCTest)
import XCTest
@testable import MailTransport

final class MIMEHeaderUnfoldTests: XCTestCase {

    func testUnfoldSimpleCRLFWithSpace() {
        let raw = "Subject: a very\r\n long subject\r\nFrom: x@y\r\n"
        let out = MIMEHeaderUnfold.unfold(raw)
        XCTAssertTrue(out.contains("Subject: a very long subject"))
        XCTAssertTrue(out.contains("From: x@y"))
    }

    func testUnfoldWithTab() {
        let raw = "X-Header: part1\r\n\tpart2\r\n"
        let out = MIMEHeaderUnfold.unfold(raw)
        XCTAssertTrue(out.contains("X-Header: part1\tpart2"))
    }

    func testUnfoldMultilineValue() {
        let raw = "Subject: line1\r\n line2\r\n line3\r\n"
        let out = MIMEHeaderUnfold.unfold(raw)
        XCTAssertEqual(
            out.replacingOccurrences(of: "\r", with: ""),
            "Subject: line1 line2 line3\n"
        )
    }

    func testParseDecodesRFC2047() {
        let raw = "Subject: =?UTF-8?B?0J/RgNC40LLQtdGC?=\r\nFrom: a@b\r\n"
        let headers = MIMEHeaderUnfold.parse(raw)
        XCTAssertEqual(MIMEHeaderUnfold.find(headers, name: "subject"), "Привет")
        XCTAssertEqual(MIMEHeaderUnfold.find(headers, name: "From"), "a@b")
    }

    func testParseStructuredValueContentType() {
        let (primary, params) = MIMEHeaderUnfold.parseStructuredValue(
            "multipart/alternative; boundary=\"abc123\"; charset=utf-8"
        )
        XCTAssertEqual(primary, "multipart/alternative")
        XCTAssertEqual(params["boundary"], "abc123")
        XCTAssertEqual(params["charset"], "utf-8")
    }

    func testParseStructuredValueWithQuotedSemicolon() {
        let (primary, params) = MIMEHeaderUnfold.parseStructuredValue(
            "text/plain; charset=\"utf-8; weird\""
        )
        XCTAssertEqual(primary, "text/plain")
        XCTAssertEqual(params["charset"], "utf-8; weird")
    }
}

final class MIMERFC2047Tests: XCTestCase {

    func testQEncodedUTF8() {
        XCTAssertEqual(IMAPHeaderDecoder.decode("=?utf-8?Q?caf=C3=A9?="), "café")
    }

    func testBEncodedUTF8() {
        XCTAssertEqual(IMAPHeaderDecoder.decode("=?UTF-8?B?SGVsbG8gV29ybGQ=?="), "Hello World")
    }

    func testBEncodedKOI8R() {
        // «Привет» в KOI8-R: П=F0, р=D2, и=C9, в=D7, е=C5, т=D4
        let bytes: [UInt8] = [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]
        let b64 = Data(bytes).base64EncodedString()
        let encoded = "=?koi8-r?B?\(b64)?="
        XCTAssertEqual(IMAPHeaderDecoder.decode(encoded), "Привет")
    }

    func testQEncodedWindows1251() {
        // «Тест» в cp1251: D2 E5 F1 F2
        XCTAssertEqual(IMAPHeaderDecoder.decode("=?windows-1251?Q?=D2=E5=F1=F2?="), "Тест")
    }

    func testMixedWordsAndPlainText() {
        let s = IMAPHeaderDecoder.decode("Re: =?utf-8?Q?=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82?= everyone")
        XCTAssertEqual(s, "Re: Привет everyone")
    }

    func testAdjacentEncodedWordsJoined() {
        // По RFC 2047: между соседними encoded-words whitespace удаляется.
        let s = IMAPHeaderDecoder.decode("=?utf-8?Q?Hello?= =?utf-8?Q?_World?=")
        XCTAssertEqual(s, "Hello World")
    }
}

final class MIMECharsetTests: XCTestCase {

    func testUTF8Roundtrip() {
        let bytes = Array("Привет".utf8)
        XCTAssertEqual(MIMECharset.decode(bytes, charset: "utf-8"), "Привет")
    }

    func testCP1251() {
        // Т е с т → D2 E5 F1 F2 в cp1251
        let bytes: [UInt8] = [0xD2, 0xE5, 0xF1, 0xF2]
        XCTAssertEqual(MIMECharset.decode(bytes, charset: "windows-1251"), "Тест")
    }

    func testUnknownCharsetFallsBackToUTF8() {
        let bytes = Array("hello".utf8)
        XCTAssertEqual(MIMECharset.decode(bytes, charset: "x-mystery"), "hello")
    }

    func testNilCharsetDefaultsToUTF8() {
        XCTAssertEqual(MIMECharset.encoding(for: nil), .utf8)
    }
}

final class MIMETransferDecoderTests: XCTestCase {

    func testQuotedPrintableBasic() {
        let dec = MIMEQuotedPrintableDecoder()
        let bytes = Array("Hello=20World=0A".utf8)
        let out = dec.feed(bytes) + dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "Hello World\n")
    }

    func testQuotedPrintableSoftLineBreaks() {
        let dec = MIMEQuotedPrintableDecoder()
        let out = dec.feed(Array("foo=\r\nbar=\nbaz".utf8)) + dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "foobarbaz")
    }

    func testQuotedPrintableSplitAcrossFeeds() {
        let dec = MIMEQuotedPrintableDecoder()
        var out = dec.feed(Array("caf=".utf8))
        out += dec.feed(Array("C3=A9".utf8))
        out += dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "café")
    }

    func testQuotedPrintableUTF8Cyrillic() {
        let dec = MIMEQuotedPrintableDecoder()
        let out = dec.feed(Array("=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82".utf8)) + dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "Привет")
    }

    func testBase64Basic() {
        let dec = MIMEBase64Decoder()
        let out = dec.feed(Array("SGVsbG8gV29ybGQ=".utf8)) + dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "Hello World")
    }

    func testBase64WithCRLFs() {
        let dec = MIMEBase64Decoder()
        let out = dec.feed(Array("SGVs\r\nbG8g\r\nV29y\r\nbGQ=".utf8)) + dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "Hello World")
    }

    func testBase64SplitAcrossFeeds() {
        let dec = MIMEBase64Decoder()
        var out = dec.feed(Array("SGVs".utf8))
        out += dec.feed(Array("bG8=".utf8))
        out += dec.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "Hello")
    }

    func testIdentityPassthrough() {
        let dec = MIMEIdentityDecoder()
        let bytes: [UInt8] = [0x00, 0xFF, 0x7F, 0x80]
        XCTAssertEqual(dec.feed(bytes), bytes)
        XCTAssertEqual(dec.finish(), [])
    }

    func testFactoryPicksQP() {
        let dec = MIMETransferEncoding.decoder(for: "Quoted-Printable")
        XCTAssertTrue(dec is MIMEQuotedPrintableDecoder)
    }

    func testFactoryPicksBase64() {
        let dec = MIMETransferEncoding.decoder(for: "BASE64")
        XCTAssertTrue(dec is MIMEBase64Decoder)
    }

    func testFactoryDefaultsToIdentity() {
        XCTAssertTrue(MIMETransferEncoding.decoder(for: "7bit") is MIMEIdentityDecoder)
        XCTAssertTrue(MIMETransferEncoding.decoder(for: nil) is MIMEIdentityDecoder)
    }
}

final class MIMEStreamParserTests: XCTestCase {

    /// Утилита: скармливает весь message парсеру, собирает события и тела по path.
    private func parse(_ message: String, chunkSize: Int = 64)
        -> (events: [MIMEStreamEvent], bodies: [[Int]: [UInt8]])
    {
        var events: [MIMEStreamEvent] = []
        var bodies: [[Int]: [UInt8]] = [:]
        let parser = MIMEStreamParser { event in
            events.append(event)
            if case .bodyChunk(let path, let bytes) = event {
                bodies[path, default: []].append(contentsOf: bytes)
            }
        }
        let allBytes = Array(message.utf8)
        var i = 0
        while i < allBytes.count {
            let end = min(i + chunkSize, allBytes.count)
            parser.feed(Array(allBytes[i..<end]))
            i = end
        }
        parser.finish()
        return (events, bodies)
    }

    func testSimpleSinglePartPlainText() {
        let msg = "Content-Type: text/plain; charset=utf-8\r\n" +
                  "Content-Transfer-Encoding: 7bit\r\n" +
                  "\r\n" +
                  "Hello, world!\r\n"
        let (events, bodies) = parse(msg)
        // Ждём: partStart(root), bodyChunk..., partEnd(root)
        let starts = events.compactMap { if case .partStart(let p, _) = $0 { return p } else { return nil as [Int]? } }
        XCTAssertEqual(starts, [[]])
        let decoded = String(decoding: bodies[[]] ?? [], as: UTF8.self)
        XCTAssertTrue(decoded.contains("Hello, world!"))
    }

    func testQuotedPrintableBody() {
        let msg = "Content-Type: text/plain; charset=utf-8\r\n" +
                  "Content-Transfer-Encoding: quoted-printable\r\n" +
                  "\r\n" +
                  "=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82\r\n"
        let (_, bodies) = parse(msg, chunkSize: 7)
        let decoded = String(decoding: bodies[[]] ?? [], as: UTF8.self)
        XCTAssertTrue(decoded.contains("Привет"))
    }

    func testBase64Body() {
        let msg = "Content-Type: text/plain\r\n" +
                  "Content-Transfer-Encoding: base64\r\n" +
                  "\r\n" +
                  "SGVsbG8gV29ybGQ=\r\n"
        let (_, bodies) = parse(msg, chunkSize: 5)
        let decoded = String(decoding: bodies[[]] ?? [], as: UTF8.self)
        XCTAssertTrue(decoded.contains("Hello World"))
    }

    func testMultipartAlternative() {
        let msg = "Content-Type: multipart/alternative; boundary=BOUND\r\n" +
                  "\r\n" +
                  "preamble ignored\r\n" +
                  "--BOUND\r\n" +
                  "Content-Type: text/plain; charset=utf-8\r\n" +
                  "\r\n" +
                  "plain version\r\n" +
                  "--BOUND\r\n" +
                  "Content-Type: text/html; charset=utf-8\r\n" +
                  "\r\n" +
                  "<p>html</p>\r\n" +
                  "--BOUND--\r\n"
        let (events, bodies) = parse(msg, chunkSize: 32)
        let starts = events.compactMap { if case .partStart(let p, _) = $0 { return p } else { return nil as [Int]? } }
        XCTAssertEqual(starts, [[], [0], [1]])
        let plain = String(decoding: bodies[[0]] ?? [], as: UTF8.self)
        let html  = String(decoding: bodies[[1]] ?? [], as: UTF8.self)
        XCTAssertTrue(plain.contains("plain version"))
        XCTAssertTrue(html.contains("<p>html</p>"))
    }

    func testNestedMultipart() {
        let msg = "Content-Type: multipart/mixed; boundary=OUT\r\n" +
                  "\r\n" +
                  "--OUT\r\n" +
                  "Content-Type: multipart/alternative; boundary=IN\r\n" +
                  "\r\n" +
                  "--IN\r\n" +
                  "Content-Type: text/plain\r\n" +
                  "\r\n" +
                  "plain\r\n" +
                  "--IN\r\n" +
                  "Content-Type: text/html\r\n" +
                  "\r\n" +
                  "<p>h</p>\r\n" +
                  "--IN--\r\n" +
                  "--OUT\r\n" +
                  "Content-Type: application/octet-stream\r\n" +
                  "Content-Transfer-Encoding: base64\r\n" +
                  "\r\n" +
                  "QUJDRA==\r\n" +
                  "--OUT--\r\n"
        let (events, bodies) = parse(msg, chunkSize: 40)
        let starts = events.compactMap { if case .partStart(let p, _) = $0 { return p } else { return nil as [Int]? } }
        // root, 0 (inner multipart), 0/0 plain, 0/1 html, 1 attachment
        XCTAssertTrue(starts.contains([]))
        XCTAssertTrue(starts.contains([0]))
        XCTAssertTrue(starts.contains([0, 0]))
        XCTAssertTrue(starts.contains([0, 1]))
        XCTAssertTrue(starts.contains([1]))

        let plain = String(decoding: bodies[[0, 0]] ?? [], as: UTF8.self)
        XCTAssertTrue(plain.contains("plain"))
        let attach = bodies[[1]] ?? []
        XCTAssertEqual(String(decoding: attach, as: UTF8.self), "ABCD")
    }

    func testMultipartPartHeadersParsedWithRFC2047() {
        let msg = "Content-Type: multipart/mixed; boundary=B\r\n" +
                  "\r\n" +
                  "--B\r\n" +
                  "Content-Type: text/plain; charset=utf-8\r\n" +
                  "Content-Disposition: attachment; filename=\"=?utf-8?B?0YTQsNC50Lsu0YLRhdGC?=\"\r\n" +
                  "\r\n" +
                  "body\r\n" +
                  "--B--\r\n"
        let (events, _) = parse(msg)
        let partHeaders: [MIMEHeader]? = events.compactMap {
            if case .partStart(let p, let h) = $0, p == [0] { return h } else { return nil }
        }.first
        XCTAssertNotNil(partHeaders)
        let disp = partHeaders?.first { $0.name.lowercased() == "content-disposition" }?.value
        XCTAssertTrue(disp?.contains("файл.тхт") == true, "got: \(disp ?? "nil")")
    }
}
#endif
