// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Why an agent paused a run, used to route an interrupt to the right UI.
///
/// The protocol defines three core values. Frameworks may add their own,
/// namespaced with a prefix such as `"langgraph:"` or `"mastra:"`, so any
/// string is accepted.
public struct InterruptReason: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {

    /// The agent wants approval before running a tool call.
    public static let toolCall = InterruptReason(rawValue: "tool_call")

    /// The agent needs information from the user to continue.
    public static let inputRequired = InterruptReason(rawValue: "input_required")

    /// The agent wants the user to confirm before continuing.
    public static let confirmation = InterruptReason(rawValue: "confirmation")

    /// The wire value of the reason.
    public let rawValue: String

    /// Creates a reason from its wire value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a reason from a string literal, such as `"mastra:tool_suspend"`.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// A request from the agent for human input that paused a run.
///
/// Delivered in `RunFinishedOutcome.interrupt`. Answer it by starting a new run
/// on the same thread with a `ResumeEntry` whose `interruptId` matches `id`.
///
/// - Note: Interrupts are a draft extension of the AG-UI protocol.
public struct Interrupt: Equatable, Hashable, Sendable {

    /// Identifies the interrupt across the interrupt, the resume, and any audit records.
    public let id: String

    /// Why the run paused.
    public let reason: InterruptReason

    /// Optional human-readable prompt to show the user.
    public let message: String?

    /// The tool call this interrupt is about, if any.
    public let toolCallId: String?

    /// Optional JSON Schema, as raw JSON, describing the expected resume payload.
    public let responseSchema: Data?

    /// Optional ISO-8601 deadline after which the interrupt can no longer be answered.
    public let expiresAt: String?

    /// Optional framework-specific data, as a raw JSON object.
    public let metadata: Data?

    /// The subagent that raised the interrupt, if any.
    public let subagentRunId: String?

    /// Creates an interrupt.
    ///
    /// - Parameters:
    ///   - id: The interrupt identifier
    ///   - reason: Why the run paused
    ///   - message: Optional prompt for the user
    ///   - toolCallId: Optional tool call the interrupt is about
    ///   - responseSchema: Optional JSON Schema for the resume payload, as raw JSON
    ///   - expiresAt: Optional ISO-8601 deadline
    ///   - metadata: Optional framework-specific data, as a raw JSON object
    ///   - subagentRunId: Optional subagent that raised the interrupt
    public init(
        id: String,
        reason: InterruptReason,
        message: String? = nil,
        toolCallId: String? = nil,
        responseSchema: Data? = nil,
        expiresAt: String? = nil,
        metadata: Data? = nil,
        subagentRunId: String? = nil
    ) {
        self.id = id
        self.reason = reason
        self.message = message
        self.toolCallId = toolCallId
        self.responseSchema = responseSchema
        self.expiresAt = expiresAt
        self.metadata = metadata
        self.subagentRunId = subagentRunId
    }
}
