// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Describes why an agent run finished.
///
/// Carried by `RunFinishedEvent` and decoded from the `"outcome"` object in the
/// AG-UI wire format, which is discriminated by its `"type"` field. An absent
/// outcome means `.success`, so producers written before outcomes existed are
/// still read correctly.
///
/// - Note: The outcome field is a draft extension of the AG-UI protocol.
public enum RunFinishedOutcome: Equatable, Hashable, Sendable {

    /// The run completed.
    ///
    /// - Parameter pendingToolCallIds: Tool calls the run started but left
    ///   unanswered, for the application to answer in the next input's
    ///   messages. Empty when the producer named none.
    case success(pendingToolCallIds: [String] = [])

    /// The run paused for human input.
    ///
    /// Continue the thread with a new run whose `RunAgentInput.resume` answers
    /// every interrupt listed here.
    case interrupt([Interrupt])

    /// The run was cancelled before it produced a final result.
    case cancelled

    /// An outcome this SDK does not recognize, such as one from a newer
    /// protocol version.
    ///
    /// Kept distinct from `.success` so an unrecognized outcome is never
    /// mistaken for a completed run.
    ///
    /// - Parameter type: The wire `"type"` value, or an empty string if the
    ///   outcome had no type.
    case unknown(type: String)

    /// The interrupts awaiting an answer, or an empty array for any outcome
    /// other than `.interrupt`.
    public var interrupts: [Interrupt] {
        if case .interrupt(let interrupts) = self {
            return interrupts
        }
        return []
    }
}
