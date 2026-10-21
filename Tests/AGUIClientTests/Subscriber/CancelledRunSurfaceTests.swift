// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
@testable import AGUIClient
import XCTest

/// B11: a cancelled run is neither success nor error.
final class CancelledRunSurfaceTests: XCTestCase {

    private actor Recorder: AgentSubscriber {
        var finalized = 0
        var failed = 0
        var cancelled = 0

        func onRunFinalized(params: AgentSubscriberParams) async -> AgentStateMutation? {
            finalized += 1
            return nil
        }

        func onRunFailed(params: AgentRunFailureParams) async -> AgentStateMutation? {
            failed += 1
            return nil
        }

        func onRunCancelled(params: AgentSubscriberParams) async -> AgentStateMutation? {
            cancelled += 1
            return nil
        }
    }

    private struct ScriptedTransport: AgentTransport {
        let events: [any AGUIEvent]
        let finishWithError: Error?

        func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
            let events = events
            let error = finishWithError
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: error)
            }
        }
    }

    private func run(
        _ events: [any AGUIEvent],
        error: Error? = nil
    ) async -> (finalized: Int, failed: Int, cancelled: Int) {
        let recorder = Recorder()
        let agent = AbstractAgent(transport: ScriptedTransport(events: events, finishWithError: error))
        _ = await agent.subscribe(recorder)
        try? await agent.runAgent()
        return (await recorder.finalized, await recorder.failed, await recorder.cancelled)
    }

    func testCancelledOutcomeCallsOnRunCancelledOnly() async {
        let counts = await run([
            RunStartedEvent(threadId: "t", runId: "r"),
            RunFinishedEvent(threadId: "t", runId: "r", outcome: .cancelled),
        ])
        XCTAssertEqual(counts.finalized, 0, "cancelled run must not be reported as success")
        XCTAssertEqual(counts.failed, 0, "cancelled run must not be reported as error")
        XCTAssertEqual(counts.cancelled, 1)
    }

    func testSuccessOutcomeStillCallsOnRunFinalized() async {
        let counts = await run([
            RunStartedEvent(threadId: "t", runId: "r"),
            RunFinishedEvent(threadId: "t", runId: "r"),
        ])
        XCTAssertEqual(counts.finalized, 1)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(counts.cancelled, 0)
    }

    func testInterruptOutcomeIsNotCancelled() async {
        let counts = await run([
            RunStartedEvent(threadId: "t", runId: "r"),
            RunFinishedEvent(threadId: "t", runId: "r", outcome: .interrupt([])),
        ])
        XCTAssertEqual(counts.cancelled, 0)
    }

    func testStreamErrorStillCallsOnRunFailedNotCancelled() async {
        let counts = await run(
            [RunStartedEvent(threadId: "t", runId: "r")],
            error: NSError(domain: "test", code: 1)
        )
        XCTAssertEqual(counts.finalized, 0)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.cancelled, 0)
    }

    func testLocalAbortReportsCancelledNotSuccessOrFailure() async throws {
        struct HangingTransport: AgentTransport {
            func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(RunStartedEvent(threadId: "t", runId: "r"))
                }
            }
        }
        let recorder = Recorder()
        let agent = AbstractAgent(transport: HangingTransport())
        _ = await agent.subscribe(recorder)
        let runTask = Task { try? await agent.runAgent() }
        try await Task.sleep(nanoseconds: 200_000_000)
        await agent.abortRun()
        _ = await runTask.value
        let counts = await (recorder.finalized, recorder.failed, recorder.cancelled)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 1)
    }

    func testDefaultOnRunCancelledReturnsNil() async throws {
        struct Plain: AgentSubscriber {}
        let input = try RunAgentInput.builder().threadId("t").runId("r").build()
        let params = AgentSubscriberParams(messages: [], state: Data("{}".utf8), input: input)
        let mutation = await Plain().onRunCancelled(params: params)
        XCTAssertNil(mutation)
    }

    func testStreamEndingWithoutRunFinishedIsNotReportedAsCancelled() async {
        let counts = await run([RunStartedEvent(threadId: "t", runId: "r")])
        XCTAssertEqual(counts.cancelled, 0)
    }

    /// An abandoning consumer must not make the pipeline invent a RUN_FINISHED.
    func testChunkTransformerDoesNotSynthesizeRunFinishedWhenSourceEndsMidMessage() async throws {
        let source: [any AGUIEvent] = [
            RunStartedEvent(threadId: "t", runId: "r"),
            TextMessageChunkEvent(messageId: "m", role: "assistant", delta: "partial"),
        ]
        var seen: [any AGUIEvent] = []
        for try await event in source.asyncStream.transformChunks() { seen.append(event) }
        XCTAssertFalse(seen.contains { $0 is RunFinishedEvent })
        XCTAssertFalse(seen.contains { $0 is RunErrorEvent })
    }
}
