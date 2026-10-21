// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Decodes and encodes ``ToolResultContent`` on the AG-UI 1.0 wire.
///
/// `content` is a string or an array of parts. Anything else is fatal. Parts this package
/// cannot use are dropped (the part codec's rule), which can leave an empty array; that is
/// still a valid result and still answers its call.
enum ToolResultContentCodec {
    /// Decodes a value produced by `JSONSerialization` (with fragments allowed).
    static func decode(_ raw: Any, path: [CodingKey] = []) throws -> ToolResultContent {
        if let string = raw as? String {
            return .text(string)
        }
        guard let array = raw as? [Any] else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: path, debugDescription: "Expected String or Array for tool result content")
            )
        }
        var parts: [any ContentPart] = []
        for (index, item) in array.enumerated() {
            guard let object = item as? [String: Any] else {
                throw DecodingError.typeMismatch(
                    [String: Any].self,
                    DecodingError.Context(
                        codingPath: path,
                        debugDescription: "Content part at index \(index) is not an object"
                    )
                )
            }
            // Warnings are discarded until a warning channel exists (plan C7).
            if let part = try ContentPartCodec.decode(object, index: index).part {
                parts.append(part)
            }
        }
        return .parts(parts)
    }

    /// Decodes a ``JSONValue`` taken from a `Decodable` container.
    static func decode(_ value: JSONValue, path: [CodingKey]) throws -> ToolResultContent {
        let raw = try JSONSerialization.jsonObject(with: value.data(), options: [.fragmentsAllowed])
        return try decode(raw, path: path)
    }

    /// The JSON-compatible value for `content`.
    static func encode(_ content: ToolResultContent) -> Any {
        switch content {
        case let .text(value):
            return value
        case let .parts(parts):
            return parts.compactMap { ContentPartCodec.encode($0) }
        }
    }
}
