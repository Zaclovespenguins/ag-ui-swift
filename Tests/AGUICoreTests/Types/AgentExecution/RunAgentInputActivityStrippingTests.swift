// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// B9: a consumer MUST strip activity messages from `messages` before sending.
final class RunAgentInputActivityStrippingTests: XCTestCase {

    private func activity(_ id: String) -> ActivityMessage {
        ActivityMessage(id: id, activityType: "progress", content: Data("{}".utf8))
    }

    func testBuilderDropsActivityMessages() throws {
        let input = try RunAgentInput.builder()
            .threadId("t").runId("r")
            .protocolVersion("1.0")
            .messages([
                UserMessage(id: "u1", content: "hi"),
                activity("a1"),
                AssistantMessage(id: "s1", content: "yo"),
                activity("a2"),
            ])
            .build()
        XCTAssertEqual(input.messages.map(\.id), ["u1", "s1"])
        XCTAssertFalse(input.messages.contains { $0.role == .activity })
        XCTAssertEqual(input.protocolVersion, "1.0")
    }

    func testStrippingKeepsOtherFields() {
        let input = RunAgentInput(
            threadId: "t", runId: "r", parentRunId: "p",
            messages: [activity("a1"), UserMessage(id: "u1", content: "hi")],
            protocolVersion: "1.0"
        )
        let stripped = input.strippingActivityMessages()
        XCTAssertEqual(stripped.messages.map(\.id), ["u1"])
        XCTAssertEqual(stripped.threadId, "t")
        XCTAssertEqual(stripped.runId, "r")
        XCTAssertEqual(stripped.parentRunId, "p")
        XCTAssertEqual(stripped.protocolVersion, "1.0")
    }

    func testStrippingOnlyActivityYieldsEmptyMessages() {
        let input = RunAgentInput(threadId: "t", runId: "r", messages: [activity("a1")])
        XCTAssertTrue(input.strippingActivityMessages().messages.isEmpty)
    }

    func testStrippingWithoutActivityIsNoOp() {
        let input = RunAgentInput(threadId: "t", runId: "r", messages: [UserMessage(id: "u1", content: "hi")])
        XCTAssertEqual(input.strippingActivityMessages(), input)
    }

    func testStrippingPreservesOrder() {
        let input = RunAgentInput(threadId: "t", runId: "r", messages: [
            UserMessage(id: "1", content: "a"), activity("x"),
            UserMessage(id: "2", content: "b"), activity("y"),
            UserMessage(id: "3", content: "c"),
        ])
        XCTAssertEqual(input.strippingActivityMessages().messages.map(\.id), ["1", "2", "3"])
    }
}
