// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUIClient
@testable import AGUICore

/// Conformance tests for `basic/transports/http-sse` (plan item B13).
///
/// These run the full `HttpAgent` path over `MockHTTPClient` and assert the
/// transport rules: LF framing, only `data` is meaningful, comments are
/// tolerated, multi-line `data` is joined, a closed connection is never
/// success by itself, no resumption, and bad responses are rejected before
/// `RUN_STARTED` through the transport error.
final class HttpSseTransportConformanceTests: XCTestCase {

    // MARK: - Helpers

    private let baseURL = URL(string: "https://agent.example.com")!

    private let started = #"data: {"type":"RUN_STARTED","threadId":"t1","runId":"r1"}"#
    private let finished = #"data: {"type":"RUN_FINISHED","threadId":"t1","runId":"r1"}"#
    private let runError = #"data: {"type":"RUN_ERROR","message":"boom"}"#

    private func makeInput() throws -> RunAgentInput {
        try RunAgentInput.builder().threadId("t1").runId("r1").build()
    }

    private func makeResponse(
        body: String,
        statusCode: Int = 200,
        contentType: String? = "text/event-stream",
        trailingError: Error? = nil
    ) -> HTTPResponse {
        let bytes = Data(body.utf8)
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish(throwing: trailingError)
        }
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let http = HTTPURLResponse(
            url: URL(string: "https://mock.local")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return HTTPResponse(bytes: stream, httpResponse: http)
    }

    private func makeAgent(
        client: any HTTPClient,
        retryPolicy: HttpAgentConfiguration.RetryPolicy = .none
    ) -> HttpAgent {
        let config = HttpAgentConfiguration(baseURL: baseURL, retryPolicy: retryPolicy)
        return HttpAgent(configuration: config, httpClient: client)
    }

    /// Runs the agent and returns the event type names plus any thrown error.
    private func collect(
        _ agent: HttpAgent
    ) async throws -> (types: [String], error: Error?) {
        var types: [String] = []
        do {
            for try await event in agent.run(input: try makeInput()) {
                types.append(event.eventType.rawValue)
            }
            return (types, nil)
        } catch {
            return (types, error)
        }
    }

    private func clientWith(_ response: HTTPResponse) async -> MockHTTPClient {
        let client = MockHTTPClient()
        await client.setResponse(response)
        return client
    }

    // MARK: - Framing and field handling

    func testLFFramedStreamDecodes() async throws {
        let body = "\(started)\n\n\(finished)\n\n"
        let client = await clientWith(makeResponse(body: body))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"])
    }

    func testCRLFFramedStreamIsStillAccepted() async throws {
        let body = "\(started)\r\n\r\n\(finished)\r\n\r\n"
        let client = await clientWith(makeResponse(body: body))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"])
    }

    func testFieldsOtherThanDataAreIgnored() async throws {
        let body = [
            "event: not-an-ag-ui-type", "id: 7", "retry: 5000", started, "",
            "event: custom", "unknown: field", finished, "", "",
        ].joined(separator: "\n")
        let client = await clientWith(makeResponse(body: body))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"],
                       "The SSE event name must not influence AG-UI dispatch")
    }

    func testCommentLinesAreTolerated() async throws {
        let body = [
            ": keep-alive", "",
            started, ": comment inside an event", "",
            ": another comment between events",
            finished, "", "",
        ].joined(separator: "\n")
        let client = await clientWith(makeResponse(body: body))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"])
    }

    func testMultiLineDataIsJoinedWithNewline() async throws {
        let body = [
            #"data: {"type":"RUN_STARTED","#,
            #"data: "threadId":"t1","#,
            #"data: "runId":"r1"}"#, "",
            finished, "", "",
        ].joined(separator: "\n")
        let client = await clientWith(makeResponse(body: body))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"])
    }

    // MARK: - Closed connection is not success

    func testStreamClosedWithoutTerminalEventIsAnError() async throws {
        let client = await clientWith(makeResponse(body: "\(started)\n\n"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertEqual(result.types, ["RUN_STARTED"])
        XCTAssertNotNil(result.error, "A stream that ends without RUN_FINISHED or RUN_ERROR is not success")
    }

    func testEmptyStreamIsAnError() async throws {
        let client = await clientWith(makeResponse(body: ""))
        let result = try await collect(makeAgent(client: client))
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertNotNil(result.error)
    }

    func testUnterminatedFinalEventIsNotDelivered() async throws {
        // No blank line after RUN_FINISHED: the event is incomplete at close.
        let client = await clientWith(makeResponse(body: "\(started)\n\n\(finished)\n"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertEqual(result.types, ["RUN_STARTED"])
        XCTAssertNotNil(result.error)
    }

    func testStreamEndingWithRunFinishedIsSuccess() async throws {
        let client = await clientWith(makeResponse(body: "\(started)\n\n\(finished)\n\n"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
    }

    func testStreamEndingWithRunErrorIsDeliveredNotTransportFailure() async throws {
        let client = await clientWith(makeResponse(body: "\(started)\n\n\(runError)\n\n"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error, "RUN_ERROR is itself a terminal event")
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_ERROR"])
    }

    // MARK: - No resumption

    func testMidStreamFailureIsNotRetriedOrResumed() async throws {
        let response = makeResponse(body: "id: event-42\n\(started)\n\n", trailingError: ClientError.timeout)
        let client = await clientWith(response)

        let agent = makeAgent(client: client, retryPolicy: .fixed(maxAttempts: 3, delay: 0))
        let result = try await collect(agent)

        XCTAssertEqual(result.error as? ClientError, .timeout)
        let requests = await client.requestsReceived
        XCTAssertEqual(requests.count, 1, "A broken stream must not be reconnected")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Last-Event-ID"))
    }

    func testPreStreamRetryNeverSendsLastEventId() async throws {
        let client = SequencedHTTPClient(responses: [
            .failure(ClientError.timeout),
            .success(makeResponse(body: "\(started)\n\n\(finished)\n\n")),
        ])
        let agent = makeAgent(client: client, retryPolicy: .fixed(maxAttempts: 1, delay: 0))
        let result = try await collect(agent)
        XCTAssertNil(result.error)
        let requests = await client.requestHistory
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Last-Event-ID"))
        }
    }

    // MARK: - Errors before RUN_STARTED

    func testNon2xxStatusFailsBeforeAnyEvent() async throws {
        let body = "\(started)\n\n\(finished)\n\n"
        let client = await clientWith(makeResponse(body: body, statusCode: 503))
        let result = try await collect(makeAgent(client: client))
        XCTAssertTrue(result.types.isEmpty)
        XCTAssertEqual(result.error as? ClientError, .httpError(statusCode: 503))
    }

    func testWrongContentTypeFailsBeforeAnyEvent() async throws {
        let body = "\(started)\n\n\(finished)\n\n"
        let client = await clientWith(makeResponse(body: body, contentType: "application/json"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertTrue(result.types.isEmpty, "Nothing may be decoded from a non-SSE response")
        guard case .streamError? = result.error as? ClientError else {
            return XCTFail("Expected ClientError.streamError, got \(String(describing: result.error))")
        }
    }

    func testWrongContentTypeIsNotRetried() async throws {
        let client = await clientWith(makeResponse(body: "{}", contentType: "text/html"))
        let agent = makeAgent(client: client, retryPolicy: .fixed(maxAttempts: 3, delay: 0))
        let result = try await collect(agent)
        XCTAssertNotNil(result.error)
        let count = await client.executeCallCount
        XCTAssertEqual(count, 1)
    }

    func testContentTypeWithParametersAndCaseIsAccepted() async throws {
        let body = "\(started)\n\n\(finished)\n\n"
        let client = await clientWith(makeResponse(body: body, contentType: "Text/Event-Stream; charset=utf-8"))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.types, ["RUN_STARTED", "RUN_FINISHED"])
    }

    func testMissingContentTypeIsTolerated() async throws {
        let body = "\(started)\n\n\(finished)\n\n"
        let client = await clientWith(makeResponse(body: body, contentType: nil))
        let result = try await collect(makeAgent(client: client))
        XCTAssertNil(result.error)
    }

    func testHttpTransportExecuteRejectsWrongContentType() async throws {
        let client = await clientWith(makeResponse(body: "{}", contentType: "application/json"))
        let transport = HttpTransport(configuration: HttpAgentConfiguration(baseURL: baseURL), httpClient: client)
        do {
            _ = try await transport.execute(endpoint: "/run", input: try makeInput())
            XCTFail("Expected an error for a non-SSE content type")
        } catch let error as ClientError {
            guard case .streamError = error else { return XCTFail("Unexpected \(error)") }
        }
    }
}
