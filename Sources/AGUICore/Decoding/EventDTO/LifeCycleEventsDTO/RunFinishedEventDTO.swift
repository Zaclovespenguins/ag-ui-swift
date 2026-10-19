// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

struct RunFinishedEventDTO {
    let threadId: String
    let runId: String
    let outcome: RunFinishedOutcome
    let result: Data?
    let timestamp: Int64?

    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> RunFinishedEventDTO {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Expected JSON object at root")
            )
        }

        let threadId: String
        if let raw = jsonObject["threadId"] {
            guard let value = raw as? String else {
                throw DecodingError.typeMismatch(
                    String.self,
                    DecodingError.Context(codingPath: [CodingKeys.threadId], debugDescription: "Type mismatch for 'threadId': expected String")
                )
            }
            threadId = value
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.threadId,
                DecodingError.Context(codingPath: [], debugDescription: "Missing required field: threadId")
            )
        }

        let runId: String
        if let raw = jsonObject["runId"] {
            guard let value = raw as? String else {
                throw DecodingError.typeMismatch(
                    String.self,
                    DecodingError.Context(codingPath: [CodingKeys.runId], debugDescription: "Type mismatch for 'runId': expected String")
                )
            }
            runId = value
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.runId,
                DecodingError.Context(codingPath: [], debugDescription: "Missing required field: runId")
            )
        }

        let outcome = try decodeOutcome(jsonObject["outcome"])

        let timestamp = try EventDecodingHelpers.extractTimestamp(from: jsonObject)

        var resultData: Data?
        if let resultValue = jsonObject["result"], !(resultValue is NSNull) {
            // `result` may be any JSON value, including a top-level scalar.
            resultData = try? JSONSerialization.data(withJSONObject: resultValue, options: .fragmentsAllowed)
        }

        return RunFinishedEventDTO(threadId: threadId, runId: runId, outcome: outcome, result: resultData, timestamp: timestamp)
    }

    func toDomain(rawEvent: Data? = nil) -> RunFinishedEvent {
        RunFinishedEvent(threadId: threadId, runId: runId, outcome: outcome, result: result, timestamp: timestamp, rawEvent: rawEvent)
    }

    /// Decodes the `"outcome"` field.
    ///
    /// Absent or null means success. A value that is present but not a known
    /// outcome object becomes `.unknown` rather than `.success`, so a run is
    /// never reported as completed when the producer said otherwise. A
    /// malformed interrupt outcome throws, because dropping its interrupts
    /// would leave the run paused with nothing to answer.
    private static func decodeOutcome(_ raw: Any?) throws -> RunFinishedOutcome {
        guard let raw, !(raw is NSNull) else {
            return .success()
        }
        guard let object = raw as? [String: Any] else {
            return .unknown(type: raw as? String ?? "")
        }
        guard let type = object["type"] as? String else {
            return .unknown(type: "")
        }

        switch type {
        case "success":
            return .success(pendingToolCallIds: object["pendingToolCallIds"] as? [String] ?? [])
        case "cancelled":
            return .cancelled
        case "interrupt":
            guard let interrupts = object["interrupts"] as? [[String: Any]] else {
                throw DecodingError.typeMismatch(
                    [Any].self,
                    DecodingError.Context(
                        codingPath: [CodingKeys.outcome],
                        debugDescription: "Interrupt outcome requires an 'interrupts' array of objects"
                    )
                )
            }
            return .interrupt(try interrupts.map(decodeInterrupt))
        default:
            return .unknown(type: type)
        }
    }

    private static func decodeInterrupt(_ object: [String: Any]) throws -> Interrupt {
        guard let id = object["id"] as? String else {
            throw DecodingError.keyNotFound(
                InterruptCodingKeys.id,
                DecodingError.Context(
                    codingPath: [CodingKeys.outcome],
                    debugDescription: "Missing required interrupt field: id"
                )
            )
        }
        guard let reason = object["reason"] as? String else {
            throw DecodingError.keyNotFound(
                InterruptCodingKeys.reason,
                DecodingError.Context(
                    codingPath: [CodingKeys.outcome],
                    debugDescription: "Missing required interrupt field: reason"
                )
            )
        }

        func jsonData(_ key: InterruptCodingKeys) -> Data? {
            guard let value = object[key.rawValue], !(value is NSNull) else { return nil }
            return try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        }

        return Interrupt(
            id: id,
            reason: InterruptReason(rawValue: reason),
            message: object["message"] as? String,
            toolCallId: object["toolCallId"] as? String,
            responseSchema: jsonData(.responseSchema),
            expiresAt: object["expiresAt"] as? String,
            metadata: jsonData(.metadata),
            subagentRunId: object["subagentRunId"] as? String
        )
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, runId, outcome, result, timestamp
    }

    private enum InterruptCodingKeys: String, CodingKey {
        case id, reason, responseSchema, metadata
    }
}
