// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// The content of a tool result: a string, or an ordered array of ``ContentPart`` values.
///
/// AG-UI 1.0 allows both shapes for `TOOL_CALL_RESULT.content` and `ToolMessage.content`
/// (`events/tool-calls#result-content`).
///
/// A result answers its tool call whatever its content is. Parts that a consumer cannot use
/// are dropped on decode, so `.parts([])` is a valid value and still answers the call.
public enum ToolResultContent: Sendable {
    /// A plain string result.
    case text(String)

    /// An ordered array of content parts.
    case parts([any ContentPart])

    /// The string for a ``text(_:)`` result, or `nil` for parts.
    public var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    /// Flattens this content to a string for a peer that only understands string results.
    ///
    /// Text parts are joined with a newline in order. Every part that is not a text part is
    /// dropped and reported as a ``ContentPartWarning/partDroppedWhenFlattening(type:)``;
    /// no placeholder text is inserted in its place. Callers must surface the warnings.
    public func flattened() -> (text: String, warnings: [ContentPartWarning]) {
        switch self {
        case let .text(value):
            return (value, [])
        case let .parts(parts):
            var texts: [String] = []
            var warnings: [ContentPartWarning] = []
            for part in parts {
                if let textPart = part as? TextPart {
                    texts.append(textPart.text)
                } else {
                    warnings.append(.partDroppedWhenFlattening(type: part.type))
                }
            }
            return (texts.joined(separator: "\n"), warnings)
        }
    }
}

extension ToolResultContent: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

extension ToolResultContent: Hashable {
    public static func == (lhs: ToolResultContent, rhs: ToolResultContent) -> Bool {
        switch (lhs, rhs) {
        case let (.text(a), .text(b)):
            return a == b
        case let (.parts(a), .parts(b)):
            guard a.count == b.count else { return false }
            for index in a.indices where erase(a[index]) != erase(b[index]) {
                return false
            }
            return true
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .text(value):
            hasher.combine(0)
            hasher.combine(value)
        case let .parts(parts):
            hasher.combine(1)
            hasher.combine(parts.count)
            for part in parts { hasher.combine(erase(part)) }
        }
    }
}

/// Erases a part to `AnyHashable`; the generic parameter opens the existential.
private func erase(_ part: any ContentPart) -> AnyHashable {
    func open<P: ContentPart>(_ part: P) -> AnyHashable { AnyHashable(part) }
    return open(part)
}
