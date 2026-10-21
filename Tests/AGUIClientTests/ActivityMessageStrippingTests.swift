// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUIClient
@testable import AGUICore

/// B9: activity messages are never sent back to the agent.
final class ActivityMessageStrippingTests: XCTestCase {

    private func activity(_ id: String) -> ActivityMessage {
        ActivityMessage(id: id, activityType: "progress", content: Data("{}".utf8))
    }

    private func sentMessageIds(_ client: MockHTTPClient) async throws -> [String] {
        let last = await client.lastRequest
        let request = try XCTUnwrap(last)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.contains { $0["role"] as? String == "activity" })
        return messages.compactMap { $0["id"] as? String }
    }

    private func makeAgent() async throws -> (HttpAgent, MockHTTPClient) {
        let client = MockHTTPClient()
        let sse = "data: {\"type\":\"RUN_STARTED\",\"threadId\":\"t1\",\"runId\":\"r1\"}\n\n"
        await client.setResponse(try await HTTPResponse.mock(data: Data(sse.utf8), statusCode: 200))
        let agent = HttpAgent(
            configuration: HttpAgentConfiguration(baseURL: URL(string: "https://agent.example.com")!),
            httpClient: client
        )
        return (agent, client)
    }

    func testHttpAgentRunWithRawInputStripsActivityMessages() async throws {
        let (agent, client) = try await makeAgent()
        // Constructed directly (bypasses the builder), so the transport must strip.
        let input = RunAgentInput(
            threadId: "t1", runId: "r1",
            messages: [UserMessage(id: "u1", content: "hi"), activity("a1")]
        )
        for try await _ in try await agent.run(input) {}
        let ids = try await sentMessageIds(client)
        XCTAssertEqual(ids, ["u1"])
    }

    func testHttpAgentRunWithBuilderStripsActivityMessages() async throws {
        let (agent, client) = try await makeAgent()
        let extra = activity("a1")
        for try await _ in try await agent.run(threadId: "t1", runId: "r1", configure: {
            $0.messages([UserMessage(id: "u1", content: "hi"), extra])
        }) {}
        let ids = try await sentMessageIds(client)
        XCTAssertEqual(ids, ["u1"])
    }

    func testAbstractAgentRunStripsActivityBeforeTransport() async throws {
        let transport = RecordingTransport()
        let agent = AbstractAgent(transport: transport)
        let input = RunAgentInput(
            threadId: "t1", runId: "r1",
            messages: [activity("a1"), UserMessage(id: "u1", content: "hi")]
        )
        for try await _ in agent.run(input: input) {}
        let seen = await transport.inputs
        XCTAssertEqual(seen.first?.messages.map(\.id), ["u1"])
    }
}

private actor RecordingTransport: AgentTransport {
    private(set) var inputs: [RunAgentInput] = []

    nonisolated func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.record(input)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ input: RunAgentInput) { inputs.append(input) }
}
