// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

extension RunAgentInput {

    /// Returns a copy of this input with activity messages removed from `messages`.
    ///
    /// Activity messages are for display only; the AG-UI `basic/run-input` rules require
    /// a consumer to strip them from `messages` before sending a run input. Every send
    /// path in the package applies this, so local history can keep activity messages
    /// while the outgoing payload never carries them. Order of the remaining messages
    /// is preserved and all other fields are copied unchanged.
    ///
    /// - Returns: This input if it holds no activity messages, otherwise a stripped copy.
    public func strippingActivityMessages() -> RunAgentInput {
        guard messages.contains(where: { $0.role == .activity }) else { return self }
        return RunAgentInput(
            threadId: threadId,
            runId: runId,
            parentRunId: parentRunId,
            state: state,
            messages: messages.filter { $0.role != .activity },
            tools: tools,
            context: context,
            forwardedProps: forwardedProps,
            resume: resume,
            protocolVersion: protocolVersion
        )
    }
}
