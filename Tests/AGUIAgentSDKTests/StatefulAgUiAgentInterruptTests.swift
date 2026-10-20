// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUIClient
import AGUICore
import XCTest
@testable import AGUIAgentSDK

// MARK: - StatefulAgUiAgentInterruptTests

final class StatefulAgUiAgentInterruptTests: XCTestCase {

    // MARK: - Helpers

    private let threadId = "t1"

    private func makeAgent() -> (StatefulAgUiAgent, CapturingTransport) {
        let cfg = StatefulAgUiAgentConfig(baseURL: URL(string: "https://placeholder.local")!)
        let transport = CapturingTransport()
        return (StatefulAgUiAgent(transport: transport, config: cfg), transport)
    }

    private func drain(_ stream: AsyncThrowingStream<any AGUIEvent, Error>) async throws {
        for try await _ in stream {}
    }

    private func interruptEvents(_ interrupts: [Interrupt], runId: String = "r1") -> [any AGUIEvent] {
        [
            RunStartedEvent(threadId: threadId, runId: runId),
            RunFinishedEvent(threadId: threadId, runId: runId, outcome: .interrupt(interrupts)),
        ]
    }

    /// Runs one message that ends on the given interrupts, leaving the thread paused.
    private func pause(
        _ agent: StatefulAgUiAgent,
        _ transport: CapturingTransport,
        on interrupts: [Interrupt]
    ) async throws {
        await transport.setMockEvents(interruptEvents(interrupts))
        try await drain(agent.sendMessage(
            message: "Run it", threadId: threadId, state: nil, includeSystemPrompt: false
        ))
    }

    private func future() -> String { "2999-01-01T00:00:00Z" }
    private func past() -> String { "2000-01-01T00:00:00Z" }

    // MARK: - Tracking

    func testInterruptOutcomeSetsPendingInterrupts() async throws {
        let (agent, transport) = makeAgent()
        let interrupt = Interrupt(id: "i1", reason: .toolCall, toolCallId: "c1")
        try await pause(agent, transport, on: [interrupt])

        let pending = await agent.pendingInterrupts(for: threadId)
        XCTAssertEqual(pending, [interrupt])
        let other = await agent.pendingInterrupts(for: "other")
        XCTAssertTrue(other.isEmpty)
    }

    func testSuccessOutcomeAfterResumeClearsPendingInterrupts() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])

        await transport.setMockEvents([
            RunStartedEvent(threadId: threadId, runId: "r2"),
            RunFinishedEvent(threadId: threadId, runId: "r2", outcome: .success()),
        ])
        try await drain(agent.resume(threadId: threadId, entries: [.cancelled(interruptId: "i1")]))

        let pending = await agent.pendingInterrupts(for: threadId)
        XCTAssertTrue(pending.isEmpty)
    }

    func testCancelledAndUnknownOutcomesClearPendingInterrupts() async throws {
        for outcome in [RunFinishedOutcome.cancelled, .unknown(type: "future")] {
            let (agent, transport) = makeAgent()
            try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])
            await transport.setMockEvents([
                RunStartedEvent(threadId: threadId, runId: "r2"),
                RunFinishedEvent(threadId: threadId, runId: "r2", outcome: outcome),
            ])
            try await drain(agent.resume(threadId: threadId, entries: [.cancelled(interruptId: "i1")]))
            let pending = await agent.pendingInterrupts(for: threadId)
            XCTAssertTrue(pending.isEmpty, "\(outcome) should clear pending interrupts")
        }
    }

    func testClearHistoryClearsPendingInterrupts() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])

        await agent.clearHistory(threadId: threadId)
        let pending = await agent.pendingInterrupts(for: threadId)
        XCTAssertTrue(pending.isEmpty)
    }

    func testClearHistoryForAllThreadsClearsPendingInterrupts() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])

        await agent.clearHistory()
        let pending = await agent.pendingInterrupts(for: threadId)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Resume run input

    func testResumeSendsEntriesWithFreshRunIdAndNoNewUserMessage() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])
        await transport.setMockEvents([RunStartedEvent(threadId: threadId, runId: "r2")])

        let payload = Data("{\"approved\":true}".utf8)
        try await drain(agent.resume(
            threadId: threadId,
            entries: [.resolved(interruptId: "i1", payload: payload)]
        ))

        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 2)
        let first = inputs[0]
        let resumed = inputs[1]
        XCTAssertNil(first.resume)
        XCTAssertEqual(resumed.threadId, threadId)
        XCTAssertNotEqual(resumed.runId, first.runId)
        XCTAssertTrue(resumed.runId.hasPrefix("run_"))
        XCTAssertEqual(resumed.resume, [.resolved(interruptId: "i1", payload: payload)])
        XCTAssertEqual(resumed.messages.map(\.id), first.messages.map(\.id))
        XCTAssertEqual(resumed.messages.filter { $0.role == .user }.count, 1)
        let historyCount = await agent.history(for: threadId).count
        XCTAssertEqual(historyCount, first.messages.count)
    }

    func testResumeIsEncodedOnTheWire() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])
        try await drain(agent.resume(
            threadId: threadId,
            entries: [.resolved(interruptId: "i1", payload: Data("{\"approved\":false}".utf8))]
        ))

        let inputs = await transport.capturedInputs
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs[1])) as? [String: Any]
        )
        let resume = try XCTUnwrap(json["resume"] as? [[String: Any]])
        XCTAssertEqual(resume.count, 1)
        XCTAssertEqual(resume[0]["interruptId"] as? String, "i1")
        XCTAssertEqual(resume[0]["status"] as? String, "resolved")
        XCTAssertEqual((resume[0]["payload"] as? [String: Any])?["approved"] as? Bool, false)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs[0])) as? [String: Any]
        )
        XCTAssertNil(first["resume"])
    }

    func testResumeAllowsExpiredInterruptWhenCancelled() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall, expiresAt: past())])

        try await drain(agent.resume(threadId: threadId, entries: [.cancelled(interruptId: "i1")]))
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 2)
    }

    // MARK: - Validation

    func testSendMessageThrowsWhilePending() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])
        let historyBefore = await agent.history(for: threadId).count

        do {
            _ = try await agent.sendMessage(
                message: "more", threadId: threadId, state: nil, includeSystemPrompt: false
            )
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .unansweredInterrupts(ids: ["i1"]))
        }
        do {
            _ = try await agent.chat(message: "more", threadId: threadId)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .unansweredInterrupts(ids: ["i1"]))
        }

        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1, "No request should be made")
        let historyAfter = await agent.history(for: threadId).count
        XCTAssertEqual(historyAfter, historyBefore, "No user message should be added")
    }

    func testResumeThrowsWhenInterruptUnanswered() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [
            Interrupt(id: "i1", reason: .toolCall),
            Interrupt(id: "i2", reason: .inputRequired),
        ])

        do {
            _ = try await agent.resume(threadId: threadId, entries: [.cancelled(interruptId: "i1")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .unansweredInterrupts(ids: ["i2"]))
        }
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1)
    }

    func testResumeThrowsOnUnknownInterruptIds() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall)])

        do {
            _ = try await agent.resume(
                threadId: threadId,
                entries: [.cancelled(interruptId: "i1"), .cancelled(interruptId: "ghost")]
            )
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .unknownInterrupts(ids: ["ghost"]))
        }
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1)
    }

    func testResumeOnThreadWithoutInterruptsThrowsUnknown() async throws {
        let (agent, transport) = makeAgent()
        do {
            _ = try await agent.resume(threadId: threadId, entries: [.cancelled(interruptId: "i1")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .unknownInterrupts(ids: ["i1"]))
        }
        let inputs = await transport.capturedInputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testResumeThrowsWhenExpiredInterruptIsResolved() async throws {
        let (agent, transport) = makeAgent()
        try await pause(agent, transport, on: [Interrupt(id: "i1", reason: .toolCall, expiresAt: past())])

        do {
            _ = try await agent.resume(threadId: threadId, entries: [.resolved(interruptId: "i1")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? InterruptError, .expired(id: "i1"))
        }
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1)
    }

    // MARK: - buildResumeArray

    func testBuildResumeArrayOrdersByInterrupts() throws {
        let interrupts = [Interrupt(id: "a", reason: .toolCall), Interrupt(id: "b", reason: .confirmation)]
        let entries = try StatefulAgUiAgent.buildResumeArray(
            interrupts: interrupts,
            responses: [
                "b": .cancelled(interruptId: "b"),
                "a": .resolved(interruptId: "a", payload: Data("true".utf8)),
            ]
        )
        XCTAssertEqual(entries.map(\.interruptId), ["a", "b"])
        XCTAssertEqual(entries[0].status, .resolved)
        XCTAssertEqual(entries[1].status, .cancelled)
    }

    func testBuildResumeArrayThrowsOnMissingAndUnknown() {
        let interrupts = [Interrupt(id: "a", reason: .toolCall)]
        XCTAssertThrowsError(try StatefulAgUiAgent.buildResumeArray(interrupts: interrupts, responses: [:])) {
            XCTAssertEqual($0 as? InterruptError, .unansweredInterrupts(ids: ["a"]))
        }
        XCTAssertThrowsError(try StatefulAgUiAgent.buildResumeArray(
            interrupts: interrupts,
            responses: ["a": .cancelled(interruptId: "a"), "z": .cancelled(interruptId: "z")]
        )) {
            XCTAssertEqual($0 as? InterruptError, .unknownInterrupts(ids: ["z"]))
        }
    }

    // MARK: - AgUiAgent (stateless)

    private func statelessRun(
        _ agent: AgUiAgent,
        resume: [ResumeEntry]?,
        answering: [Interrupt]? = nil
    ) async -> Error? {
        do {
            for try await _ in agent.sendMessage("hi", threadId: "t", resume: resume, answering: answering) {}
            return nil
        } catch {
            return error
        }
    }

    func testAgUiAgentSendsResumeThatCoversAnsweredInterrupts() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let entries = [ResumeEntry.cancelled(interruptId: "i1")]
        let first = await statelessRun(agent, resume: entries, answering: [Interrupt(id: "i1", reason: .toolCall)])
        let second = await statelessRun(agent, resume: nil)
        XCTAssertNil(first)
        XCTAssertNil(second)

        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs[0].resume, entries)
        XCTAssertNil(inputs[1].resume)
    }

    func testAgUiAgentRejectsResumeThatLeavesAnInterruptUncovered() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(
            agent,
            resume: [.cancelled(interruptId: "i1")],
            answering: [Interrupt(id: "i1", reason: .toolCall), Interrupt(id: "i2", reason: .toolCall)]
        )
        XCTAssertEqual(error as? InterruptError, .unansweredInterrupts(ids: ["i2"]))
        let inputs = await transport.capturedInputs
        XCTAssertTrue(inputs.isEmpty, "Nothing should be sent")
    }

    func testAgUiAgentRejectsResumeWithoutTheInterruptsItAnswers() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(agent, resume: [.cancelled(interruptId: "i1")])
        XCTAssertEqual(error as? InterruptError, .unknownInterrupts(ids: ["i1"]))
        let inputs = await transport.capturedInputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testAgUiAgentRejectsResolvedAnswerToExpiredInterrupt() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(
            agent,
            resume: [.resolved(interruptId: "i1")],
            answering: [Interrupt(id: "i1", reason: .toolCall, expiresAt: past())]
        )
        XCTAssertEqual(error as? InterruptError, .expired(id: "i1"))
        let inputs = await transport.capturedInputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testAgUiAgentSendsCancelledAnswerToExpiredInterrupt() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(
            agent,
            resume: [.cancelled(interruptId: "i1")],
            answering: [Interrupt(id: "i1", reason: .toolCall, expiresAt: past())]
        )
        XCTAssertNil(error)
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1)
    }

    func testAgUiAgentRejectsNewMessageWhileInterruptsArePending() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(agent, resume: nil, answering: [Interrupt(id: "i1", reason: .toolCall)])
        XCTAssertEqual(error as? InterruptError, .unansweredInterrupts(ids: ["i1"]))
        let inputs = await transport.capturedInputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testAgUiAgentSendsNewMessageWhenNoInterruptsArePending() async throws {
        let transport = CapturingTransport()
        let agent = AgUiAgent(transport: transport)
        let error = await statelessRun(agent, resume: nil, answering: [])
        XCTAssertNil(error)
        let inputs = await transport.capturedInputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertNil(inputs[0].resume)
    }
}
