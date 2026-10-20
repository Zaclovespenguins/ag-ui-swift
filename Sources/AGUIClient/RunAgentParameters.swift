// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

// MARK: - RunAgentParameters

/// Parameters for a single agent run.
public struct RunAgentParameters: Sendable {
    public var runId: String?
    public var tools: [Tool]?
    public var context: [Context]?
    public var forwardedProps: State?

    /// Answers to the interrupts that ended the previous run, when this run resumes from one.
    public var resume: [ResumeEntry]?

    public init(
        runId: String? = nil,
        tools: [Tool]? = nil,
        context: [Context]? = nil,
        forwardedProps: State? = nil,
        resume: [ResumeEntry]? = nil
    ) {
        self.runId = runId
        self.tools = tools
        self.context = context
        self.forwardedProps = forwardedProps
        self.resume = resume
    }
}
