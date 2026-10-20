// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Data Transfer Object for UserMessage decoding.
struct UserMessageDTO {
    let id: String
    let content: String
    let name: String?
    let contentParts: [any ContentPart]?
    let encryptedValue: String?

    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> UserMessageDTO {
        guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Expected JSON object at root")
            )
        }

        // Validate role
        let role = try MessageDecodingHelpers.extractRole(from: jsonObject)
        try MessageDecodingHelpers.validateRole(role, expected: .user)

        // Extract required fields
        let id = try MessageDecodingHelpers.extractRequiredString(from: jsonObject, key: "id")

        // Extract optional fields
        let name = MessageDecodingHelpers.extractOptionalString(from: jsonObject, key: "name")
        let encryptedValue = MessageDecodingHelpers.extractOptionalString(from: jsonObject, key: "encryptedValue")

        // Handle polymorphic content (String or Array of InputContent)
        guard let contentValue = jsonObject["content"] else {
            throw DecodingError.keyNotFound(
                CodingKeys.content,
                DecodingError.Context(codingPath: [], debugDescription: "Missing content field")
            )
        }

        let content: String
        let contentParts: [any ContentPart]?

        if let contentString = contentValue as? String {
            // Text-only message
            content = contentString
            contentParts = nil
        } else if let contentArray = contentValue as? [[String: Any]] {
            // Multimodal message
            content = ""
            contentParts = try decodeInputContentArray(contentArray, decoder: decoder)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: [CodingKeys.content],
                    debugDescription: "Expected String or Array for content"
                )
            )
        }

        return UserMessageDTO(id: id, content: content, name: name, contentParts: contentParts, encryptedValue: encryptedValue)
    }

    /// Decodes an array of content parts. Parts this package cannot use are dropped rather than
    /// failing the message; the warnings are discarded until a warning channel exists (plan C7).
    private static func decodeInputContentArray(
        _ array: [[String: Any]],
        decoder: JSONDecoder
    ) throws -> [any ContentPart] {
        try array.enumerated().compactMap { index, item in
            try ContentPartCodec.decode(item, index: index).part
        }
    }

    func toDomain() -> UserMessage {
        if let parts = contentParts {
            return UserMessage.multimodal(id: id, parts: parts, name: name, encryptedValue: encryptedValue)
        } else {
            return UserMessage(id: id, content: content, name: name, encryptedValue: encryptedValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case content
    }
}
