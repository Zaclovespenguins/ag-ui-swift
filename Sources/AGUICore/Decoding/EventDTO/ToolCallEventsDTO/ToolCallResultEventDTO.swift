// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

struct ToolCallResultEventDTO: Decodable {
    let messageId: String
    let toolCallId: String
    let content: ToolResultContent
    let role: String?
    let timestamp: Int64?

    private enum CodingKeys: String, CodingKey {
        case messageId, toolCallId, content, role, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        // A string or an array of parts; anything else (including null) is fatal.
        let value = try container.decode(JSONValue.self, forKey: .content)
        content = try ToolResultContentCodec.decode(value, path: container.codingPath + [CodingKeys.content])
        role = try container.decodeIfPresent(String.self, forKey: .role)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
    }

    func toDomain(rawEvent: Data? = nil) -> ToolCallResultEvent {
        ToolCallResultEvent(
            messageId: messageId,
            toolCallId: toolCallId,
            resultContent: content,
            role: role,
            timestamp: timestamp,
            rawEvent: rawEvent
        )
    }
}
