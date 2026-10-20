// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUIClient
import AGUICore
import AGUITools
import Foundation

/// Stateful AG-UI agent that automatically manages conversation history.
///
/// `StatefulAgUiAgent` provides a high-level, iOS-friendly API for building
/// conversational AI interfaces. It automatically tracks message history per thread,
/// manages state updates, and provides convenient methods for common patterns.
///
public final class StatefulAgUiAgent: Sendable {
    /// The underlying HTTP agent for communication.
    private let httpAgent: HttpAgent

    /// Injected transport used in place of `httpAgent` when present (test path).
    private let agentTransport: (any AgentTransport)?

    /// Manager for conversation histories across threads.
    private let historyManager: ConversationHistoryManager

    /// Configuration for this agent.
    public let config: StatefulAgUiAgentConfig

    /// Actor for managing current state (thread-safe).
    private let stateManager: StateManager

    /// Interrupts from each thread's most recent run, awaiting a resume.
    private let interruptManager = InterruptManager()

    /// Optional tool execution manager. Created when `config.toolRegistry` is set.
    private let toolExecutionManager: ToolExecutionManager?

    /// Creates a new stateful agent with a base URL.
    ///
    /// - Parameter baseURL: The base URL of the AG-UI agent server
    ///
    /// ## Example
    ///
    /// ```swift
    /// let agent = StatefulAgUiAgent(baseURL: URL(string: "https://agent.example.com")!)
    /// ```
    public convenience init(baseURL: URL) {
        self.init(configuration: StatefulAgUiAgentConfig(baseURL: baseURL))
    }

    /// Creates a new stateful agent with custom configuration.
    ///
    /// - Parameter configuration: The stateful agent configuration
    ///
    /// ## Example
    ///
    /// ```swift
    /// var config = StatefulAgUiAgentConfig(baseURL: agentURL)
    /// config.systemPrompt = "You are helpful"
    /// config.maxHistoryLength = 100
    ///
    /// let agent = StatefulAgUiAgent(configuration: config)
    /// ```
    public init(configuration: StatefulAgUiAgentConfig) {
        self.config = configuration
        let agent = HttpAgent(configuration: HttpAgentConfiguration(
            baseURL: configuration.baseURL,
            timeout: configuration.timeout,
            headers: configuration.headers,
            debug: configuration.debug
        ))
        self.httpAgent = agent
        self.agentTransport = nil
        self.historyManager = ConversationHistoryManager()
        self.stateManager = StateManager(initialState: configuration.initialState)
        if let registry = configuration.toolRegistry {
            self.toolExecutionManager = ToolExecutionManager(
                toolRegistry: registry,
                responseHandler: ClientToolResponseHandler(httpAgent: agent, endpoint: configuration.endpoint)
            )
        } else {
            self.toolExecutionManager = nil
        }
    }

    /// Creates a stateful agent backed by a custom transport (test path).
    ///
    /// Use this initializer in tests to inject a mock transport instead of
    /// making real HTTP connections.
    init(transport: any AgentTransport, config: StatefulAgUiAgentConfig) {
        self.config = config
        let url = URL(string: "https://placeholder.local")!
        self.httpAgent = HttpAgent(baseURL: url)
        self.agentTransport = transport
        self.historyManager = ConversationHistoryManager()
        self.stateManager = StateManager(initialState: config.initialState)
        self.toolExecutionManager = nil
    }

    /// Sends a chat message with automatic history management.
    ///
    /// This is a convenience method that delegates to ``sendMessage(message:threadId:state:includeSystemPrompt:)``
    /// with sensible defaults for casual chat interactions.
    ///
    /// - Parameters:
    ///   - message: The user's message text
    ///   - threadId: The conversation thread ID (default: "default")
    /// - Returns: Event stream from the agent
    /// - Throws: `ClientError` if the request fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let stream = try await agent.chat(message: "Hello!")
    /// for try await event in stream {
    ///     // Process events
    /// }
    /// ```
    public func chat(
        message: String,
        threadId: String = "default"
    ) async throws -> AsyncThrowingStream<any AGUIEvent, Error> {
        let currentState = await stateManager.currentState()
        return try await sendMessage(
            message: message,
            threadId: threadId,
            state: currentState,
            includeSystemPrompt: true
        )
    }

    /// Sends a message with full control over state and system prompt.
    ///
    /// This method provides complete control over the message sending process,
    /// including custom state and system prompt inclusion.
    ///
    /// - Parameters:
    ///   - message: The user's message text
    ///   - threadId: The conversation thread ID
    ///   - state: Custom state to send (defaults to current state)
    ///   - includeSystemPrompt: Whether to add system prompt for new threads (default: true)
    /// - Returns: Event stream from the agent
    /// - Throws: ``InterruptError/unansweredInterrupts(ids:)`` if the thread has pending
    ///   interrupts (answer them with ``resume(threadId:entries:)`` first), or
    ///   `ClientError` if the request fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let customState = Data("{\"mode\":\"creative\"}".utf8)
    /// let stream = try await agent.sendMessage(
    ///     message: "Tell me a story",
    ///     threadId: "story-session",
    ///     state: customState,
    ///     includeSystemPrompt: true
    /// )
    /// ```
    public func sendMessage(
        message: String,
        threadId: String,
        state: State?,
        includeSystemPrompt: Bool
    ) async throws -> AsyncThrowingStream<any AGUIEvent, Error> {
        // A thread paused on an interrupt can only continue through resume(threadId:entries:).
        let pending = await interruptManager.pending(for: threadId)
        if !pending.isEmpty {
            throw InterruptError.unansweredInterrupts(ids: pending.map(\.id))
        }

        // Get conversation history for this thread
        var history = await historyManager.history(for: threadId)

        // Add system prompt if it's the first message and includeSystemPrompt is true
        if history.isEmpty && includeSystemPrompt, let systemPrompt = config.systemPrompt {
            let systemMessage = SystemMessage(
                id: "sys_\(UUID().uuidString)",
                content: systemPrompt
            )
            await historyManager.append(message: systemMessage, to: threadId)
            history.append(systemMessage)
        }

        // Create and add the user message
        let userMessage = UserMessage(
            id: "usr_\(UUID().uuidString)",
            content: message
        )
        await historyManager.append(message: userMessage, to: threadId)
        history.append(userMessage)

        // Apply history length limit if configured
        if config.maxHistoryLength > 0 {
            await historyManager.trim(threadId: threadId, maxLength: config.maxHistoryLength)
            history = await historyManager.history(for: threadId)
        }

        // Use the provided state or the current state
        let stateToUse: State
        if let providedState = state {
            stateToUse = providedState
        } else {
            stateToUse = await stateManager.currentState()
        }

        return try await startRun(threadId: threadId, history: history, state: stateToUse, resume: nil)
    }

    /// Continues a thread that paused on an interrupt.
    ///
    /// Starts a new run on the same thread with a fresh run ID, the existing history
    /// (no user message is added), the current state, tools, and context, plus `entries`
    /// as the run's `resume` field. Nothing is sent if validation fails.
    ///
    /// - Parameters:
    ///   - threadId: The thread whose interrupts are being answered
    ///   - entries: One entry per pending interrupt
    /// - Returns: Event stream from the agent
    /// - Throws: ``InterruptError`` if `entries` leave a pending interrupt unanswered,
    ///   name an interrupt that is not pending, or answer an expired interrupt with
    ///   anything but `.cancelled`; `ClientError` if the request fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let pending = await agent.pendingInterrupts(for: "chat-1")
    /// let entries = pending.map { ResumeEntry.resolved(interruptId: $0.id, payload: Data("{\"approved\":true}".utf8)) }
    /// let stream = try await agent.resume(threadId: "chat-1", entries: entries)
    /// ```
    public func resume(
        threadId: String,
        entries: [ResumeEntry]
    ) async throws -> AsyncThrowingStream<any AGUIEvent, Error> {
        let pending = await interruptManager.pending(for: threadId)
        try Self.validateResume(entries: entries, pending: pending)

        let history = await historyManager.history(for: threadId)
        let currentState = await stateManager.currentState()
        return try await startRun(threadId: threadId, history: history, state: currentState, resume: entries)
    }

    /// The interrupts that ended a thread's most recent run and are still awaiting an answer.
    ///
    /// - Parameter threadId: The thread ID
    /// - Returns: The pending interrupts, or an empty array if the last run did not pause
    public func pendingInterrupts(for threadId: String) async -> [Interrupt] {
        await interruptManager.pending(for: threadId)
    }

    /// Builds a `resume` array with one entry per interrupt, in interrupt order.
    ///
    /// Mirrors `buildResumeArray` in the TypeScript SDK.
    ///
    /// - Parameters:
    ///   - interrupts: The interrupts to answer
    ///   - responses: The response for each interrupt, keyed by interrupt ID
    /// - Returns: The resume entries
    /// - Throws: ``InterruptError/unansweredInterrupts(ids:)`` if an interrupt has no
    ///   response, or ``InterruptError/unknownInterrupts(ids:)`` if a response names
    ///   an interrupt that is not in `interrupts`
    public static func buildResumeArray(
        interrupts: [Interrupt],
        responses: [String: ResumeEntry]
    ) throws -> [ResumeEntry] {
        let ids = Set(interrupts.map(\.id))
        let missing = interrupts.map(\.id).filter { responses[$0] == nil }
        if !missing.isEmpty {
            throw InterruptError.unansweredInterrupts(ids: missing)
        }
        let unknown = responses.keys.filter { !ids.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw InterruptError.unknownInterrupts(ids: unknown)
        }
        return interrupts.compactMap { interrupt in
            responses[interrupt.id].map {
                ResumeEntry(
                    interruptId: interrupt.id,
                    status: $0.status,
                    payload: $0.status == .resolved ? $0.payload : nil,
                    metadata: $0.metadata
                )
            }
        }
    }

    /// Retrieves the conversation history for a thread.
    ///
    /// - Parameter threadId: The thread ID (default: "default")
    /// - Returns: Array of messages in chronological order
    ///
    /// ## Example
    ///
    /// ```swift
    /// let history = await agent.history(for: "chat-session")
    /// print("Conversation has \(history.count) messages")
    /// ```
    public func history(for threadId: String = "default") async -> [any Message] {
        await historyManager.history(for: threadId)
    }

    /// Clears conversation history, and any pending interrupts, for one or all threads.
    ///
    /// - Parameter threadId: The thread ID to clear, or `nil` to clear all threads
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Clear specific thread
    /// await agent.clearHistory(threadId: "chat-1")
    ///
    /// // Clear all threads
    /// await agent.clearHistory()
    /// ```
    public func clearHistory(threadId: String? = nil) async {
        await historyManager.clear(threadId: threadId)
        await interruptManager.clear(threadId: threadId)
    }

    // MARK: - Private Helpers

    /// Builds the run input, starts the run, and wraps the stream with tool execution
    /// and history and state tracking. Shared by ``sendMessage(message:threadId:state:includeSystemPrompt:)``
    /// and ``resume(threadId:entries:)``.
    private func startRun(
        threadId: String,
        history: [any Message],
        state stateToUse: State,
        resume: [ResumeEntry]?
    ) async throws -> AsyncThrowingStream<any AGUIEvent, Error> {
        // Build the base run input
        var builder = RunAgentInput.builder()
            .threadId(threadId)
            .runId("run_\(UUID().uuidString)")
            .messages(history)
            .state(stateToUse)
        if let resume {
            builder = builder.resume(resume)
        }
        let baseInput = try builder.build()

        // Include tool definitions if a registry is configured
        let inputWithTools: RunAgentInput
        if let registry = config.toolRegistry {
            let tools = await registry.allTools()
            inputWithTools = RunAgentInput(
                threadId: baseInput.threadId,
                runId: baseInput.runId,
                parentRunId: baseInput.parentRunId,
                state: baseInput.state,
                messages: baseInput.messages,
                tools: tools,
                context: config.context.isEmpty ? baseInput.context : config.context,
                forwardedProps: baseInput.forwardedProps,
                resume: baseInput.resume
            )
        } else {
            inputWithTools = RunAgentInput(
                threadId: baseInput.threadId,
                runId: baseInput.runId,
                parentRunId: baseInput.parentRunId,
                state: baseInput.state,
                messages: baseInput.messages,
                tools: baseInput.tools,
                context: config.context.isEmpty ? baseInput.context : config.context,
                forwardedProps: baseInput.forwardedProps,
                resume: baseInput.resume
            )
        }

        // Execute the run and obtain an event stream
        let eventStream: AsyncThrowingStream<any AGUIEvent, Error>

        if let transport = agentTransport {
            // Test path: transport yields events directly
            let rawStream = transport.run(input: inputWithTools)
            if let manager = toolExecutionManager {
                eventStream = await manager.processEventStream(
                    rawStream,
                    threadId: inputWithTools.threadId,
                    runId: inputWithTools.runId
                )
            } else {
                eventStream = rawStream
            }
        } else {
            // Production path: httpAgent performs SSE over HTTP
            let rawStream = try await httpAgent.run(inputWithTools, endpoint: config.endpoint)
            if let manager = toolExecutionManager {
                eventStream = await manager.processEventStream(
                    rawStream,
                    threadId: inputWithTools.threadId,
                    runId: inputWithTools.runId
                )
            } else {
                eventStream = AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            for try await event in rawStream { continuation.yield(event) }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }

        // Wrap the stream to track history and state updates
        return trackHistoryAndState(stream: eventStream, threadId: threadId)
    }

    /// Checks that `entries` answer exactly the pending interrupts, and that none that
    /// has expired is answered with anything but `.cancelled`.
    static func validateResume(
        entries: [ResumeEntry],
        pending: [Interrupt],
        now: Date = Date()
    ) throws {
        let answered = Set(entries.map(\.interruptId))
        let pendingIds = Set(pending.map(\.id))

        let unanswered = pending.map(\.id).filter { !answered.contains($0) }
        if !unanswered.isEmpty {
            throw InterruptError.unansweredInterrupts(ids: unanswered)
        }

        var unknown: [String] = []
        for entry in entries where !pendingIds.contains(entry.interruptId) && !unknown.contains(entry.interruptId) {
            unknown.append(entry.interruptId)
        }
        if !unknown.isEmpty {
            throw InterruptError.unknownInterrupts(ids: unknown)
        }

        for interrupt in pending where InterruptExpiry.isExpired(interrupt, now: now) {
            let isCancelled = entries.first { $0.interruptId == interrupt.id }?.status == .cancelled
            if !isCancelled {
                throw InterruptError.expired(id: interrupt.id)
            }
        }
    }

    /// Wraps an event stream to track assistant messages, tool calls, state updates, and pending interrupts.
    private func trackHistoryAndState<S: AsyncSequence>(
        stream: S,
        threadId: String
    ) -> AsyncThrowingStream<any AGUIEvent, Error> where S.Element == any AGUIEvent {
        AsyncThrowingStream { continuation in
            let task = Task {
                var currentAssistantMessage: AssistantMessage?
                let patchApplicator = PatchApplicator()
                let messageDecoder = MessageDecoder()

                do {
                    for try await event in stream {
                        // Yield the event downstream
                        continuation.yield(event)

                        // Track assistant messages, tool calls, and state
                        switch event {

                        // MARK: Text messages

                        case let start as TextMessageStartEvent:
                            currentAssistantMessage = AssistantMessage(
                                id: start.messageId,
                                content: ""
                            )

                        case let content as TextMessageContentEvent:
                            if let msg = currentAssistantMessage, msg.id == content.messageId {
                                let updatedContent = (msg.content ?? "") + content.delta
                                currentAssistantMessage = AssistantMessage(
                                    id: msg.id,
                                    content: updatedContent,
                                    name: msg.name,
                                    toolCalls: msg.toolCalls
                                )
                            }

                        case let end as TextMessageEndEvent:
                            if let msg = currentAssistantMessage, msg.id == end.messageId {
                                await self.historyManager.append(message: msg, to: threadId)
                                currentAssistantMessage = nil
                            }

                        // MARK: Tool calls

                        case let start as ToolCallStartEvent:
                            let newCall = ToolCall(
                                id: start.toolCallId,
                                function: FunctionCall(name: start.toolCallName, arguments: "")
                            )
                            if let msg = currentAssistantMessage {
                                var calls = msg.toolCalls ?? []
                                calls.append(newCall)
                                currentAssistantMessage = AssistantMessage(
                                    id: msg.id,
                                    content: msg.content,
                                    name: msg.name,
                                    toolCalls: calls
                                )
                            } else {
                                currentAssistantMessage = AssistantMessage(
                                    id: "asst_\(UUID().uuidString)",
                                    content: nil,
                                    toolCalls: [newCall]
                                )
                            }

                        case let args as ToolCallArgsEvent:
                            if let msg = currentAssistantMessage,
                               let calls = msg.toolCalls,
                               let idx = calls.firstIndex(where: { $0.id == args.toolCallId }) {
                                let call = calls[idx]
                                let updatedCall = ToolCall(
                                    id: call.id,
                                    function: FunctionCall(
                                        name: call.function.name,
                                        arguments: call.function.arguments + args.delta
                                    )
                                )
                                var updatedCalls = calls
                                updatedCalls[idx] = updatedCall
                                currentAssistantMessage = AssistantMessage(
                                    id: msg.id,
                                    content: msg.content,
                                    name: msg.name,
                                    toolCalls: updatedCalls
                                )
                            }

                        case is ToolCallEndEvent:
                            // Do NOT append the assistant message here. For multi-tool-call sequences
                            // (ToolCallStart→ToolCallEnd×N), appending at every ToolCallEnd caused N
                            // duplicates in history. The assistant message is flushed at:
                            //   • TextMessageEndEvent (text + optional tool calls)
                            //   • The first ToolCallResultEvent (tool-call-only turns)
                            break

                        case let result as ToolCallResultEvent:
                            // Flush a pending tool-call-only assistant message before recording the
                            // tool result. This handles turns where ToolCallStart/End events fire
                            // without a surrounding TextMessageStart/End envelope.
                            if let msg = currentAssistantMessage {
                                await self.historyManager.append(message: msg, to: threadId)
                                currentAssistantMessage = nil
                            }
                            let toolMessage = ToolMessage(
                                id: result.messageId,
                                content: result.content,
                                toolCallId: result.toolCallId
                            )
                            await self.historyManager.append(message: toolMessage, to: threadId)

                        // MARK: Run lifecycle

                        case let finished as RunFinishedEvent:
                            // An interrupt outcome pauses the thread; any other outcome clears it.
                            await self.interruptManager.set(finished.outcome.interrupts, for: threadId)

                        // MARK: State events

                        case let snapshot as StateSnapshotEvent:
                            await self.stateManager.updateState(snapshot.snapshot)

                        case let delta as StateDeltaEvent:
                            let currentState = await self.stateManager.currentState()
                            if let newState = try? patchApplicator.apply(patch: delta.delta, to: currentState) {
                                await self.stateManager.updateState(newState)
                            }

                        case let msgSnapshot as MessagesSnapshotEvent:
                            // Replace the thread history with the authoritative snapshot.
                            if let rawArray = try? JSONSerialization.jsonObject(with: msgSnapshot.messages) as? [[String: Any]] {
                                let msgs: [any Message] = rawArray.compactMap { dict in
                                    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                                    return try? messageDecoder.decode(data)
                                }
                                await self.historyManager.clear(threadId: threadId)
                                for msg in msgs {
                                    await self.historyManager.append(message: msg, to: threadId)
                                }
                            }

                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - StateManager

/// Thread-safe actor for managing agent state.
private actor StateManager {
    private var currentStateValue: State

    init(initialState: State) {
        self.currentStateValue = initialState
    }

    func currentState() -> State {
        currentStateValue
    }

    func updateState(_ newState: State) {
        currentStateValue = newState
    }
}

// MARK: - InterruptManager

/// Thread-safe actor for tracking each thread's pending interrupts.
private actor InterruptManager {
    private var interruptsByThread: [String: [Interrupt]] = [:]

    func pending(for threadId: String) -> [Interrupt] {
        interruptsByThread[threadId] ?? []
    }

    func set(_ interrupts: [Interrupt], for threadId: String) {
        interruptsByThread[threadId] = interrupts.isEmpty ? nil : interrupts
    }

    func clear(threadId: String?) {
        if let threadId {
            interruptsByThread[threadId] = nil
        } else {
            interruptsByThread.removeAll()
        }
    }
}
