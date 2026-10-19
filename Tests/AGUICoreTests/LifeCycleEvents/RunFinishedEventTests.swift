// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

final class RunFinishedEventTests: XCTestCase,
                                    AGUIEventDecoderTestHelpers,
                                    EventDecodingErrorTests {

    // MARK: - EventDecodingErrorTests Protocol Requirements

    var validEventFieldsWithoutType: [String: Any] {
        [
            "threadId": EventTestData.threadId,
            "runId": EventTestData.runId
        ]
    }

    var eventTypeString: String { "RUN_FINISHED" }
    var expectedEventType: EventType { .runFinished }
    var unknownEventTypeString: String { "RUN_PAUSED" }

    // MARK: - Feature: Decode RUN_FINISHED

    func test_decodeValidRunFinished_returnsRunFinishedEvent() throws {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "threadId": "\(EventTestData.threadId)",
          "runId": "\(EventTestData.runId)"
        }
        """)

        let decoder = makeStrictDecoder()

        // When
        let event = try decoder.decode(data)

        // Then
        guard let runFinished = event as? RunFinishedEvent else {
            return XCTFail("Expected RunFinishedEvent, got \(type(of: event))")
        }
        XCTAssertEqual(runFinished.eventType, .runFinished)
        XCTAssertEqual(runFinished.threadId, EventTestData.threadId)
        XCTAssertEqual(runFinished.runId, EventTestData.runId)
        XCTAssertNil(runFinished.timestamp)
    }

    func test_decodeRunFinished_withTimestamp_populatesTimestamp() throws {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "threadId": "\(EventTestData.threadId)",
          "runId": "\(EventTestData.runId)",
          "timestamp": \(EventTestData.timestamp)
        }
        """)
        let decoder = makeStrictDecoder()

        // When
        let event = try decoder.decode(data)

        // Then
        let runFinished = try XCTUnwrap(event as? RunFinishedEvent)
        XCTAssertEqual(runFinished.timestamp, EventTestData.timestamp)
    }

    func test_decodeRunFinished_preservesRawEventBytes() throws {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "threadId": "\(EventTestData.threadId)",
          "runId": "\(EventTestData.runId)",
          "timestamp": \(EventTestData.timestamp)
        }
        """)
        let decoder = makeStrictDecoder()

        // When
        let event = try decoder.decode(data)

        // Then
        let runFinished = try XCTUnwrap(event as? RunFinishedEvent)
        XCTAssertEqual(runFinished.rawEvent, data)
    }

    func test_decodeRunFinished_ignoresUnknownExtraFields() throws {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "threadId": "\(EventTestData.threadId)",
          "runId": "\(EventTestData.runId)",
          "extraField": "ignored",
          "nested": { "x": 1 }
        }
        """)
        let decoder = makeStrictDecoder()

        // When
        let event = try decoder.decode(data)

        // Then
        let runFinished = try XCTUnwrap(event as? RunFinishedEvent)
        XCTAssertEqual(runFinished.threadId, EventTestData.threadId)
        XCTAssertEqual(runFinished.runId, EventTestData.runId)
    }

    // MARK: - Feature: Error handling (event-specific)

    func test_decodeRunFinished_missingThreadId_throwsDecodingFailed() {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "runId": "run-456"
        }
        """)
        let decoder = makeStrictDecoder()

        // When / Then
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            guard case .decodingFailed(let message) = (error as? EventDecodingError) else {
                return XCTFail("Expected .decodingFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("threadId"), "Expected message to mention 'threadId'. Got: \(message)")
        }
    }

    func test_decodeRunFinished_threadIdWrongType_throwsDecodingFailed() {
        // Given
        let data = jsonData("""
        {
          "type": "RUN_FINISHED",
          "threadId": 123,
          "runId": "run-456"
        }
        """)
        let decoder = makeStrictDecoder()

        // When / Then
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            guard case .decodingFailed(let message) = (error as? EventDecodingError) else {
                return XCTFail("Expected .decodingFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("type mismatch") || message.contains("Type mismatch"),
                          "Expected a type mismatch message. Got: \(message)")
        }
    }

    // MARK: - Feature: Decode outcome field

    // Fixtures below were produced by the official TypeScript SDK
    // (@ag-ui/encoder 1.0.2) and validated against RunFinishedEventSchema.

    func test_decodeRunFinished_missingOutcome_defaultsToSuccess() throws {
        // Given – no "outcome" key; absent means success per the spec
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1"}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .success())
        XCTAssertTrue(runFinished.outcome.interrupts.isEmpty)
    }

    func test_decodeRunFinished_nullOutcome_defaultsToSuccess() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":null}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .success())
    }

    func test_decodeRunFinished_successOutcome_withPendingToolCallIds() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"success","pendingToolCallIds":["call-9"]}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .success(pendingToolCallIds: ["call-9"]))
    }

    func test_decodeRunFinished_successOutcome_withoutPendingToolCallIds() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"success"}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .success())
    }

    func test_decodeRunFinished_cancelledOutcome() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"cancelled"}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .cancelled)
    }

    func test_decodeRunFinished_interruptOutcome_decodesAllInterruptFields() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"interrupt","interrupts":[{"id":"run-1::call-1","reason":"tool_call","message":"Approve running the calculator?","toolCallId":"call-1","responseSchema":{"type":"object","properties":{"approved":{"type":"boolean"}}},"expiresAt":"2026-10-19T12:00:00Z","metadata":{"toolName":"calculatorCardTool"},"subagentRunId":"sub-1"},{"id":"int-2","reason":"mastra:tool_suspend"}]}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        guard case .interrupt(let interrupts) = runFinished.outcome else {
            return XCTFail("Expected interrupt outcome, got \(runFinished.outcome)")
        }
        XCTAssertEqual(interrupts.count, 2)
        XCTAssertEqual(runFinished.outcome.interrupts, interrupts)

        let first = interrupts[0]
        XCTAssertEqual(first.id, "run-1::call-1")
        XCTAssertEqual(first.reason, .toolCall)
        XCTAssertEqual(first.message, "Approve running the calculator?")
        XCTAssertEqual(first.toolCallId, "call-1")
        XCTAssertEqual(first.expiresAt, "2026-10-19T12:00:00Z")
        XCTAssertEqual(first.subagentRunId, "sub-1")

        let schema = try XCTUnwrap(first.responseSchema)
        let schemaObject = try XCTUnwrap(JSONSerialization.jsonObject(with: schema) as? [String: Any])
        XCTAssertEqual(schemaObject["type"] as? String, "object")

        let metadata = try XCTUnwrap(first.metadata)
        let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(metadataObject["toolName"] as? String, "calculatorCardTool")

        // Optional fields stay nil, and custom namespaced reasons are preserved.
        let second = interrupts[1]
        XCTAssertEqual(second.id, "int-2")
        XCTAssertEqual(second.reason, InterruptReason(rawValue: "mastra:tool_suspend"))
        XCTAssertNil(second.message)
        XCTAssertNil(second.toolCallId)
        XCTAssertNil(second.responseSchema)
        XCTAssertNil(second.expiresAt)
        XCTAssertNil(second.metadata)
        XCTAssertNil(second.subagentRunId)
    }

    func test_decodeRunFinished_interruptMissingId_throws() {
        // Given – an interrupt nobody can answer must not be dropped silently
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"interrupt","interrupts":[{"reason":"tool_call"}]}}
        """)

        // Then
        XCTAssertThrowsError(try makeStrictDecoder().decode(data))
    }

    func test_decodeRunFinished_interruptMissingReason_throws() {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"interrupt","interrupts":[{"id":"int-1"}]}}
        """)

        // Then
        XCTAssertThrowsError(try makeStrictDecoder().decode(data))
    }

    func test_decodeRunFinished_interruptOutcomeWithoutInterruptsArray_throws() {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"interrupt"}}
        """)

        // Then
        XCTAssertThrowsError(try makeStrictDecoder().decode(data))
    }

    func test_decodeRunFinished_unknownOutcomeType_isUnknownNotSuccess() throws {
        // Given – a future outcome type must not be mistaken for a completed run
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"type":"handoff"}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .unknown(type: "handoff"))
    }

    func test_decodeRunFinished_legacyStringOutcome_isUnknownAndDoesNotThrow() throws {
        // Given – pre-spec string form from older producers
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":"CANCELLED"}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .unknown(type: "CANCELLED"))
    }

    func test_decodeRunFinished_outcomeObjectWithoutType_isUnknownAndDoesNotThrow() throws {
        // Given
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","outcome":{"interrupts":[]}}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        XCTAssertEqual(runFinished.outcome, .unknown(type: ""))
    }

    func test_decodeRunFinished_scalarResult_isPreserved() throws {
        // Given – result may be any JSON value, including a top-level scalar
        let data = jsonData("""
        {"type":"RUN_FINISHED","threadId":"thread-1","runId":"run-1","result":42}
        """)

        // When
        let runFinished = try XCTUnwrap(try makeStrictDecoder().decode(data) as? RunFinishedEvent)

        // Then
        let result = try XCTUnwrap(runFinished.result)
        XCTAssertEqual(String(data: result, encoding: .utf8), "42")
    }

    // MARK: - Feature: InterruptReason

    func test_interruptReason_coreValuesMatchSpec() {
        XCTAssertEqual(InterruptReason.toolCall.rawValue, "tool_call")
        XCTAssertEqual(InterruptReason.inputRequired.rawValue, "input_required")
        XCTAssertEqual(InterruptReason.confirmation.rawValue, "confirmation")
    }

    func test_interruptReason_isExpressibleByStringLiteral() {
        let reason: InterruptReason = "langgraph:custom"
        XCTAssertEqual(reason.rawValue, "langgraph:custom")
    }

    // MARK: - Feature: Model behaviors

    func test_runFinishedEvent_eventTypeIsAlwaysRunFinished() {
        // Given
        let event = RunFinishedEvent(threadId: "t", runId: "r", timestamp: nil, rawEvent: nil)

        // Then
        XCTAssertEqual(event.eventType, .runFinished)
    }

    func test_runFinishedEvent_defaultOutcomeIsSuccess() {
        // Given
        let event = RunFinishedEvent(threadId: "t", runId: "r")

        // Then
        XCTAssertEqual(event.outcome, .success())
    }

    func test_runFinishedEvent_outcomeCanBeSetToCancelled() {
        // Given
        let event = RunFinishedEvent(threadId: "t", runId: "r", outcome: .cancelled)

        // Then
        XCTAssertEqual(event.outcome, .cancelled)
        XCTAssertTrue(event.outcome.interrupts.isEmpty)
    }

    func test_runFinishedEvent_outcomeCanBeSetToInterrupt() {
        // Given
        let interrupt = Interrupt(id: "int-1", reason: .confirmation, message: "Continue?")
        let event = RunFinishedEvent(threadId: "t", runId: "r", outcome: .interrupt([interrupt]))

        // Then
        XCTAssertEqual(event.outcome.interrupts, [interrupt])
    }

    func test_runFinishedEvent_equatable_sameFields_areEqual() {
        // Given
        let event1 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .success(), timestamp: 1, rawEvent: nil)
        let event2 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .success(), timestamp: 1, rawEvent: nil)

        // Then
        XCTAssertEqual(event1, event2)
    }

    func test_runFinishedEvent_equatable_differentOutcome_areNotEqual() {
        // Given
        let event1 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .success())
        let event2 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .cancelled)

        // Then
        XCTAssertNotEqual(event1, event2)
    }

    func test_runFinishedEvent_equatable_differentInterrupts_areNotEqual() {
        // Given
        let event1 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .interrupt([Interrupt(id: "a", reason: .toolCall)]))
        let event2 = RunFinishedEvent(threadId: "t", runId: "r", outcome: .interrupt([Interrupt(id: "b", reason: .toolCall)]))

        // Then
        XCTAssertNotEqual(event1, event2)
    }
}
