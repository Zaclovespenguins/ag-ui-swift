// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

// MARK: - AgentStorage

internal actor AgentStorage {
    var messages: [any Message] = []
    var currentState: State = Data("{}".utf8)
    var rawEvents: [RawEvent] = []
    var customEvents: [CustomEvent] = []
    var currentTask: Task<Void, Error>?
    var isDisposed: Bool = false
}

// MARK: - AgentStorage Mutation Helpers

internal extension AgentStorage {
    func setMessages(_ messages: [any Message]) { self.messages = messages }
    func setState(_ state: State) { self.currentState = state }
    func setRawEvents(_ rawEvents: [RawEvent]) { self.rawEvents = rawEvents }
    func setCustomEvents(_ customEvents: [CustomEvent]) { self.customEvents = customEvents }
    func setCurrentTask(_ task: Task<Void, Error>?) { self.currentTask = task }
    func setDisposed(_ disposed: Bool) { self.isDisposed = disposed }
}

// MARK: - RunOutcomeRecorder

/// Remembers the outcome of the `RUN_FINISHED` event a run delivered, so the
/// pipeline can tell a cancelled run from a completed one.
private actor RunOutcomeRecorder {
    private(set) var outcome: RunFinishedOutcome?
    private(set) var failure: RunErrorEvent?

    func observe(_ event: any AGUIEvent) {
        if event is RunStartedEvent {
            outcome = nil
            failure = nil
        } else if let failed = event as? RunErrorEvent {
            failure = failed
            outcome = nil
        } else if let finished = event as? RunFinishedEvent {
            outcome = finished.outcome
        }
    }
}

// MARK: - AbstractAgent

public final class AbstractAgent: Sendable {

    // MARK: - Internal storage

    internal let storage: AgentStorage
    internal let subscriberManager: SubscriberManager

    // MARK: - Transport

    private let transport: any AgentTransport

    // MARK: - Configuration (immutable after init)

    public let debug: Bool

    // MARK: - Initialization

    public init(transport: any AgentTransport, debug: Bool = false) {
        self.transport = transport
        self.storage = AgentStorage()
        self.subscriberManager = SubscriberManager()
        self.debug = debug
    }

    // MARK: - Async state accessors (cross actor boundary)

    public var messages: [any Message] { get async { await storage.messages } }

    public var state: State { get async { await storage.currentState } }

    public var rawEvents: [RawEvent] { get async { await storage.rawEvents } }

    public var customEvents: [CustomEvent] { get async { await storage.customEvents } }

    // MARK: - Run method

    public func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
        transport.run(input: input)
    }

    // MARK: - Public pipeline methods

    public func runAgent(
        parameters: RunAgentParameters? = nil,
        subscriber: (any AgentSubscriber)? = nil
    ) async throws {
        guard await !storage.isDisposed else { return }

        let input = buildInput(from: parameters)

        let registeredSubscribers = await subscriberManager.allSubscribers()
        var allSubscribers = registeredSubscribers
        if let s = subscriber { allSubscribers.append(s) }

        let initMutation = await runSubscribersWithMutation(
            subscribers: allSubscribers,
            messages: await storage.messages,
            state: await storage.currentState
        ) { sub, msgs, st in
            let params = AgentSubscriberParams(messages: msgs, state: st, input: input)
            return await sub.onRunInitialized(params: params)
        }
        if let msgs = initMutation.messages { await storage.setMessages(msgs) }
        if let st = initMutation.state { await storage.setState(st) }

        let task = Task<Void, Error> {
            do {
                let eventStream = self.run(input: input)
                let recorder = RunOutcomeRecorder()
                let processedStream = eventStream
                    .transformChunks()
                    .verifyEvents(debug: self.debug)
                    .map { (event: any AGUIEvent) -> any AGUIEvent in
                        await recorder.observe(event)
                        return event
                    }
                    .applyEvents(input: input, subscribers: allSubscribers)

                for try await agentState in processedStream {
                    await self.applyAgentState(agentState, input: input, subscribers: allSubscribers)
                }

                if let failure = await recorder.failure {
                    throw AgentRunError(event: failure)
                }

                let finalMessages = await self.storage.messages
                let finalState = await self.storage.currentState
                // A cancelled run (a `.cancelled` RUN_FINISHED, or a local abort) is
                // neither a success nor an error: report it on its own hook.
                let wasCancelled = await recorder.outcome == .cancelled || Task.isCancelled
                _ = await runSubscribersWithMutation(
                    subscribers: allSubscribers,
                    messages: finalMessages,
                    state: finalState
                ) { sub, msgs, st in
                    let params = AgentSubscriberParams(messages: msgs, state: st, input: input)
                    if wasCancelled {
                        return await sub.onRunCancelled(params: params)
                    }
                    return await sub.onRunFinalized(params: params)
                }
            } catch where error is CancellationError || (error as? ClientError) == .cancelled {
                // Cancelled locally: not an error. Subscribers hear onRunCancelled;
                // the error still propagates to the caller of runAgent.
                let currentMsgs = await self.storage.messages
                let currentSt = await self.storage.currentState
                _ = await runSubscribersWithMutation(
                    subscribers: allSubscribers,
                    messages: currentMsgs,
                    state: currentSt
                ) { sub, msgs, st in
                    let params = AgentSubscriberParams(messages: msgs, state: st, input: input)
                    return await sub.onRunCancelled(params: params)
                }
                throw error
            } catch {
                let currentMsgs = await self.storage.messages
                let currentSt = await self.storage.currentState
                _ = await runSubscribersWithMutation(
                    subscribers: allSubscribers,
                    messages: currentMsgs,
                    state: currentSt
                ) { sub, msgs, st in
                    let params = AgentRunFailureParams(error: error, messages: msgs, state: st, input: input)
                    return await sub.onRunFailed(params: params)
                }
                throw error
            }
        }

        await storage.setCurrentTask(task)
        let result = await task.result
        await storage.setCurrentTask(nil)
        try result.get()
    }

    public func runAgentObservable(
        input: RunAgentInput
    ) -> AsyncThrowingStream<any AGUIEvent, Error> {
        run(input: input)
            .transformChunks()
            .verifyEvents(debug: debug)
    }

    public func abortRun() async {
        await storage.currentTask?.cancel()
    }

    public func dispose() async {
        await storage.setDisposed(true)
    }

    public func subscribe(_ subscriber: any AgentSubscriber) async -> any AgentSubscription {
        let id = await subscriberManager.subscribe(subscriber)
        return DefaultAgentSubscription {
            await self.subscriberManager.unsubscribe(id)
        }
    }

    // MARK: - Internal helpers

    internal func buildInput(from parameters: RunAgentParameters?) -> RunAgentInput {
        RunAgentInput(
            threadId: "default",
            runId: parameters?.runId ?? "run_\(UUID().uuidString)",
            tools: parameters?.tools ?? [],
            context: parameters?.context ?? [],
            forwardedProps: parameters?.forwardedProps ?? Data("{}".utf8),
            resume: parameters?.resume
        )
    }

    internal func applyAgentState(
        _ agentState: AgentState,
        input: RunAgentInput,
        subscribers: [any AgentSubscriber]
    ) async {
        if let messages = agentState.messages {
            await storage.setMessages(messages)
            let params = AgentStateChangedParams(
                messages: messages,
                state: await storage.currentState,
                input: input
            )
            for sub in subscribers { await sub.onMessagesChanged(params: params) }
        }
        if let state = agentState.state {
            await storage.setState(state)
            let msgs = await storage.messages
            let params = AgentStateChangedParams(messages: msgs, state: state, input: input)
            for sub in subscribers { await sub.onStateChanged(params: params) }
        }
        if let rawEvents = agentState.rawEvents {
            await storage.setRawEvents(rawEvents)
        }
        if let customEvents = agentState.customEvents {
            await storage.setCustomEvents(customEvents)
        }
    }
}
