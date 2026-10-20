// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUIClient
import AGUICore
import AGUITools
import Foundation

public final class AgUiAgent: Sendable {

    // MARK: - Public properties

    public let config: AgUiAgentConfig

    // MARK: - Private state

    private let transport: any AgentTransport
    private let httpAgent: HttpAgent
    private let toolExecutionManager: ToolExecutionManager?

    // MARK: - Initialization

    public init(
        url: URL,
        configure: (inout AgUiAgentConfig) -> Void = { _ in }
    ) {
        var cfg = AgUiAgentConfig()
        configure(&cfg)
        self.config = cfg

        var httpConfig = HttpAgentConfiguration(baseURL: url)
        httpConfig.timeout = cfg.requestTimeout
        httpConfig.retryPolicy = cfg.retryPolicy
        httpConfig.headers = cfg.buildHeaders()

        let agent = HttpAgent(configuration: httpConfig)
        self.httpAgent = agent
        self.transport = HttpAgentTransport(configuration: httpConfig)

        if let registry = cfg.toolRegistry {
            self.toolExecutionManager = ToolExecutionManager(
                toolRegistry: registry,
                responseHandler: ClientToolResponseHandler(httpAgent: agent)
            )
        } else {
            self.toolExecutionManager = nil
        }
    }

    public init(
        transport: any AgentTransport,
        config: AgUiAgentConfig = AgUiAgentConfig(),
        toolExecutionManager: ToolExecutionManager? = nil
    ) {
        self.config = config
        self.transport = transport
        let url = URL(string: "https://placeholder.local")!
        self.httpAgent = HttpAgent(baseURL: url)
        self.toolExecutionManager = toolExecutionManager
    }

    // MARK: - Core run method

    /// Runs the input as given.
    ///
    /// - Note: This does not validate `input.resume`; the caller owns interrupt
    ///   coverage. Use ``sendMessage(_:threadId:state:includeSystemPrompt:resume:answering:)``
    ///   for the checked path.
    public func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
        transport.run(input: input)
    }

    // MARK: - sendMessage (primary API)

    /// Sends a message in a new run.
    ///
    /// - Parameters:
    ///   - message: The user's message text
    ///   - threadId: The conversation thread ID (defaults to a new UUID)
    ///   - state: State to send (defaults to an empty object)
    ///   - includeSystemPrompt: Whether to prepend the configured system prompt
    ///   - resume: Answers to the interrupts that ended the previous run on this
    ///     thread, if this run continues from one
    ///   - answering: The interrupts that ended the previous run. This agent keeps no
    ///     history, so the caller supplies them (from the `RUN_FINISHED` outcome) and
    ///     `resume` is checked against them with ``ResumeValidator`` before anything is
    ///     sent. Omitting them while passing `resume` fails with
    ///     ``InterruptError/unknownInterrupts(ids:)``.
    /// - Note: The returned stream fails with ``InterruptError`` if `resume` does not
    ///   match `answering` (including `answering` interrupts with no `resume` at all),
    ///   without making a request. ``run(input:)`` does no such
    ///   check; callers that build the input themselves own coverage.
    public func sendMessage(
        _ message: String,
        threadId: String = UUID().uuidString,
        state: State? = nil,
        includeSystemPrompt: Bool = true,
        resume: [ResumeEntry]? = nil,
        answering: [Interrupt]? = nil
    ) -> AsyncThrowingStream<any AGUIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if resume != nil || !(answering ?? []).isEmpty {
                        try ResumeValidator.validate(entries: resume ?? [], pending: answering ?? [])
                    }

                    var messages: [any Message] = []

                    if includeSystemPrompt, let prompt = self.config.systemPrompt {
                        messages.append(SystemMessage(
                            id: "sys_\(UUID().uuidString)",
                            content: prompt
                        ))
                    }

                    messages.append(UserMessage(
                        id: "usr_\(UUID().uuidString)",
                        content: message
                    ))

                    var tools: [Tool] = []
                    if let registry = self.config.toolRegistry {
                        tools = await registry.allTools()
                    }

                    let input = RunAgentInput(
                        threadId: threadId,
                        runId: "run_\(UUID().uuidString)",
                        state: state ?? Data("{}".utf8),
                        messages: messages,
                        tools: tools,
                        context: self.config.context,
                        forwardedProps: self.config.forwardedProps,
                        resume: resume
                    )

                    let rawStream = self.run(input: input)

                    if let manager = self.toolExecutionManager {
                        let managed = await manager.processEventStream(
                            rawStream,
                            threadId: input.threadId,
                            runId: input.runId
                        )
                        for try await event in managed {
                            continuation.yield(event)
                        }
                    } else {
                        for try await event in rawStream {
                            continuation.yield(event)
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

    // MARK: - Subscriber

    public func subscribe(_ subscriber: any AgentSubscriber) async -> any AgentSubscription {
        await httpAgent.subscribe(subscriber)
    }

    // MARK: - Lifecycle

    public func close() async {
        if let manager = toolExecutionManager {
            await manager.cancelAllExecutions()
        }
        await httpAgent.dispose()
    }
}

/// The error thrown when a resume list does not match a thread's pending interrupts.
public typealias InterruptError = AGUICore.InterruptError
