// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Tests for the `basic/run-input` shape: optional tools/context and `protocolVersion`.
final class RunAgentInputShapeTests: XCTestCase {

    private func encodeToObject(_ input: RunAgentInput) throws -> [String: Any] {
        let data = try JSONEncoder().encode(input)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> RunAgentInput {
        try JSONDecoder().decode(RunAgentInput.self, from: Data(json.utf8))
    }

    // MARK: - Optional tools / context

    func testDecodeWithoutToolsAndContextYieldsEmpty() throws {
        let input = try decode(#"{"threadId":"t","runId":"r"}"#)
        XCTAssertTrue(input.tools.isEmpty)
        XCTAssertTrue(input.context.isEmpty)
        XCTAssertEqual(input.state, Data("{}".utf8))
    }

    func testDecodeWithEmptyArraysYieldsEmpty() throws {
        let input = try decode(#"{"threadId":"t","runId":"r","tools":[],"context":[]}"#)
        XCTAssertTrue(input.tools.isEmpty)
        XCTAssertTrue(input.context.isEmpty)
    }

    func testDecodeWithNullToolsAndContextYieldsEmpty() throws {
        let input = try decode(#"{"threadId":"t","runId":"r","tools":null,"context":null}"#)
        XCTAssertTrue(input.tools.isEmpty)
        XCTAssertTrue(input.context.isEmpty)
    }

    func testDecodeWithMalformedToolsFails() {
        XCTAssertThrowsError(try decode(#"{"threadId":"t","runId":"r","tools":"nope"}"#))
    }

    func testEncodeOmitsEmptyToolsAndContext() throws {
        let json = try encodeToObject(RunAgentInput(threadId: "t", runId: "r"))
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["context"])
        XCTAssertNotNil(json["messages"])
        XCTAssertNotNil(json["forwardedProps"])
        XCTAssertNil(json["state"], "Empty state is omitted, never null")
    }

    func testEncodeKeepsNonEmptyToolsAndContext() throws {
        let input = RunAgentInput(
            threadId: "t",
            runId: "r",
            tools: [Tool(name: "f", description: "d", parameters: Data(#"{"type":"object"}"#.utf8))],
            context: [Context(description: "k", value: "v")]
        )
        let json = try encodeToObject(input)
        XCTAssertEqual((json["tools"] as? [Any])?.count, 1)
        XCTAssertEqual((json["context"] as? [Any])?.count, 1)
    }

    func testRoundTripPreservesEmptyToolsAndContext() throws {
        let input = RunAgentInput(threadId: "t", runId: "r")
        let decoded = try JSONDecoder().decode(RunAgentInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded, input)
    }

    // MARK: - protocolVersion

    func testProtocolVersionDefaultsToNil() throws {
        let input = RunAgentInput(threadId: "t", runId: "r")
        XCTAssertNil(input.protocolVersion)
        XCTAssertNil(try encodeToObject(input)["protocolVersion"])
    }

    func testProtocolVersionEncodedWhenSet() throws {
        let input = RunAgentInput(threadId: "t", runId: "r", protocolVersion: "1.0")
        XCTAssertEqual(try encodeToObject(input)["protocolVersion"] as? String, "1.0")
    }

    func testProtocolVersionDecoded() throws {
        let input = try decode(#"{"threadId":"t","runId":"r","protocolVersion":"1.10"}"#)
        XCTAssertEqual(input.protocolVersion, "1.10")
    }

    func testProtocolVersionAbsentDecodesToNil() throws {
        XCTAssertNil(try decode(#"{"threadId":"t","runId":"r"}"#).protocolVersion)
    }

    func testProtocolVersionRoundTripAndEquality() throws {
        let input = RunAgentInput(threadId: "t", runId: "r", protocolVersion: "1.0")
        let decoded = try JSONDecoder().decode(RunAgentInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded, input)
        XCTAssertNotEqual(input, RunAgentInput(threadId: "t", runId: "r", protocolVersion: "1.1"))
        XCTAssertNotEqual(input, RunAgentInput(threadId: "t", runId: "r"))
    }

    func testBuilderSetsProtocolVersion() throws {
        let input = try RunAgentInput.builder().threadId("t").runId("r").protocolVersion("1.0").build()
        XCTAssertEqual(input.protocolVersion, "1.0")
        XCTAssertNil(try RunAgentInput.builder().threadId("t").runId("r").build().protocolVersion)
    }
}
