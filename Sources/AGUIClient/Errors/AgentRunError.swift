// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

/// A producer-reported run failure, distinct from a consumer's ``AGUIProtocolError``.
///
/// Event streams still deliver `RUN_ERROR` as an event. `AbstractAgent.runAgent`
/// reports this error to its caller and failure subscribers after processing it.
public struct AgentRunError: Error, LocalizedError, Sendable, Hashable {
    /// The producer's original failure event, including its message and code.
    public let event: RunErrorEvent

    /// Creates a failure from a producer's `RUN_ERROR` event.
    public init(event: RunErrorEvent) {
        self.event = event
    }

    /// The producer's human-readable failure message.
    public var errorDescription: String? { event.message }
}
