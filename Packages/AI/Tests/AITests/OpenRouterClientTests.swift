#if canImport(XCTest)
import XCTest
import Foundation
@testable import AI

/// URLProtocol-мок, перехватывающий запросы к OpenRouter и отдающий подготовленные ответы.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (data, response) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OpenRouterClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.responder = nil
    }

    func testSendsCorrectHeadersAndBody() async throws {
        let captured = RequestCapture()
        MockURLProtocol.responder = { request in
            captured.capture(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: nil)!
            return (Self.nonStreamBody("ok"), response)
        }
        let client = OpenRouterClient(apiKey: "secret-key", model: "test/model", session: session)
        var output = ""
        for try await chunk in client.complete(system: "sys", user: "usr", streaming: false) {
            output += chunk
        }
        XCTAssertEqual(output, "ok")

        let req = captured.request!
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "MailAi")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "HTTP-Referer"))

        let body = try XCTUnwrap(captured.bodyJSON)
        XCTAssertEqual(body["model"] as? String, "test/model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "sys")
        XCTAssertEqual(messages[1]["role"], "user")
    }

    func testStreamingParsesSSEChunks() async throws {
        let sse = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" "}}]}

            data: {"choices":[{"delta":{"content":"world"}}]}

            data: [DONE]


            """
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (sse.data(using: .utf8)!, response)
        }
        let client = OpenRouterClient(apiKey: "k", model: "m", session: session)
        var chunks: [String] = []
        for try await chunk in client.complete(system: "s", user: "u", streaming: true) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["Hello", " ", "world"])
    }

    func testNonStreamingReturnsSingleChunk() async throws {
        MockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: nil)!
            return (Self.nonStreamBody("full text"), response)
        }
        let client = OpenRouterClient(apiKey: "k", model: "m", session: session)
        var output = ""
        for try await chunk in client.complete(system: "s", user: "u", streaming: false) {
            output += chunk
        }
        XCTAssertEqual(output, "full text")
    }

    func testMapsHTTPStatusToErrors() async {
        let cases: [(Int, OpenRouterError)] = [
            (401, .unauthorized),
            (402, .paymentRequired),
            (429, .rateLimited),
            (500, .serverError(500)),
            (503, .serverError(503)),
            (418, .httpError(418))
        ]
        for (status, expected) in cases {
            MockURLProtocol.responder = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                               headerFields: nil)!
                return (Data(), response)
            }
            let client = OpenRouterClient(apiKey: "k", model: "m", session: session)
            do {
                for try await _ in client.complete(system: "s", user: "u", streaming: false) {}
                XCTFail("Expected error for status \(status)")
            } catch let error as OpenRouterError {
                XCTAssertEqual(error, expected, "status \(status)")
            } catch {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private static func nonStreamBody(_ content: String) -> Data {
        let json = """
            {
                "choices": [
                    {"message": {"content": "\(content)"}}
                ]
            }
            """
        return json.data(using: .utf8)!
    }

    private final class RequestCapture: @unchecked Sendable {
        var request: URLRequest?
        var bodyJSON: [String: Any]?
        func capture(_ req: URLRequest) {
            request = req
            if let data = req.httpBody ?? Self.readStream(req.httpBodyStream),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodyJSON = json
            }
        }
        private static func readStream(_ stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                out.append(buffer, count: n)
            }
            return out
        }
    }
}
#endif
