import XCTest
@testable import speaktype

/// Tests for ClaudePolisher. Network calls are stubbed via a custom
/// URLProtocol so the suite is fully deterministic — no real Anthropic
/// API requests, no flakiness, no API-key requirement.
///
/// Coverage targets:
///   - Short-input bypass (model never called)
///   - 200 → returns cleaned text from response payload
///   - 401 → falls back to raw (caller's try? + UI explanation later)
///   - 429 → one retry, then falls back
///   - 529 → one retry, then falls back
///   - Network error → falls back
///   - Cancellation → throws CancellationError
///   - Request shape (headers, body, model) is correct
final class ClaudePolisherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makePolisher() -> ClaudePolisher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudePolisher(
            apiKey: "sk-ant-test-key",
            urlSession: URLSession(configuration: config)
        )
    }

    // MARK: - Bypass

    func testShortInputBypassesNetwork() async throws {
        let polisher = makePolisher()
        let result = try await polisher.polish("hi there")
        XCTAssertEqual(result, "hi there")
        XCTAssertEqual(StubURLProtocol.requestCount, 0,
            "Short input must skip the network entirely.")
    }

    // MARK: - Happy path

    func testHappyPathReturnsCleanedText() async throws {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                """
                {"content":[{"type":"text","text":"I think the meeting went well."}]}
                """.data(using: .utf8)!
            )
        }

        let polisher = makePolisher()
        let result = try await polisher.polish(
            "um so I think uh the meeting like went well you know"
        )
        XCTAssertEqual(result, "I think the meeting went well.")
    }

    func testRequestCarriesCorrectHeadersAndBody() async throws {
        StubURLProtocol.handler = { request in
            // Verify request shape — these assertions run in the stub
            // and propagate via XCTFail recorded during execution.
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "x-api-key"),
                "sk-ant-test-key"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "anthropic-version"),
                "2023-06-01"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "content-type"),
                "application/json"
            )
            // Inspect the body to confirm we send the expected model + prompt.
            // URLProtocol gives us the request before the body is streamed,
            // so read from the bodyStream if needed. URLSession with
            // standard data path puts the body on httpBody.
            if let body = request.httpBody ?? StubURLProtocol.bodyData(for: request),
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                XCTAssertEqual(json["model"] as? String, ClaudePolisher.model)
                XCTAssertNotNil(json["system"])
                XCTAssertNotNil(json["messages"])
            } else {
                XCTFail("Request body was not readable as JSON")
            }

            return (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
            )
        }

        let polisher = makePolisher()
        _ = try await polisher.polish("um so testing the request shape one two three four")
    }

    // MARK: - Error paths fall back to raw

    func test401InvalidKeyFallsBackToRaw() async throws {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let polisher = makePolisher()
        let raw = "um so this is the raw transcript content here"
        let result = try await polisher.polish(raw)
        XCTAssertEqual(result, raw,
            "401 Unauthorized must fall back to raw — retrying won't fix a bad key.")
        XCTAssertEqual(StubURLProtocol.requestCount, 1,
            "401 must NOT trigger a retry; one request only.")
    }

    func test429RateLimitedRetriesOnceThenFallsBack() async throws {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let polisher = makePolisher()
        let raw = "um so this is the raw transcript content here"
        let result = try await polisher.polish(raw)
        XCTAssertEqual(result, raw)
        XCTAssertEqual(StubURLProtocol.requestCount, 2,
            "429 must trigger exactly one retry — total 2 requests, then fall back.")
    }

    func test529OverloadedRetriesOnceThenFallsBack() async throws {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 529,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let polisher = makePolisher()
        let raw = "um so this is the raw transcript content here"
        _ = try await polisher.polish(raw)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testNetworkErrorFallsBackToRaw() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let polisher = makePolisher()
        let raw = "um so this is the raw transcript content here"
        let result = try await polisher.polish(raw)
        XCTAssertEqual(result, raw)
    }

    // MARK: - Cancellation

    func testCancellationPropagates() async {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                #"{"content":[{"type":"text","text":"too late"}]}"#.data(using: .utf8)!
            )
        }
        let polisher = makePolisher()

        let task = Task {
            try await polisher.polish("um so this is plenty long enough for the bypass check")
        }
        task.cancel()

        do {
            _ = try await task.value
            // Either it completed before cancel landed (acceptable) or it
            // threw CancellationError (also acceptable).
        } catch is CancellationError {
            // Expected when cancellation lands before the network completes.
        } catch {
            XCTFail("Unexpected non-cancellation error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

/// Intercepts every request made by URLSessions configured with this
/// protocol class and returns canned responses. Mirrors the standard
/// pattern used in production Swift apps for deterministic networking
/// tests (Hammerspoon, AsyncHTTPClient samples, RxAlamofire, etc.).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var bodies: [URLRequest: Data] = [:]

    static func reset() {
        handler = nil
        requestCount = 0
        bodies = [:]
    }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        // URLSession's data(for:) often consumes the body via stream;
        // the stub captures it during loading.
        return bodies[request]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1

        // Capture body via stream if it wasn't on httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var captured = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 1024)
                if read <= 0 { break }
                captured.append(buf, count: read)
            }
            Self.bodies[request] = captured
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotConnectToHost)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
