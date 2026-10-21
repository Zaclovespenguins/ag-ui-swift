// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Shared readers for optional fields in hand-decoded JSON objects.
///
/// A field that is absent or `null` reads as `nil`. A field that is present with a
/// value of the wrong type throws `DecodingError.typeMismatch`, so a malformed value is
/// never silently repaired into "absent" (AG-UI: "malformed is fatal"). Use these
/// instead of `object[key] as? T` for any known field.
enum OptionalField {

    /// Reads an optional string field.
    static func string(
        _ key: String,
        in object: [String: Any],
        codingPath: [CodingKey] = []
    ) throws -> String? {
        try read(key, in: object, expected: String.self, codingPath: codingPath) { $0 as? String }
    }

    /// Reads an optional boolean field. JSON `0` and `1` are numbers, not booleans.
    static func bool(
        _ key: String,
        in object: [String: Any],
        codingPath: [CodingKey] = []
    ) throws -> Bool? {
        try read(key, in: object, expected: Bool.self, codingPath: codingPath) { jsonBoolean($0) }
    }

    /// Reads an optional array of strings. Every element must be a string.
    static func stringArray(
        _ key: String,
        in object: [String: Any],
        codingPath: [CodingKey] = []
    ) throws -> [String]? {
        try read(key, in: object, expected: [String].self, codingPath: codingPath) { $0 as? [String] }
    }

    private static func read<T>(
        _ key: String,
        in object: [String: Any],
        expected: T.Type,
        codingPath: [CodingKey],
        cast: (Any) -> T?
    ) throws -> T? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = cast(raw) else {
            throw DecodingError.typeMismatch(
                expected,
                DecodingError.Context(
                    codingPath: codingPath + [FieldKey(stringValue: key)],
                    debugDescription: "Expected \(expected) for '\(key)', got \(type(of: raw))"
                )
            )
        }
        return value
    }

    private struct FieldKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
