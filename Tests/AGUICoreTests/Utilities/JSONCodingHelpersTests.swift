// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Tests that the generic JSON encoding helpers keep integers and booleans distinct.
///
/// Values produced by `JSONSerialization` are `NSNumber`s, and `NSNumber(1)` bridges
/// to `Bool` via `as? Bool`. The helpers must not turn `0`/`1` into `false`/`true`.
final class JSONCodingHelpersTests: XCTestCase {
    // MARK: - Fixtures

    private struct Primitives: Decodable, Equatable {
        let one: Int
        let zero: Int
        let yes: Bool
        let no: Bool
        let ratio: Double
    }

    private struct Nested: Decodable, Equatable {
        let flat: Primitives
        let inner: Inner
        let numbers: [Int]
        let flags: [Bool]
        let objects: [Primitives]

        struct Inner: Decodable, Equatable {
            let deeper: Primitives
        }
    }

    private let primitivesJSON = #"{"one":1,"zero":0,"yes":true,"no":false,"ratio":1.5}"#

    private var nestedJSON: String {
        """
        {
          "flat": \(primitivesJSON),
          "inner": {"deeper": \(primitivesJSON)},
          "numbers": [1, 0, 1],
          "flags": [true, false, true],
          "objects": [\(primitivesJSON)]
        }
        """
    }

    private let expectedPrimitives = Primitives(one: 1, zero: 0, yes: true, no: false, ratio: 1.5)

    private var expectedNested: Nested {
        Nested(
            flat: expectedPrimitives,
            inner: Nested.Inner(deeper: expectedPrimitives),
            numbers: [1, 0, 1],
            flags: [true, false, true],
            objects: [expectedPrimitives]
        )
    }

    // MARK: - Direct helper tests

    private struct ObjectBox: Encodable {
        let object: Any

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: JSONCodingKeys.self)
            try container.encodeJSONObject(object)
        }
    }

    private struct ArrayBox: Encodable {
        let array: [Any]

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encodeJSONArray(array)
        }
    }

    func test_encodeJSONObject_withSerializedNumbers_keepsIntsAndBoolsDistinct() throws {
        let object = try JSONSerialization.jsonObject(with: Data(nestedJSON.utf8))

        let data = try JSONEncoder().encode(ObjectBox(object: object))

        XCTAssertEqual(try JSONDecoder().decode(Nested.self, from: data), expectedNested)
    }

    func test_encodeJSONObject_withSwiftNativeValues_keepsIntsAndBoolsDistinct() throws {
        let object: [String: Any] = ["one": 1, "zero": 0, "yes": true, "no": false, "ratio": 1.5]

        let data = try JSONEncoder().encode(ObjectBox(object: object))

        XCTAssertEqual(try JSONDecoder().decode(Primitives.self, from: data), expectedPrimitives)
    }

    func test_encodeJSONArray_withSerializedNumbers_keepsIntsAndBoolsDistinct() throws {
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("[1, 0, true, false, [1, 0], [true, false]]".utf8)) as? [Any]
        )

        let data = try JSONEncoder().encode(ArrayBox(array: array))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])

        XCTAssertEqual(decoded.count, 6)
        XCTAssertFalse(isBoolean(decoded[0]))
        XCTAssertEqual(decoded[0] as? Int, 1)
        XCTAssertFalse(isBoolean(decoded[1]))
        XCTAssertEqual(decoded[1] as? Int, 0)
        XCTAssertTrue(isBoolean(decoded[2]))
        XCTAssertEqual(decoded[2] as? Bool, true)
        XCTAssertTrue(isBoolean(decoded[3]))
        XCTAssertEqual(decoded[3] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: JSONSerialization.data(withJSONObject: decoded[4])), [1, 0])
        XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: JSONSerialization.data(withJSONObject: decoded[5])), [true, false])
    }

    // MARK: - JSONPrimitiveWrapper

    func test_jsonPrimitiveWrapper_withSerializedInts_encodesNumbers() throws {
        let encoder = JSONEncoder()

        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: NSNumber(value: 1))), as: UTF8.self), "1")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: NSNumber(value: 0))), as: UTF8.self), "0")
    }

    func test_jsonPrimitiveWrapper_withBooleans_encodesBooleans() throws {
        let encoder = JSONEncoder()

        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: true)), as: UTF8.self), "true")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: false)), as: UTF8.self), "false")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: NSNumber(value: true))), as: UTF8.self), "true")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONPrimitiveWrapper(value: NSNumber(value: false))), as: UTF8.self), "false")
    }

    func test_stateSnapshotEvent_withIntegerSnapshot_keepsNumber() throws {
        let data = Data(#"{"type":"STATE_SNAPSHOT","snapshot":1}"#.utf8)

        let event = try XCTUnwrap(try AGUIEventDecoder().decode(data) as? StateSnapshotEvent)

        XCTAssertEqual(String(decoding: event.snapshot, as: UTF8.self), "1")
    }

    // MARK: - RunAgentInput

    func test_runAgentInput_forwardedProps_keepsIntsAndBoolsDistinct() throws {
        let input = RunAgentInput(threadId: "t", runId: "r", forwardedProps: Data(nestedJSON.utf8))

        let props = try encodedField("forwardedProps", of: input)

        XCTAssertEqual(try JSONDecoder().decode(Nested.self, from: props), expectedNested)
    }

    func test_runAgentInput_state_keepsIntsAndBoolsDistinct() throws {
        let input = RunAgentInput(threadId: "t", runId: "r", state: Data(nestedJSON.utf8))

        let state = try encodedField("state", of: input)

        XCTAssertEqual(try JSONDecoder().decode(Nested.self, from: state), expectedNested)
    }

    func test_runAgentInput_roundTrip_keepsIntsAndBoolsDistinct() throws {
        let input = RunAgentInput(
            threadId: "t",
            runId: "r",
            state: Data(nestedJSON.utf8),
            forwardedProps: Data(nestedJSON.utf8)
        )

        let decoded = try JSONDecoder().decode(RunAgentInput.self, from: JSONEncoder().encode(input))

        XCTAssertEqual(try JSONDecoder().decode(Nested.self, from: decoded.state), expectedNested)
        XCTAssertEqual(try JSONDecoder().decode(Nested.self, from: decoded.forwardedProps), expectedNested)
    }

    // MARK: - Helpers

    private func encodedField(_ name: String, of input: RunAgentInput) throws -> Data {
        let encoded = try JSONEncoder().encode(input)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let field = try XCTUnwrap(root[name])
        return try JSONSerialization.data(withJSONObject: field)
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
