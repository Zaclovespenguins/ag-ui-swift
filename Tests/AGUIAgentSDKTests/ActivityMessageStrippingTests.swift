// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUIClient
import AGUICore
import XCTest
@testable import AGUIAgentSDK

/// B9: activity messages stay in local history but are never sent.
final class SDKActivityMessageStrippingTests: XCTestCase {

    private func snapshotWithActivity() -> MessagesSnapshotEvent {
        let json = """
        [{"id":"u0","role":"user","content":"earlier"},
         {"id":"a1","role":"activity","activityType":"progress","content":{"pct":50}},
         {"id":"s0","role":"assistant","content":"ok"}]
        """
        return MessagesSnapshotEvent(messages: Data(json.utf8), timestamp: nil, rawEvent: nil)
    }

    private func seededAgent() async throws -> (StatefulAgUiAgent, CapturingTransport) {
        let transport = CapturingTransport()
        let agent = StatefulAgUiAgent(
            transport: transport,
            config: StatefulAgUiAgentConfig(baseURL: URL(string: "https://placeholder.local")!)
        )
        await transport.setMockEvents([snapshotWithActivity()])
        for try await _ in try await agent.sendMessage(
            message: "first", threadId: "t1", state: nil, includeSystemPrompt: false
        ) {}
        await transport.setMockEvents([])
        return (agent, transport)
    }

    func testLocalHistoryKeepsActivityMessage() async throws {
        let (agent, _) = try await seededAgent()
        let history = await agent.history(for: "t1")
        XCTAssertTrue(history.contains { $0.role == .activity })
    }

    func testSendMessageOmitsActivityMessagesButKeepsOthers() async throws {
        let (agent, transport) = try await seededAgent()
        for try await _ in try await agent.sendMessage(
            message: "second", threadId: "t1", state: nil, includeSystemPrompt: false
        ) {}
        let inputs = await transport.capturedInputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertFalse(input.messages.contains { $0.role == .activity })
        XCTAssertEqual(Array(input.messages.map(\.id).prefix(2)), ["u0", "s0"])
        XCTAssertEqual(input.messages.last?.role, .user)
        let history = await agent.history(for: "t1")
        XCTAssertTrue(history.contains { $0.role == .activity }, "display history must keep activity")
    }

    func testChatPathOmitsActivityMessages() async throws {
        let (agent, transport) = try await seededAgent()
        for try await _ in try await agent.chat(message: "via chat", threadId: "t1") {}
        let inputs = await transport.capturedInputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertFalse(input.messages.contains { $0.role == .activity })
    }

    func testResumePathOmitsActivityMessages() async throws {
        let (agent, transport) = try await seededAgent()
        for try await _ in try await agent.resume(threadId: "t1", entries: []) {}
        let inputs = await transport.capturedInputs
        let input = try XCTUnwrap(inputs.last)
        XCTAssertFalse(input.messages.contains { $0.role == .activity })
    }
}
