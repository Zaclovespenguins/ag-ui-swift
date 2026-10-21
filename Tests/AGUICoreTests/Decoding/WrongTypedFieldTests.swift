// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// B5: a known optional field that is present with a wrong-typed value must fail
/// decoding instead of silently becoming `nil`. Absent and `null` stay `nil`.
final class WrongTypedFieldTests: XCTestCase, AGUIEventDecoderTestHelpers {

    // MARK: - Helpers

    private func assertEventDecodingFails(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try makeStrictDecoder().decode(jsonData(json)), file: file, line: line) { error in
            guard case EventDecodingError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertMessageDecodingFails(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MessageDecoder().decode(jsonData(json)), file: file, line: line)
    }

    private func interruptOutcome(_ extra: String) -> String {
        """
        {"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"interrupt","interrupts":[{"id":"i","reason":"tool_call",\(extra)}]}}
        """
    }

    // MARK: - Events

    func test_runStarted_wrongTypedParentRunId_throws() {
        assertEventDecodingFails(#"{"type":"RUN_STARTED","threadId":"t","runId":"r","parentRunId":42}"#)
    }

    func test_runStarted_absentOrNullParentRunId_isNil() throws {
        for json in [
            #"{"type":"RUN_STARTED","threadId":"t","runId":"r"}"#,
            #"{"type":"RUN_STARTED","threadId":"t","runId":"r","parentRunId":null}"#,
        ] {
            let event = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(json)) as? RunStartedEvent)
            XCTAssertNil(event.parentRunId)
        }
    }

    func test_runError_wrongTypedCode_throws() {
        assertEventDecodingFails(#"{"type":"RUN_ERROR","message":"m","code":500}"#)
    }

    func test_runError_absentOrNullCode_isNil() throws {
        for json in [#"{"type":"RUN_ERROR","message":"m"}"#, #"{"type":"RUN_ERROR","message":"m","code":null}"#] {
            let event = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(json)) as? RunErrorEvent)
            XCTAssertNil(event.code)
        }
    }

    func test_rawEvent_wrongTypedSource_throws() {
        assertEventDecodingFails(#"{"type":"RAW","event":{"a":1},"source":true}"#)
    }

    func test_activitySnapshot_wrongTypedReplace_throws() {
        for replace in ["\"yes\"", "1", "0", "[]"] {
            assertEventDecodingFails(
                #"{"type":"ACTIVITY_SNAPSHOT","messageId":"m","activityType":"a","content":{},"replace":\#(replace)}"#
            )
        }
    }

    func test_activitySnapshot_absentReplace_defaultsTrue_booleanKept() throws {
        let absent = #"{"type":"ACTIVITY_SNAPSHOT","messageId":"m","activityType":"a","content":{}}"#
        let event = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(absent)) as? ActivitySnapshotEvent)
        XCTAssertTrue(event.replace)
        let falseJSON = #"{"type":"ACTIVITY_SNAPSHOT","messageId":"m","activityType":"a","content":{},"replace":false}"#
        let off = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(falseJSON)) as? ActivitySnapshotEvent)
        XCTAssertFalse(off.replace)
    }

    func test_runFinished_successWrongTypedPendingToolCallIds_throws() {
        assertEventDecodingFails(
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"success","pendingToolCallIds":"a"}}"#
        )
        assertEventDecodingFails(
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"success","pendingToolCallIds":["a",1]}}"#
        )
    }

    func test_runFinished_successAbsentPendingToolCallIds_isEmpty() throws {
        let json = #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"success"}}"#
        let event = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(json)) as? RunFinishedEvent)
        XCTAssertEqual(event.outcome, .success())
    }

    func test_runFinished_interruptWrongTypedOptionalFields_throw() {
        for extra in [
            #""message":1"#,
            #""toolCallId":false"#,
            #""expiresAt":123"#,
            #""subagentRunId":{}"#,
        ] {
            assertEventDecodingFails(interruptOutcome(extra))
        }
    }

    func test_runFinished_interruptWrongTypedRequiredFields_throw() {
        assertEventDecodingFails(
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"interrupt","interrupts":[{"id":1,"reason":"x"}]}}"#
        )
        assertEventDecodingFails(
            #"{"type":"RUN_FINISHED","threadId":"t","runId":"r","outcome":{"type":"interrupt","interrupts":[{"id":"i","reason":2}]}}"#
        )
    }

    func test_runFinished_interruptNullOptionalFields_areNil() throws {
        let json = interruptOutcome(#""message":null,"toolCallId":null,"expiresAt":null,"subagentRunId":null"#)
        let event = try XCTUnwrap(try makeStrictDecoder().decode(jsonData(json)) as? RunFinishedEvent)
        guard case .interrupt(let interrupts) = event.outcome else { return XCTFail("Expected interrupt") }
        XCTAssertNil(interrupts[0].message)
        XCTAssertNil(interrupts[0].subagentRunId)
    }

    func test_timestamp_wrongType_stillThrows() {
        assertEventDecodingFails(#"{"type":"RUN_ERROR","message":"m","timestamp":"now"}"#)
    }

    // MARK: - Messages

    func test_userMessage_wrongTypedOptionalFields_throw() {
        assertMessageDecodingFails(#"{"id":"1","role":"user","content":"hi","name":5}"#)
        assertMessageDecodingFails(#"{"id":"1","role":"user","content":"hi","encryptedValue":[]}"#)
    }

    func test_toolMessage_wrongTypedOptionalFields_throw() {
        for field in ["content", "name", "error", "encryptedValue"] {
            let content = field == "content" ? "" : #", "content":"x""#
            assertMessageDecodingFails(#"{"id":"1","role":"tool","toolCallId":"c"\#(content),"\#(field)":7}"#)
        }
    }

    func test_reasoningMessage_wrongTypedEncryptedValue_throws() {
        assertMessageDecodingFails(#"{"id":"1","role":"reasoning","content":"x","encryptedValue":7}"#)
    }

    func test_message_nullOptionalFields_areNil() throws {
        let message = try MessageDecoder().decode(
            jsonData(#"{"id":"1","role":"tool","toolCallId":"c","content":null,"name":null,"error":null}"#)
        )
        let tool = try XCTUnwrap(message as? ToolMessage)
        XCTAssertNil(tool.name)
    }

    // MARK: - Shared helpers

    func test_optionalFieldHelpers_semantics() throws {
        let object: [String: Any] = ["s": "x", "n": NSNull(), "i": 1, "b": true, "a": ["p", "q"], "bad": ["p", 2]]
        XCTAssertEqual(try OptionalField.string("s", in: object), "x")
        XCTAssertNil(try OptionalField.string("n", in: object))
        XCTAssertNil(try OptionalField.string("missing", in: object))
        XCTAssertThrowsError(try OptionalField.string("i", in: object))
        XCTAssertThrowsError(try OptionalField.string("b", in: object))
        XCTAssertEqual(try OptionalField.bool("b", in: object), true)
        XCTAssertThrowsError(try OptionalField.bool("i", in: object))
        XCTAssertThrowsError(try OptionalField.bool("s", in: object))
        XCTAssertEqual(try OptionalField.stringArray("a", in: object), ["p", "q"])
        XCTAssertThrowsError(try OptionalField.stringArray("bad", in: object))
        XCTAssertThrowsError(try OptionalField.stringArray("s", in: object))
        XCTAssertNil(try OptionalField.stringArray("n", in: object))
    }
}
