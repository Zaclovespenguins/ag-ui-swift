// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Tests for `ResumeEntry`, the client's answer to an interrupt.
final class ResumeEntryTests: XCTestCase {

    private func encodeToObject(_ entry: ResumeEntry) throws -> [String: Any] {
        let data = try JSONEncoder().encode(entry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Initialization

    func test_resolvedFactory_setsStatusAndPayload() {
        let payload = Data(#"{"approved":true}"#.utf8)
        let entry = ResumeEntry.resolved(interruptId: "int-1", payload: payload)

        XCTAssertEqual(entry.interruptId, "int-1")
        XCTAssertEqual(entry.status, .resolved)
        XCTAssertEqual(entry.payload, payload)
        XCTAssertNil(entry.metadata)
    }

    func test_cancelledFactory_hasNoPayload() {
        let entry = ResumeEntry.cancelled(interruptId: "int-1")

        XCTAssertEqual(entry.status, .cancelled)
        XCTAssertNil(entry.payload)
    }

    func test_resumeStatus_rawValuesMatchSpec() {
        XCTAssertEqual(ResumeStatus.resolved.rawValue, "resolved")
        XCTAssertEqual(ResumeStatus.cancelled.rawValue, "cancelled")
    }

    // MARK: - Encoding

    func test_encode_resolvedWithObjectPayload() throws {
        let entry = ResumeEntry.resolved(interruptId: "int-1", payload: Data(#"{"approved":true,"note":"ok"}"#.utf8))

        let json = try encodeToObject(entry)

        XCTAssertEqual(json["interruptId"] as? String, "int-1")
        XCTAssertEqual(json["status"] as? String, "resolved")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["approved"] as? Bool, true)
        XCTAssertEqual(payload["note"] as? String, "ok")
        XCTAssertNil(json["metadata"])
    }

    func test_encode_cancelled_omitsPayloadKey() throws {
        let json = try encodeToObject(.cancelled(interruptId: "int-1"))

        XCTAssertEqual(json["status"] as? String, "cancelled")
        XCTAssertFalse(json.keys.contains("payload"), "Cancelled entries must not send a payload")
        XCTAssertFalse(json.keys.contains("metadata"))
    }

    func test_encode_scalarPayloads() throws {
        // The spec allows any JSON value, including top-level scalars.
        let cases: [(String, (Any) -> Bool)] = [
            ("true", { ($0 as? Bool) == true }),
            (#""yes""#, { ($0 as? String) == "yes" }),
            ("42", { ($0 as? Int) == 42 }),
            ("[1,2]", { ($0 as? [Int]) == [1, 2] })
        ]

        for (raw, check) in cases {
            let entry = ResumeEntry.resolved(interruptId: "int-1", payload: Data(raw.utf8))
            let json = try encodeToObject(entry)
            let payload = try XCTUnwrap(json["payload"], "payload missing for \(raw)")
            XCTAssertTrue(check(payload), "Unexpected payload \(payload) for \(raw)")
        }
    }

    func test_encode_withMetadata() throws {
        let entry = ResumeEntry.resolved(
            interruptId: "int-1",
            payload: Data("true".utf8),
            metadata: Data(#"{"signature":"abc"}"#.utf8)
        )

        let json = try encodeToObject(entry)

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["signature"] as? String, "abc")
    }

    func test_encode_invalidPayloadJSON_throws() {
        let entry = ResumeEntry.resolved(interruptId: "int-1", payload: Data("not json".utf8))

        XCTAssertThrowsError(try JSONEncoder().encode(entry))
    }

    // MARK: - Decoding

    func test_decode_resolvedWithPayloadAndMetadata() throws {
        let data = Data(#"{"interruptId":"int-1","status":"resolved","payload":{"approved":false},"metadata":{"k":"v"}}"#.utf8)

        let entry = try JSONDecoder().decode(ResumeEntry.self, from: data)

        XCTAssertEqual(entry.interruptId, "int-1")
        XCTAssertEqual(entry.status, .resolved)
        let payload = try XCTUnwrap(entry.payload)
        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(payloadObject["approved"] as? Bool, false)
        let metadata = try XCTUnwrap(entry.metadata)
        let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(metadataObject["k"] as? String, "v")
    }

    func test_decode_scalarPayload() throws {
        let data = Data(#"{"interruptId":"int-1","status":"resolved","payload":"yes"}"#.utf8)

        let entry = try JSONDecoder().decode(ResumeEntry.self, from: data)

        let payload = try XCTUnwrap(entry.payload)
        XCTAssertEqual(String(data: payload, encoding: .utf8), #""yes""#)
    }

    func test_decode_cancelledWithoutPayload() throws {
        let data = Data(#"{"interruptId":"int-1","status":"cancelled"}"#.utf8)

        let entry = try JSONDecoder().decode(ResumeEntry.self, from: data)

        XCTAssertEqual(entry.status, .cancelled)
        XCTAssertNil(entry.payload)
        XCTAssertNil(entry.metadata)
    }

    func test_decode_unknownStatus_throws() {
        let data = Data(#"{"interruptId":"int-1","status":"maybe"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ResumeEntry.self, from: data))
    }

    func test_decode_missingInterruptId_throws() {
        let data = Data(#"{"status":"resolved"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ResumeEntry.self, from: data))
    }

    func test_roundTrip_preservesValues() throws {
        let original = ResumeEntry.resolved(interruptId: "int-1", payload: Data(#"{"approved":true}"#.utf8))

        let decoded = try JSONDecoder().decode(ResumeEntry.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.interruptId, original.interruptId)
        XCTAssertEqual(decoded.status, original.status)
        let payload = try XCTUnwrap(decoded.payload)
        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(payloadObject["approved"] as? Bool, true)
    }

    // MARK: - Equatable

    func test_equatable_differentStatus_areNotEqual() {
        XCTAssertNotEqual(
            ResumeEntry.resolved(interruptId: "int-1"),
            ResumeEntry.cancelled(interruptId: "int-1")
        )
    }
}

/// Tests for the `resume` field on `RunAgentInput`.
final class RunAgentInputResumeTests: XCTestCase {

    private func encodeToObject(_ input: RunAgentInput) throws -> [String: Any] {
        let data = try JSONEncoder().encode(input)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_resume_defaultsToNil() {
        let input = RunAgentInput(threadId: "t", runId: "r")

        XCTAssertNil(input.resume)
    }

    func test_encode_withoutResume_omitsKey() throws {
        // zod's .optional() rejects null, so the key must be absent, not null.
        let json = try encodeToObject(RunAgentInput(threadId: "t", runId: "r"))

        XCTAssertFalse(json.keys.contains("resume"))
    }

    func test_encode_withResume_writesEntries() throws {
        let input = RunAgentInput(
            threadId: "t",
            runId: "r",
            resume: [
                .resolved(interruptId: "int-1", payload: Data(#"{"approved":true}"#.utf8)),
                .cancelled(interruptId: "int-2")
            ]
        )

        let json = try encodeToObject(input)

        let resume = try XCTUnwrap(json["resume"] as? [[String: Any]])
        XCTAssertEqual(resume.count, 2)
        XCTAssertEqual(resume[0]["interruptId"] as? String, "int-1")
        XCTAssertEqual(resume[0]["status"] as? String, "resolved")
        XCTAssertEqual((resume[0]["payload"] as? [String: Any])?["approved"] as? Bool, true)
        XCTAssertEqual(resume[1]["interruptId"] as? String, "int-2")
        XCTAssertEqual(resume[1]["status"] as? String, "cancelled")
        XCTAssertFalse(resume[1].keys.contains("payload"))
    }

    func test_decode_withResume() throws {
        let data = Data("""
        {"threadId":"t","runId":"r","messages":[],"tools":[],"context":[],"forwardedProps":{},
         "resume":[{"interruptId":"int-1","status":"resolved","payload":true}]}
        """.utf8)

        let input = try JSONDecoder().decode(RunAgentInput.self, from: data)

        let resume = try XCTUnwrap(input.resume)
        XCTAssertEqual(resume.count, 1)
        XCTAssertEqual(resume[0].interruptId, "int-1")
        XCTAssertEqual(resume[0].status, .resolved)
        XCTAssertEqual(resume[0].payload.flatMap { String(data: $0, encoding: .utf8) }, "true")
    }

    func test_decode_withoutResume_isNil() throws {
        let data = Data(#"{"threadId":"t","runId":"r","messages":[],"tools":[],"context":[],"forwardedProps":{}}"#.utf8)

        let input = try JSONDecoder().decode(RunAgentInput.self, from: data)

        XCTAssertNil(input.resume)
    }

    func test_equatable_differentResume_areNotEqual() {
        let first = RunAgentInput(threadId: "t", runId: "r", resume: [.resolved(interruptId: "int-1")])
        let second = RunAgentInput(threadId: "t", runId: "r", resume: [.cancelled(interruptId: "int-1")])
        let none = RunAgentInput(threadId: "t", runId: "r")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, none)
    }

    func test_hashable_differentResume_produceDistinctSetEntries() {
        let first = RunAgentInput(threadId: "t", runId: "r", resume: [.resolved(interruptId: "int-1")])
        let second = RunAgentInput(threadId: "t", runId: "r", resume: [.cancelled(interruptId: "int-1")])

        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func test_builder_setsResume() throws {
        let entries: [ResumeEntry] = [.cancelled(interruptId: "int-1")]

        let input = try RunAgentInput.builder()
            .threadId("t")
            .runId("r")
            .resume(entries)
            .build()

        XCTAssertEqual(input.resume, entries)
    }

    func test_builder_withoutResume_isNil() throws {
        let input = try RunAgentInput.builder().threadId("t").runId("r").build()

        XCTAssertNil(input.resume)
    }
}
