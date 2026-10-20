// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import XCTest
@testable import AGUIClient

final class RunAgentParametersResumeTests: XCTestCase {

    private actor NoopTransport: AgentTransport {
        nonisolated func run(input: RunAgentInput) -> AsyncThrowingStream<any AGUIEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testResumeReachesRunAgentInput() {
        let agent = AbstractAgent(transport: NoopTransport())
        let entries = [ResumeEntry.resolved(interruptId: "i1", payload: Data("true".utf8))]

        let input = agent.buildInput(from: RunAgentParameters(resume: entries))
        XCTAssertEqual(input.resume, entries)
    }

    func testResumeDefaultsToNil() {
        let agent = AbstractAgent(transport: NoopTransport())
        XCTAssertNil(agent.buildInput(from: nil).resume)
        XCTAssertNil(agent.buildInput(from: RunAgentParameters()).resume)
    }
}
