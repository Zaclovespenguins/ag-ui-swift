// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// B6: "absent means absent". Producers omit empty optionals and never send `null`;
/// consumers read an optional set to `null` as omitted; `null` inside payloads is data.
final class AbsentMeansAbsentTests: XCTestCase {

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ input: RunAgentInput) throws -> [String: Any] {
        try object(JSONEncoder().encode(input))
    }

    private func decodeInput(_ json: String) throws -> RunAgentInput {
        try JSONDecoder().decode(RunAgentInput.self, from: Data(json.utf8))
    }

    private func assertNoNulls(_ value: Any, path: String = "$", file: StaticString = #filePath, line: UInt = #line) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict { assertNoNulls(child, path: "\(path).\(key)", file: file, line: line) }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() { assertNoNulls(child, path: "\(path)[\(index)]", file: file, line: line) }
        } else if value is NSNull {
            XCTFail("Unexpected null at \(path)", file: file, line: line)
        }
    }

    // MARK: - RunAgentInput producer

    func test_encode_emptyState_omitsStateInsteadOfNull() throws {
        let input = RunAgentInput(threadId: "t", runId: "r")
        let result = try json(input)
        XCTAssertNil(result["state"], "empty state must be omitted, not null")
    }

    func test_encode_neverEmitsNullForEmptyOptionals() throws {
        let input = RunAgentInput(
            threadId: "t", runId: "r",
            messages: [
                AssistantMessage(id: "a", content: nil),
                ToolMessage(id: "m", content: "x", toolCallId: "c"),
                ReasoningMessage(id: "rm", content: "thinking")
            ]
        )
        assertNoNulls(try json(input))
    }

    func test_encode_nonEmptyState_preservesNullInsidePayload() throws {
        let input = RunAgentInput(
            threadId: "t", runId: "r",
            state: Data(#"{"a":null,"b":{"c":null},"d":[null,1]}"#.utf8)
        )
        let state = try XCTUnwrap(try json(input)["state"] as? [String: Any])
        XCTAssertTrue(state["a"] is NSNull)
        XCTAssertTrue((state["b"] as? [String: Any])?["c"] is NSNull)
        XCTAssertTrue((state["d"] as? [Any])?.first is NSNull)
    }

    func test_encode_forwardedPropsPreservesNullInsidePayload() throws {
        let input = RunAgentInput(
            threadId: "t", runId: "r",
            forwardedProps: Data(#"{"flag":null}"#.utf8)
        )
        let props = try XCTUnwrap(try json(input)["forwardedProps"] as? [String: Any])
        XCTAssertTrue(props["flag"] is NSNull)
    }

    func test_encode_toolMetadataNullValuePreserved() throws {
        let tool = Tool(
            name: "t", description: "d", parameters: Data("{}".utf8),
            metadata: Data(#"{"k":null}"#.utf8)
        )
        let result = try object(JSONEncoder().encode(tool))
        XCTAssertTrue((result["metadata"] as? [String: Any])?["k"] is NSNull)
    }

    func test_encode_toolWithoutMetadata_omitsMetadata() throws {
        let tool = Tool(name: "t", description: "d", parameters: Data("{}".utf8))
        XCTAssertNil(try object(JSONEncoder().encode(tool))["metadata"])
    }

    // MARK: - RunAgentInput consumer

    func test_decode_stateNull_equalsEmptyObject() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","state":null,"messages":[]}"#)
        XCTAssertEqual(input.state, Data("{}".utf8))
    }

    func test_decode_stateAbsent_equalsEmptyObject() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","messages":[]}"#)
        XCTAssertEqual(input.state, Data("{}".utf8))
    }

    func test_decode_stateWithNullInside_preservesNull() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","state":{"a":null}}"#)
        XCTAssertTrue(try object(input.state)["a"] is NSNull)
    }

    func test_decode_forwardedPropsNull_treatedAsOmitted() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","forwardedProps":null}"#)
        XCTAssertEqual(input.forwardedProps, Data("{}".utf8))
    }

    func test_decode_forwardedPropsWithNullInside_preservesNull() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","forwardedProps":{"x":null}}"#)
        XCTAssertTrue(try object(input.forwardedProps)["x"] is NSNull)
    }

    func test_decode_nullMessagesToolsContext_treatedAsOmitted() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","messages":null,"tools":null,"context":null}"#)
        XCTAssertTrue(input.messages.isEmpty)
        XCTAssertTrue(input.tools.isEmpty)
        XCTAssertTrue(input.context.isEmpty)
    }

    func test_decode_nullParentRunIdAndResume_treatedAsOmitted() throws {
        let input = try decodeInput(#"{"threadId":"t","runId":"r","parentRunId":null,"resume":null}"#)
        XCTAssertNil(input.parentRunId)
        XCTAssertNil(input.resume)
    }

    func test_roundTrip_emptyStateStaysEmpty() throws {
        let original = RunAgentInput(threadId: "t", runId: "r")
        let decoded = try JSONDecoder().decode(RunAgentInput.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Message and type consumers

    private let messageDecoder = MessageDecoder()

    func test_decodeMessages_nullOptionals_treatedAsOmitted() throws {
        let cases: [String] = [
            #"{"id":"1","role":"developer","content":"c","name":null,"encryptedValue":null}"#,
            #"{"id":"1","role":"system","content":null,"name":null,"encryptedValue":null}"#,
            #"{"id":"1","role":"user","content":"c","name":null,"encryptedValue":null}"#,
            #"{"id":"1","role":"assistant","content":null,"name":null,"toolCalls":null,"encryptedValue":null}"#,
            #"{"id":"1","role":"tool","toolCallId":"c","content":"x","name":null,"error":null,"encryptedValue":null}"#,
            #"{"id":"1","role":"reasoning","content":"c","encryptedValue":null}"#
        ]
        for text in cases {
            let message = try messageDecoder.decode(Data(text.utf8))
            XCTAssertNil(message.name, text)
            if let assistant = message as? AssistantMessage {
                XCTAssertNil(assistant.toolCalls, text)
                XCTAssertNil(assistant.encryptedValue, text)
            }
        }
    }

    func test_decodeToolCall_nullEncryptedValue_treatedAsOmitted() throws {
        let text = #"{"id":"1","role":"assistant","toolCalls":[{"id":"c","type":"function","function":{"name":"n","arguments":"{}"},"encryptedValue":null}]}"#
        let message = try XCTUnwrap(try messageDecoder.decode(Data(text.utf8)) as? AssistantMessage)
        XCTAssertNil(message.toolCalls?.first?.encryptedValue)
    }

    func test_decodeToolCall_nullType_defaultsToFunction() throws {
        let text = #"{"id":"c","type":null,"function":{"name":"n","arguments":"{}"}}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(text.utf8))
        XCTAssertEqual(call.type, "function")
    }

    func test_decodeTool_nullMetadata_treatedAsOmitted() throws {
        let text = #"{"name":"n","description":"d","parameters":{},"metadata":null}"#
        XCTAssertNil(try JSONDecoder().decode(Tool.self, from: Data(text.utf8)).metadata)
    }

    func test_decodeTool_metadataNullValuePreserved() throws {
        let text = #"{"name":"n","description":"d","parameters":{},"metadata":{"k":null}}"#
        let tool = try JSONDecoder().decode(Tool.self, from: Data(text.utf8))
        XCTAssertTrue(try object(try XCTUnwrap(tool.metadata))["k"] is NSNull)
    }

    func test_decodeResumeEntry_nullPayloadAndMetadata_treatedAsOmitted() throws {
        let text = #"{"interruptId":"i","status":"resolved","payload":null,"metadata":null}"#
        let entry = try JSONDecoder().decode(ResumeEntry.self, from: Data(text.utf8))
        XCTAssertNil(entry.payload)
        XCTAssertNil(entry.metadata)
    }

    func test_encodeResumeEntry_omitsAbsentPayloadAndMetadata() throws {
        let entry = ResumeEntry(interruptId: "i", status: .resolved)
        let result = try object(JSONEncoder().encode(entry))
        XCTAssertNil(result["payload"])
        XCTAssertNil(result["metadata"])
    }

    // MARK: - Event consumers

    private let eventDecoder = AGUIEventDecoder()

    private func decodeEvent(_ text: String) throws -> any AGUIEvent {
        try eventDecoder.decode(Data(text.utf8))
    }

    private func describe(_ event: any AGUIEvent) -> String {
        String(describing: event).replacingOccurrences(of: "rawEvent.*", with: "", options: .regularExpression)
    }

    func test_decodeEvents_nullOptionals_treatedAsOmitted() throws {
        let cases: [(String, [String], [String])] = [
            ("RUN_STARTED", [#""threadId":"t""#, #""runId":"r""#], ["parentRunId", "input", "timestamp"]),
            ("RUN_FINISHED", [#""threadId":"t""#, #""runId":"r""#], ["result", "outcome", "timestamp"]),
            ("RUN_ERROR", [#""message":"m""#], ["code", "timestamp"]),
            ("TEXT_MESSAGE_START", [#""messageId":"m""#, #""role":"assistant""#], ["name", "timestamp"]),
            ("TEXT_MESSAGE_CHUNK", [], ["messageId", "role", "name", "delta", "timestamp"]),
            ("TOOL_CALL_START", [#""toolCallId":"c""#, #""toolCallName":"n""#], ["parentMessageId", "timestamp"]),
            ("TOOL_CALL_CHUNK", [], ["toolCallId", "toolCallName", "delta", "parentMessageId", "timestamp"]),
            ("TOOL_CALL_RESULT", [#""messageId":"m""#, #""toolCallId":"c""#, #""content":"x""#], ["role", "timestamp"]),
            ("REASONING_MESSAGE_CHUNK", [], ["messageId", "delta", "timestamp"]),
            ("RAW", [#""event":{"a":1}"#], ["source", "timestamp"]),
            ("ACTIVITY_SNAPSHOT", [#""messageId":"m""#, #""activityType":"t""#, #""content":{}"#], ["replace", "timestamp"])
        ]
        for (type, required, optional) in cases {
            let base = [#""type":"\#(type)""#] + required
            let nulls = optional.map { #""\#($0)":null"# }
            let withNulls = try decodeEvent("{" + (base + nulls).joined(separator: ",") + "}")
            let withoutNulls = try decodeEvent("{" + base.joined(separator: ",") + "}")
            XCTAssertEqual(describe(withNulls), describe(withoutNulls), type)
        }
    }

    func test_decodeRunFinished_nullInterruptFields_treatedAsOmitted() throws {
        let text = #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"interrupt","interrupts":[{"id":"i","reason":"input_required","message":null,"toolCallId":null,"responseSchema":null,"expiresAt":null,"metadata":null,"subagentRunId":null}]}}"#
        let event = try XCTUnwrap(try decodeEvent(text) as? RunFinishedEvent)
        guard case .interrupt(let interrupts) = event.outcome else { return XCTFail("expected interrupt") }
        let interrupt = try XCTUnwrap(interrupts.first)
        XCTAssertNil(interrupt.message)
        XCTAssertNil(interrupt.toolCallId)
        XCTAssertNil(interrupt.responseSchema)
        XCTAssertNil(interrupt.expiresAt)
        XCTAssertNil(interrupt.metadata)
        XCTAssertNil(interrupt.subagentRunId)
    }

    func test_decodeStateSnapshot_nullInsidePayloadPreserved() throws {
        let event = try XCTUnwrap(
            try decodeEvent(#"{"type":"STATE_SNAPSHOT","snapshot":{"a":null}}"#) as? StateSnapshotEvent
        )
        XCTAssertTrue(try object(event.snapshot)["a"] is NSNull)
    }

    func test_decodeStateDelta_nullPatchValuePreserved() throws {
        let event = try XCTUnwrap(
            try decodeEvent(#"{"type":"STATE_DELTA","delta":[{"op":"add","path":"/a","value":null}]}"#) as? StateDeltaEvent
        )
        let ops = try XCTUnwrap(JSONSerialization.jsonObject(with: event.delta) as? [[String: Any]])
        XCTAssertTrue(ops[0]["value"] is NSNull)
    }

    func test_decodeRunStarted_inputWithNullInside_preserved() throws {
        let event = try XCTUnwrap(
            try decodeEvent(#"{"type":"RUN_STARTED","threadId":"t","runId":"r","input":{"state":null}}"#) as? RunStartedEvent
        )
        let input = try object(try XCTUnwrap(event.input))
        XCTAssertTrue(input["state"] is NSNull)
    }
}
