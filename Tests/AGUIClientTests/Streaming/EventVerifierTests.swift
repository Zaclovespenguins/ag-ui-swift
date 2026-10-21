// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
@testable import AGUIClient
import XCTest

final class EventVerifierTests: XCTestCase {

    // MARK: - Valid Run Tests

    func testValidCompleteRunPassesThrough() async throws {
        // Given: A well-formed event sequence
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
            TextMessageContentEvent(messageId: "msg1", delta: "Hello"),
            TextMessageEndEvent(messageId: "msg1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]

        // When: Verifying the stream
        let verified = try await collectEvents(events.asyncStream.verifyEvents())

        // Then: All events pass through
        XCTAssertEqual(verified.count, 5)
        XCTAssertTrue(verified[0] is RunStartedEvent)
        XCTAssertTrue(verified[1] is TextMessageStartEvent)
        XCTAssertTrue(verified[2] is TextMessageContentEvent)
        XCTAssertTrue(verified[3] is TextMessageEndEvent)
        XCTAssertTrue(verified[4] is RunFinishedEvent)
    }

    // MARK: - First Event Validation Tests

    func testWrongFirstEventThrowsAGUIProtocolError() async throws {
        // Given: A stream that starts with a non-RUN_STARTED event
        let events: [any AGUIEvent] = [
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
        ]

        // When/Then: Should throw AGUIProtocolError
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertEqual(error.message, "First event must be 'RUN_STARTED'")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRunErrorAsFirstEventIsAllowed() async throws {
        // Given: A stream starting with RUN_ERROR
        let events: [any AGUIEvent] = [
            RunErrorEvent(message: "Something failed", code: "ERR"),
        ]

        // When: Verifying
        let verified = try await collectEvents(events.asyncStream.verifyEvents())

        // Then: RUN_ERROR passes through as first event
        XCTAssertEqual(verified.count, 1)
        XCTAssertTrue(verified[0] is RunErrorEvent)
    }

    // MARK: - Duplicate Message Tests

    func testDuplicateTextMessageStartThrowsError() async throws {
        // Given: Two TEXT_MESSAGE_START events with the same messageId
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
        ]

        // When/Then: Should throw AGUIProtocolError
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertTrue(error.message.contains("msg1"))
            XCTAssertTrue(error.message.contains("already in progress"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Message Without Start Tests

    func testTextMessageContentWithoutStartThrowsError() async throws {
        // Given: TEXT_MESSAGE_CONTENT without matching START
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageContentEvent(messageId: "msg-orphan", delta: "Hello"),
        ]

        // When/Then: Should throw AGUIProtocolError
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertTrue(error.message.contains("msg-orphan"))
            XCTAssertTrue(error.message.contains("No active text message"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - RUN_FINISHED with Active Message Tests

    func testRunFinishedWithActiveMessageThrowsError() async throws {
        // Given: RUN_FINISHED while a message is still open
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
            // Missing TextMessageEndEvent
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]

        // When/Then: Should throw AGUIProtocolError
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertTrue(error.message.contains("RUN_FINISHED"))
            XCTAssertTrue(error.message.contains("messages are still active"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Sequential Runs Tests

    func testSequentialRunsResetState() async throws {
        // Given: Two complete runs in sequence
        let events: [any AGUIEvent] = [
            // First run
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
            TextMessageContentEvent(messageId: "msg1", delta: "Hello"),
            TextMessageEndEvent(messageId: "msg1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
            // Second run
            RunStartedEvent(threadId: "t1", runId: "r2"),
            TextMessageStartEvent(messageId: "msg2", role: "assistant"),
            TextMessageContentEvent(messageId: "msg2", delta: "World"),
            TextMessageEndEvent(messageId: "msg2"),
            RunFinishedEvent(threadId: "t1", runId: "r2"),
        ]

        // When: Verifying
        let verified = try await collectEvents(events.asyncStream.verifyEvents())

        // Then: All 10 events pass through without error
        XCTAssertEqual(verified.count, 10)
    }

    func testEventsAfterRunErrorThrows() async throws {
        // Given: An event after RUN_ERROR
        let events: [any AGUIEvent] = [
            RunErrorEvent(message: "Failure", code: "ERR"),
            TextMessageStartEvent(messageId: "msg1", role: "assistant"),
        ]

        // When/Then: Should throw
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertTrue(error.message.contains("already errored"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Tool Call Tests

    func testValidToolCallSequencePassesThrough() async throws {
        // Given: A valid tool call sequence
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallStartEvent(toolCallId: "tc1", toolCallName: "get_weather"),
            ToolCallArgsEvent(toolCallId: "tc1", delta: "{\"loc\":"),
            ToolCallArgsEvent(toolCallId: "tc1", delta: "\"SF\"}"),
            ToolCallEndEvent(toolCallId: "tc1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]

        // When: Verifying
        let verified = try await collectEvents(events.asyncStream.verifyEvents())

        // Then: All events pass through
        XCTAssertEqual(verified.count, 6)
    }

    func testToolCallArgsWithoutStartThrowsError() async throws {
        // Given: TOOL_CALL_ARGS without matching START
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallArgsEvent(toolCallId: "tc-orphan", delta: "{}"),
        ]

        // When/Then: Should throw
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
        } catch let error as AGUIProtocolError {
            XCTAssertTrue(error.message.contains("tc-orphan"))
            XCTAssertTrue(error.message.contains("No active tool call"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - B8: Run lifecycle

    func testLateRunErrorAfterRunFinishedPassesThroughAsFailedRun() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
            RunErrorEvent(message: "late failure", code: "LATE"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 3)
        XCTAssertTrue(verified[2] is RunErrorEvent)
    }

    func testEventsAfterLateRunErrorThrowAlreadyErrored() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
            RunErrorEvent(message: "late failure"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("already errored") == true)
    }

    func testSecondRunErrorStillThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            RunErrorEvent(message: "a"),
            RunErrorEvent(message: "b"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("already errored") == true)
    }

    func testRunStartedAfterRunErrorReturnsToActive() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            RunErrorEvent(message: "boom"),
            RunStartedEvent(threadId: "t1", runId: "r2"),
            TextMessageStartEvent(messageId: "m2", role: "assistant"),
            TextMessageEndEvent(messageId: "m2"),
            RunFinishedEvent(threadId: "t1", runId: "r2"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 6)
    }

    func testRunErrorEndsOpenItemsSoNextRunStartsClean() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "f"),
            StepStartedEvent(stepName: "s"),
            ReasoningStartEvent(messageId: "r"),
            RunErrorEvent(message: "boom"),
            RunStartedEvent(threadId: "t1", runId: "r2"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            TextMessageEndEvent(messageId: "m"),
            RunFinishedEvent(threadId: "t1", runId: "r2"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 10)
    }

    func testRunStartedWithoutFinishResetsPerRunTracking() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            RunStartedEvent(threadId: "t1", runId: "r2"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            TextMessageEndEvent(messageId: "m"),
            RunFinishedEvent(threadId: "t1", runId: "r2"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 6)
    }

    func testProducerRunErrorIsEventButConsumerRejectionIsProtocolError() async throws {
        // A producer RUN_ERROR is delivered as an event, never thrown.
        let ok: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            RunErrorEvent(message: "producer says no", code: "X"),
        ]
        let verified = try await collectEvents(ok.asyncStream.verifyEvents())
        XCTAssertEqual((verified[1] as? RunErrorEvent)?.code, "X")

        // A rejected stream throws AGUIProtocolError and yields no RunErrorEvent.
        let bad: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageContentEvent(messageId: "x", delta: "d"),
        ]
        var seen: [any AGUIEvent] = []
        do {
            for try await e in bad.asyncStream.verifyEvents() { seen.append(e) }
            XCTFail("expected throw")
        } catch is AGUIProtocolError {
            XCTAssertFalse(seen.contains { $0 is RunErrorEvent })
        }
    }

    // MARK: - B8: Reasoning

    func testValidReasoningSequencePasses() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningStartEvent(messageId: "r1"),
            ReasoningMessageStartEvent(messageId: "rm1"),
            ReasoningMessageContentEvent(messageId: "rm1", delta: "think"),
            ReasoningMessageEndEvent(messageId: "rm1"),
            ReasoningEndEvent(messageId: "r1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 7)
    }

    func testDuplicateOpenReasoningSpanThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningStartEvent(messageId: "r1"),
            ReasoningStartEvent(messageId: "r1"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("already in progress") == true)
    }

    func testReasoningEndWithoutStartThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningEndEvent(messageId: "nope"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("No active reasoning") == true)
    }

    func testReasoningEndMatchesByMessageId() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningStartEvent(messageId: "a"),
            ReasoningEndEvent(messageId: "b"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("'b'") == true)
    }

    func testRunFinishedWithOpenReasoningSpanThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningStartEvent(messageId: "r1"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("reasoning") == true)
    }

    func testRunFinishedWithOpenReasoningMessageThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageStartEvent(messageId: "rm"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("reasoning") == true)
    }

    func testReasoningMessageContentWithoutStartThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageContentEvent(messageId: "rm", delta: "x"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("No active reasoning message") == true)
    }

    func testDuplicateReasoningMessageStartThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageStartEvent(messageId: "rm"),
            ReasoningMessageStartEvent(messageId: "rm"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("already in progress") == true)
    }

    func testReasoningMessageEndWithoutStartThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageEndEvent(messageId: "rm"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("No active reasoning message") == true)
    }

    func testReasoningChunkWithoutMessageIdFirstThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageChunkEvent(delta: "x"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("messageId") == true)
    }

    func testReasoningChunkContinuationWithoutIdPasses() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ReasoningMessageChunkEvent(messageId: "rm", delta: "a"),
            ReasoningMessageChunkEvent(delta: "b"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 4)
    }

    // MARK: - B8: Chunks

    func testTextChunkFirstWithoutMessageIdThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageChunkEvent(delta: "x"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("messageId") == true)
    }

    func testTextChunkContinuationWithConflictingRoleThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageChunkEvent(messageId: "m", role: "assistant", delta: "a"),
            TextMessageChunkEvent(messageId: "m", role: "user", delta: "b"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("role") == true)
    }

    func testTextChunkContinuationRepeatingSameRolePasses() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageChunkEvent(messageId: "m", role: "assistant", delta: "a"),
            TextMessageChunkEvent(messageId: "m", role: "assistant", delta: "b"),
            TextMessageChunkEvent(delta: "c"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 5)
    }

    func testToolChunkFirstMissingNameThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallChunkEvent(toolCallId: "tc", delta: "{}"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("toolCallName") == true)
    }

    func testToolChunkFirstMissingIdThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallChunkEvent(toolCallName: "f", delta: "{}"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("toolCallId") == true)
    }

    func testToolChunkContinuationWithConflictingNameThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallChunkEvent(toolCallId: "tc", toolCallName: "f", delta: "{"),
            ToolCallChunkEvent(toolCallId: "tc", toolCallName: "g", delta: "}"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("toolCallName") == true)
    }

    func testToolChunkContinuationWithConflictingParentThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallChunkEvent(toolCallId: "tc", toolCallName: "f", parentMessageId: "p1"),
            ToolCallChunkEvent(toolCallId: "tc", delta: "}", parentMessageId: "p2"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("parentMessageId") == true)
    }

    func testToolChunkSequencePasses() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallChunkEvent(toolCallId: "tc", toolCallName: "f", delta: "{"),
            ToolCallChunkEvent(toolCallId: "tc", toolCallName: "f", delta: "}"),
            ToolCallChunkEvent(delta: ""),
            ToolCallEndEvent(toolCallId: "tc"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 6)
    }

    func testOpenChunkItemsAreClosedByRunFinished() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageChunkEvent(messageId: "m", role: "assistant", delta: "a"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 3)
    }

    // MARK: - B8: Reopening closed items

    func testClosedTextMessageMayReopenWithSameRole() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            TextMessageEndEvent(messageId: "m"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            TextMessageContentEvent(messageId: "m", delta: "more"),
            TextMessageEndEvent(messageId: "m"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 7)
    }

    func testClosedTextMessageReopenWithDifferentRoleThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            TextMessageStartEvent(messageId: "m", role: "assistant"),
            TextMessageEndEvent(messageId: "m"),
            TextMessageStartEvent(messageId: "m", role: "user"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("role") == true)
    }

    func testClosedToolCallMayReopenWithSameName() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "f"),
            ToolCallEndEvent(toolCallId: "tc"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "f"),
            ToolCallEndEvent(toolCallId: "tc"),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 6)
    }

    func testClosedToolCallReopenWithDifferentNameThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "f"),
            ToolCallEndEvent(toolCallId: "tc"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "g"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("toolCallName") == true)
    }

    func testToolCallArgsAfterEndThrows() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ToolCallStartEvent(toolCallId: "tc", toolCallName: "f"),
            ToolCallEndEvent(toolCallId: "tc"),
            ToolCallArgsEvent(toolCallId: "tc", delta: "{}"),
        ]
        let error = await protocolError(events)
        XCTAssertTrue(error?.message.contains("No active tool call") == true)
    }

    // MARK: - B8: Activity

    func testActivityDeltaWithoutSnapshotIsSkippedWithWarning() async throws {
        let (sink, continuation) = AsyncStream<String>.makeStream()
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ActivityDeltaEvent(messageId: "a1", activityType: "PLAN", patch: Data("[]".utf8)),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(
            events.asyncStream.verifyEvents(onWarning: { continuation.yield($0.message) })
        )
        continuation.finish()
        var warnings: [String] = []
        for await w in sink { warnings.append(w) }
        XCTAssertEqual(verified.count, 2)
        XCTAssertFalse(verified.contains { $0 is ActivityDeltaEvent })
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("a1") == true)
    }

    func testActivityDeltaAfterSnapshotPassesWithoutWarning() async throws {
        let (sink, continuation) = AsyncStream<String>.makeStream()
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ActivitySnapshotEvent(messageId: "a1", activityType: "PLAN", content: Data("{}".utf8)),
            ActivityDeltaEvent(messageId: "a1", activityType: "PLAN", patch: Data("[]".utf8)),
            RunFinishedEvent(threadId: "t1", runId: "r1"),
        ]
        let verified = try await collectEvents(
            events.asyncStream.verifyEvents(onWarning: { continuation.yield($0.message) })
        )
        continuation.finish()
        var warnings: [String] = []
        for await w in sink { warnings.append(w) }
        XCTAssertEqual(verified.count, 4)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testActivityDeltaWithoutSnapshotAndNoHookDoesNotThrow() async throws {
        let events: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t1", runId: "r1"),
            ActivityDeltaEvent(messageId: "a1", activityType: "PLAN", patch: Data("[]".utf8)),
        ]
        let verified = try await collectEvents(events.asyncStream.verifyEvents())
        XCTAssertEqual(verified.count, 1)
    }

    // MARK: - Helper Methods

    private func protocolError(_ events: [any AGUIEvent]) async -> AGUIProtocolError? {
        do {
            _ = try await collectEvents(events.asyncStream.verifyEvents())
            XCTFail("Expected AGUIProtocolError to be thrown")
            return nil
        } catch let error as AGUIProtocolError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(error)")
            return nil
        }
    }

    private func collectEvents(
        _ stream: AsyncThrowingStream<any AGUIEvent, Error>
    ) async throws -> [any AGUIEvent] {
        var collected: [any AGUIEvent] = []
        for try await event in stream {
            collected.append(event)
        }
        return collected
    }
}

// Note: asyncStream is provided by the extension in ChunkTransformTests.swift
