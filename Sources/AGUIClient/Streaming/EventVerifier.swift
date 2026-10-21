// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

// MARK: - AGUIProtocolError

/// An error thrown when the AG-UI protocol event sequence is violated.
///
/// This is how a stream *the consumer rejected* surfaces. It is deliberately a
/// different thing from a producer-sent `RUN_ERROR`, which is delivered to the
/// caller as an ordinary ``RunErrorEvent`` and never thrown by the verifier.
public struct AGUIProtocolError: Error, Sendable {
    /// A human-readable description of the protocol violation.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - AGUIProtocolWarning

/// A non-fatal observation made while verifying a stream.
///
/// Warnings are reported through the `onWarning` hook of
/// ``Swift/AsyncSequence/verifyEvents(debug:onWarning:)``. The package has no
/// logging framework yet; routing these to a logger is a deferred decision.
public struct AGUIProtocolWarning: Sendable, Hashable {
    /// A human-readable description of what was observed.
    public let message: String

    /// Creates a warning describing a non-fatal protocol condition.
    public init(message: String) {
        self.message = message
    }
}

// MARK: - EventVerifier

/// Internal state machine that validates AG-UI protocol event sequences.
///
/// All access to this class is serialized within a single Task, so no
/// actor isolation is needed.
private final class EventVerifier {
    private enum RunState {
        case idle, active, finished, errored
    }

    private struct OpenText {
        var role: String?
        var name: String?
        var fromChunk: Bool
    }

    private struct OpenTool {
        var name: String
        var parentMessageId: String?
        var fromChunk: Bool
    }

    private var state: RunState = .idle

    // Per-run tracking; reset by `resetRunTracking()`.
    private var activeMessages: [String: OpenText] = [:]
    private var closedMessages: [String: OpenText] = [:]
    private var activeToolCalls: [String: OpenTool] = [:]
    private var closedToolCalls: [String: OpenTool] = [:]
    private var activeSteps: Set<String> = []
    private var activeReasoningSpans: Set<String> = []
    private var activeReasoningMessages: [String: Bool] = [:] // id -> fromChunk
    private var chunkTextId: String?
    private var chunkToolId: String?
    private var chunkReasoningId: String?

    /// Activity message ids that have received a snapshot. Activity messages
    /// outlive a run, so this is not reset per run.
    private var activitySnapshots: Set<String> = []

    private let debug: Bool
    private let onWarning: (@Sendable (AGUIProtocolWarning) -> Void)?

    init(debug: Bool, onWarning: (@Sendable (AGUIProtocolWarning) -> Void)?) {
        self.debug = debug
        self.onWarning = onWarning
    }

    private func resetRunTracking() {
        activeMessages.removeAll()
        closedMessages.removeAll()
        activeToolCalls.removeAll()
        closedToolCalls.removeAll()
        activeSteps.removeAll()
        activeReasoningSpans.removeAll()
        activeReasoningMessages.removeAll()
        chunkTextId = nil
        chunkToolId = nil
        chunkReasoningId = nil
    }

    private func fail(_ message: String) -> AGUIProtocolError {
        AGUIProtocolError(message: message)
    }

    /// Verifies one event.
    ///
    /// - Returns: `true` if the event should be passed on, `false` if it is
    ///   skipped (with a warning).
    func verify(_ event: any AGUIEvent) throws -> Bool {
        let type = event.eventType.rawValue

        // A new RUN_STARTED always begins a fresh run, from any state.
        if event is RunStartedEvent {
            resetRunTracking()
            state = .active
            return true
        }

        if event is RunErrorEvent {
            switch state {
            case .errored:
                throw fail("Cannot send event type '\(type)': The run has already errored")
            case .idle, .active, .finished:
                // Ends whatever was open. After RUN_FINISHED this is a late
                // error: the run is treated as failed.
                resetRunTracking()
                state = .errored
            }
            return true
        }

        switch state {
        case .idle:
            throw fail("First event must be 'RUN_STARTED'")
        case .errored:
            throw fail("Cannot send event type '\(type)': The run has already errored")
        case .finished:
            throw fail("Cannot send event type '\(type)': The run has already finished")
        case .active:
            break
        }

        switch event {
        case let value as TextMessageStartEvent:
            try openText(id: value.messageId, role: value.role, name: nil, fromChunk: false)
        case let value as TextMessageContentEvent:
            guard activeMessages[value.messageId] != nil else {
                throw fail("No active text message found with ID '\(value.messageId)'")
            }
        case let value as TextMessageEndEvent:
            guard let open = activeMessages.removeValue(forKey: value.messageId) else {
                throw fail("No active text message found with ID '\(value.messageId)'")
            }
            closedMessages[value.messageId] = open
            if chunkTextId == value.messageId { chunkTextId = nil }
        case let value as TextMessageChunkEvent:
            try handleTextChunk(value)

        case let value as ToolCallStartEvent:
            try openTool(id: value.toolCallId, name: value.toolCallName, parent: value.parentMessageId, fromChunk: false)
        case let value as ToolCallArgsEvent:
            guard activeToolCalls[value.toolCallId] != nil else {
                throw fail("No active tool call found with ID '\(value.toolCallId)'")
            }
        case let value as ToolCallEndEvent:
            guard let open = activeToolCalls.removeValue(forKey: value.toolCallId) else {
                throw fail("No active tool call found with ID '\(value.toolCallId)'")
            }
            closedToolCalls[value.toolCallId] = open
            if chunkToolId == value.toolCallId { chunkToolId = nil }
        case let value as ToolCallChunkEvent:
            try handleToolChunk(value)

        case let value as StepStartedEvent:
            activeSteps.insert(value.stepName)
        case let value as StepFinishedEvent:
            guard activeSteps.remove(value.stepName) != nil else {
                throw fail("Cannot send 'STEP_FINISHED' for step '\(value.stepName)' that was not started")
            }

        case let value as ReasoningStartEvent:
            guard activeReasoningSpans.insert(value.messageId).inserted else {
                throw fail("A reasoning span with ID '\(value.messageId)' is already in progress")
            }
        case let value as ReasoningEndEvent:
            guard activeReasoningSpans.remove(value.messageId) != nil else {
                throw fail("No active reasoning span found with ID '\(value.messageId)'")
            }
        case let value as ReasoningMessageStartEvent:
            guard activeReasoningMessages[value.messageId] == nil else {
                throw fail("A reasoning message with ID '\(value.messageId)' is already in progress")
            }
            activeReasoningMessages[value.messageId] = false
        case let value as ReasoningMessageContentEvent:
            guard activeReasoningMessages[value.messageId] != nil else {
                throw fail("No active reasoning message found with ID '\(value.messageId)'")
            }
        case let value as ReasoningMessageEndEvent:
            guard activeReasoningMessages.removeValue(forKey: value.messageId) != nil else {
                throw fail("No active reasoning message found with ID '\(value.messageId)'")
            }
            if chunkReasoningId == value.messageId { chunkReasoningId = nil }
        case let value as ReasoningMessageChunkEvent:
            try handleReasoningChunk(value)

        case let value as ActivitySnapshotEvent:
            activitySnapshots.insert(value.messageId)
        case let value as ActivityDeltaEvent:
            guard activitySnapshots.contains(value.messageId) else {
                warn("Skipped ACTIVITY_DELTA for message '\(value.messageId)': no prior ACTIVITY_SNAPSHOT")
                return false
            }

        case is RunFinishedEvent:
            try finishRun()

        default:
            break
        }

        #if DEBUG
        if debug {
            print("[EventVerifier] Verified: \(type)")
        }
        #endif
        return true
    }

    // MARK: Text

    private func openText(id: String, role: String?, name: String?, fromChunk: Bool) throws {
        if activeMessages[id] != nil {
            throw fail("A text message with ID '\(id)' is already in progress")
        }
        if let closed = closedMessages[id], let role = role, let original = closed.role, role != original {
            throw fail("Cannot reopen text message '\(id)' with role '\(role)': it was opened with role '\(original)'")
        }
        activeMessages[id] = OpenText(role: role, name: name, fromChunk: fromChunk)
    }

    private func handleTextChunk(_ chunk: TextMessageChunkEvent) throws {
        guard let id = chunk.messageId ?? chunkTextId else {
            throw fail("The first TEXT_MESSAGE_CHUNK of a message must carry a 'messageId'")
        }
        if var open = activeMessages[id] {
            if let role = chunk.role, let original = open.role, role != original {
                throw fail("TEXT_MESSAGE_CHUNK for '\(id)' repeats role '\(role)' but the message has role '\(original)'")
            }
            if let name = chunk.name, let original = open.name, name != original {
                throw fail("TEXT_MESSAGE_CHUNK for '\(id)' repeats name '\(name)' but the message has name '\(original)'")
            }
            open.role = open.role ?? chunk.role
            open.name = open.name ?? chunk.name
            activeMessages[id] = open
        } else {
            closeChunkText()
            try openText(id: id, role: chunk.role, name: chunk.name, fromChunk: true)
        }
        chunkTextId = id
    }

    private func closeChunkText() {
        if let id = chunkTextId, let open = activeMessages[id], open.fromChunk {
            activeMessages.removeValue(forKey: id)
            closedMessages[id] = open
        }
        chunkTextId = nil
    }

    // MARK: Tool calls

    private func openTool(id: String, name: String, parent: String?, fromChunk: Bool) throws {
        if activeToolCalls[id] != nil {
            throw fail("A tool call with ID '\(id)' is already in progress")
        }
        if let closed = closedToolCalls[id] {
            if closed.name != name {
                throw fail(
                    "Cannot reopen tool call '\(id)' with toolCallName '\(name)': it was opened as '\(closed.name)'"
                )
            }
            if let parent = parent, let original = closed.parentMessageId, parent != original {
                throw fail("Cannot reopen tool call '\(id)' with a different parentMessageId")
            }
        }
        activeToolCalls[id] = OpenTool(name: name, parentMessageId: parent, fromChunk: fromChunk)
    }

    private func handleToolChunk(_ chunk: ToolCallChunkEvent) throws {
        guard let id = chunk.toolCallId ?? chunkToolId else {
            throw fail("The first TOOL_CALL_CHUNK of a call must carry 'toolCallId' and 'toolCallName'")
        }
        if var open = activeToolCalls[id] {
            if let name = chunk.toolCallName, name != open.name {
                throw fail("TOOL_CALL_CHUNK for '\(id)' repeats toolCallName '\(name)' but the call is '\(open.name)'")
            }
            if let parent = chunk.parentMessageId {
                if let original = open.parentMessageId, parent != original {
                    throw fail("TOOL_CALL_CHUNK for '\(id)' repeats a different parentMessageId")
                }
                open.parentMessageId = parent
                activeToolCalls[id] = open
            }
        } else {
            guard let name = chunk.toolCallName else {
                throw fail("The first TOOL_CALL_CHUNK of call '\(id)' must carry 'toolCallName'")
            }
            closeChunkTool()
            try openTool(id: id, name: name, parent: chunk.parentMessageId, fromChunk: true)
        }
        chunkToolId = id
    }

    private func closeChunkTool() {
        if let id = chunkToolId, let open = activeToolCalls[id], open.fromChunk {
            activeToolCalls.removeValue(forKey: id)
            closedToolCalls[id] = open
        }
        chunkToolId = nil
    }

    // MARK: Reasoning

    private func handleReasoningChunk(_ chunk: ReasoningMessageChunkEvent) throws {
        guard let id = chunk.messageId ?? chunkReasoningId else {
            throw fail("The first REASONING_MESSAGE_CHUNK of a message must carry a 'messageId'")
        }
        if activeReasoningMessages[id] == nil {
            if let prev = chunkReasoningId, activeReasoningMessages[prev] == true {
                activeReasoningMessages.removeValue(forKey: prev)
            }
            activeReasoningMessages[id] = true
        }
        chunkReasoningId = id
    }

    // MARK: Run end

    private func finishRun() throws {
        // Chunk-opened items have no explicit end; the run ending closes them.
        closeChunkText()
        closeChunkTool()
        activeReasoningMessages = activeReasoningMessages.filter { !$0.value }
        chunkReasoningId = nil

        if !activeMessages.isEmpty {
            throw fail("Cannot send 'RUN_FINISHED' while messages are still active")
        }
        if !activeToolCalls.isEmpty {
            throw fail("Cannot send 'RUN_FINISHED' while tool calls are still active")
        }
        if !activeSteps.isEmpty {
            throw fail("Cannot send 'RUN_FINISHED' while steps are still active")
        }
        if !activeReasoningSpans.isEmpty {
            throw fail("Cannot send 'RUN_FINISHED' while reasoning spans are still active")
        }
        if !activeReasoningMessages.isEmpty {
            throw fail("Cannot send 'RUN_FINISHED' while reasoning messages are still active")
        }
        state = .finished
    }

    private func warn(_ message: String) {
        onWarning?(AGUIProtocolWarning(message: message))
        #if DEBUG
        if debug {
            print("[EventVerifier] Warning: \(message)")
        }
        #endif
    }
}

// MARK: - AsyncSequence Extension

extension AsyncSequence where Element == any AGUIEvent {
    /// Validates that the event stream conforms to the AG-UI protocol state machine.
    ///
    /// Events are passed through unchanged if they are valid. If a protocol violation
    /// is detected, the stream throws an ``AGUIProtocolError`` and terminates. A
    /// `RUN_ERROR` sent by the producer is not a violation: it is passed through as a
    /// ``RunErrorEvent`` (including a late one after `RUN_FINISHED`, which marks the
    /// run as failed), so application code can tell it apart from a rejected stream.
    ///
    /// A new `RUN_STARTED` resets all per-run tracking, including after a
    /// `RUN_ERROR`. A `RUN_ERROR` ends whatever was open.
    ///
    /// Non-fatal conditions, such as an `ACTIVITY_DELTA` with no prior
    /// `ACTIVITY_SNAPSHOT` for its message, are skipped: the event is dropped from
    /// the output and reported to `onWarning`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let verified = eventStream.verifyEvents()
    /// for try await event in verified {
    ///     // Only valid events reach here
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - debug: When `true`, logs each verified event to stdout.
    ///   - onWarning: Called for each non-fatal warning. Defaults to ignoring them.
    /// - Returns: A throwing stream of verified events.
    public func verifyEvents(
        debug: Bool = false,
        onWarning: (@Sendable (AGUIProtocolWarning) -> Void)? = nil
    ) -> AsyncThrowingStream<any AGUIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let verifier = EventVerifier(debug: debug, onWarning: onWarning)
                do {
                    for try await event in self {
                        if try verifier.verify(event) {
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
}
