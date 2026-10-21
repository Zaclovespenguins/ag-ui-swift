// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import XCTest
@testable import AGUIClient

/// Wire compatibility with @ag-ui/core and @ag-ui/encoder 1.0.3.
final class ReferenceSDKWireTests: XCTestCase {
    func testDecodesSSEProducedByReferenceEncoder() async throws {
        // Generated with new EventEncoder().encode(event) from @ag-ui/encoder 1.0.3.
        let sse = [
            "data: {\"type\":\"RUN_STARTED\",\"threadId\":\"t\",\"runId\":\"r\"}",
            "",
            "data: {\"type\":\"TEXT_MESSAGE_START\",\"messageId\":\"assistant\"}",
            "",
            "data: {\"type\":\"TOOL_CALL_RESULT\",\"messageId\":\"result\",\"toolCallId\":\"call\",\"content\":[{\"typ" +
                "e\":\"text\",\"text\":\"done\"},{\"type\":\"image\",\"source\":{\"type\":\"url\",\"value\":\"https://example.c" +
                "om/result.png\",\"mimeType\":\"image/png\"}}]}",
            "",
            "data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\",\"outcome\":{\"type\":\"cancelled\"}}",
            "",
            "",
        ].joined(separator: "\n")
        let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
            for byte in sse.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        var events: [any AGUIEvent] = []
        for try await event in EventStream(bytes: bytes, decoder: AGUIEventDecoder()) {
            events.append(event)
        }
        XCTAssertEqual(events.count, 4)
        let start = try XCTUnwrap(events[1] as? TextMessageStartEvent)
        XCTAssertEqual(start.role, "assistant")
        let result = try XCTUnwrap(events[2] as? ToolCallResultEvent)
        XCTAssertEqual(result.resultContent, .parts([
            TextPart(text: "done"),
            ImagePart(url: "https://example.com/result.png", mimeType: "image/png")
        ]))
        XCTAssertEqual((events[3] as? RunFinishedEvent)?.outcome, .cancelled)
    }

    func testExportRunInputsForReferenceValidation() throws {
        let inputs = [
            RunAgentInput(threadId: "t", runId: "minimal"),
            RunAgentInput(
                threadId: "t", runId: "parts", state: Data(#"{"nested":null}"#.utf8),
                messages: [ToolMessage(
                    id: "result", resultContent: .parts([
                        TextPart(text: "done"),
                        ImagePart(url: "https://example.com/result.png", mimeType: "image/png")
                    ]), toolCallId: "call", name: "local-only", encryptedValue: "opaque"
                )],
                forwardedProps: Data(#"{"nested":null}"#.utf8),
                resume: [.resolved(interruptId: "interrupt", payload: Data(#"{"answer":null}"#.utf8))],
                protocolVersion: "1.0"
            ),
            RunAgentInput(threadId: "t", runId: "empty-parts", messages: [
                ToolMessage(id: "empty", resultContent: .parts([]), toolCallId: "call")
            ])
        ]
        let data = try JSONEncoder().encode(inputs)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(objects[0]["state"])
        XCTAssertNil(objects[0]["tools"])
        XCTAssertNil(objects[0]["context"])
        let message = try XCTUnwrap((objects[1]["messages"] as? [[String: Any]])?.first)
        XCTAssertNil(message["name"])
        XCTAssertEqual(message["encryptedValue"] as? String, "opaque")
        XCTAssertEqual((message["content"] as? [Any])?.count, 2)
        XCTAssertTrue((objects[1]["state"] as? [String: Any])?["nested"] is NSNull)
        if let output = ProcessInfo.processInfo.environment["AGUI_WIRE_OUTPUT_PATH"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}
