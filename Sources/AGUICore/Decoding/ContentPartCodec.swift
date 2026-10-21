// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// A non-fatal condition found while decoding or encoding content parts.
///
/// The spec requires a consumer that cannot use a part to carry on rather than fail the run,
/// and requires a warning when input is translated from a retired shape. There is no logging
/// or warning channel yet (plan item C7), so the codec returns these and callers decide.
public enum ContentPartWarning: Sendable, Hashable {
    /// A retired `binary` part was translated to a 1.0 part.
    case legacyBinaryTranslated

    /// A 0.x flat part (`url`/`data` beside `type`, no `source`) was translated. Fields with
    /// no 1.0 equivalent (`detail`, `format`, `title`) were dropped.
    case legacyFlatShapeTranslated(type: String)

    /// A part with an unrecognized `type` was dropped.
    case unknownPartDropped(type: String)

    /// A part was dropped because its `source` is unrecognized or cannot be expressed in 1.0.
    case unusableSourceDropped(type: String)

    /// A non-text part was dropped while flattening tool result content to a string for a peer
    /// that only understands strings. No placeholder is inserted in its place.
    case partDroppedWhenFlattening(type: String)
}

/// Decodes and encodes ``ContentPart`` values on the AG-UI 1.0 wire.
///
/// Rules, from `basic/processing`:
/// - an absent optional field is `nil`; a present field of the wrong type is fatal
/// - `null` for an optional field is treated as absent
/// - unknown properties are stripped; unknown part or source types drop the part, not the run
enum ContentPartCodec {
    struct Decoded {
        let part: (any ContentPart)?
        let warnings: [ContentPartWarning]
    }

    private static let mediaTypes: Set<String> = ["image", "audio", "video", "document"]

    // MARK: - Decoding

    static func decode(_ object: [String: Any], index: Int) throws -> Decoded {
        guard let type = object["type"] as? String else {
            throw error(.keyNotFound, index: index, key: "type", "Missing type field in content array item")
        }
        switch type {
        case "text":
            return Decoded(part: try decodeText(object, index: index), warnings: [])
        case "binary":
            return try decodeLegacyBinary(object, index: index)
        case _ where mediaTypes.contains(type):
            if object["source"] != nil, !(object["source"] is NSNull) {
                return try decodeMedia(object, type: type, index: index)
            }
            return try decodeLegacyFlat(object, type: type, index: index)
        default:
            return Decoded(part: nil, warnings: [.unknownPartDropped(type: type)])
        }
    }

    private static func decodeText(_ object: [String: Any], index: Int) throws -> TextPart {
        guard let text = object["text"] as? String else {
            throw error(.keyNotFound, index: index, key: "text", "Missing or non-string text field")
        }
        return TextPart(
            text: text,
            id: try optionalString(object, "id", index: index),
            metadata: try metadata(object, index: index)
        )
    }

    private static func decodeMedia(_ object: [String: Any], type: String, index: Int) throws -> Decoded {
        guard let sourceObject = object["source"] as? [String: Any] else {
            throw error(.typeMismatch, index: index, key: "source", "source must be an object")
        }
        guard let source = try decodeSource(sourceObject, index: index) else {
            return Decoded(part: nil, warnings: [.unusableSourceDropped(type: type)])
        }
        let part = try makeMedia(
            type: type,
            source: source,
            id: try optionalString(object, "id", index: index),
            metadata: try metadata(object, index: index)
        )
        return Decoded(part: part, warnings: [])
    }

    /// Returns `nil` for an unrecognized source type.
    private static func decodeSource(_ object: [String: Any], index: Int) throws -> PartSource? {
        guard let type = object["type"] as? String else {
            throw error(.keyNotFound, index: index, key: "source.type", "Missing source type")
        }
        func value() throws -> String {
            guard let value = object["value"] as? String else {
                throw error(.keyNotFound, index: index, key: "source.value", "Missing or non-string source value")
            }
            return value
        }
        switch type {
        case "data":
            let bytes = try value()
            guard let mimeType = try optionalString(object, "mimeType", index: index) else {
                throw error(.keyNotFound, index: index, key: "source.mimeType", "A data source requires mimeType")
            }
            guard Data(base64Encoded: bytes) != nil else {
                throw error(.dataCorrupted, index: index, key: "source.value", "Data source value is not valid base64")
            }
            return .data(value: bytes, mimeType: mimeType)
        case "url":
            return .url(value: try value(), mimeType: try optionalString(object, "mimeType", index: index))
        case "file":
            return .file(
                value: try value(),
                provider: try optionalString(object, "provider", index: index),
                mimeType: try optionalString(object, "mimeType", index: index)
            )
        default:
            return nil
        }
    }

    // MARK: - Legacy translation

    /// Translates a retired `binary` part. The MIME family picks the 1.0 part kind; anything
    /// that is not image, audio or video becomes a document.
    private static func decodeLegacyBinary(_ object: [String: Any], index: Int) throws -> Decoded {
        guard let mimeType = object["mimeType"] as? String else {
            throw error(.keyNotFound, index: index, key: "mimeType", "Missing mimeType field")
        }
        let source: PartSource
        if let data = try optionalString(object, "data", index: index) {
            source = .data(value: data, mimeType: mimeType)
        } else if let url = try optionalString(object, "url", index: index) {
            source = .url(value: url, mimeType: mimeType)
        } else if let id = try optionalString(object, "id", index: index) {
            source = .file(value: id, provider: nil, mimeType: mimeType)
        } else {
            throw error(.dataCorrupted, index: index, key: "binary", "binary requires at least one of: id, url, or data")
        }
        return Decoded(part: try makeMedia(type: legacyKind(forMimeType: mimeType), source: source, id: nil, metadata: nil),
                       warnings: [.legacyBinaryTranslated])
    }

    /// Translates a 0.x flat `image`/`audio`/`video`/`document` part. A flat `data` payload with
    /// no `mimeType` cannot form a valid 1.0 data source, so that part is dropped with a warning.
    private static func decodeLegacyFlat(_ object: [String: Any], type: String, index: Int) throws -> Decoded {
        let mimeType = try optionalString(object, "mimeType", index: index)
        let source: PartSource
        if let url = try optionalString(object, "url", index: index) {
            source = .url(value: url, mimeType: mimeType)
        } else if let data = try optionalString(object, "data", index: index) {
            guard let mimeType, Data(base64Encoded: data) != nil else {
                return Decoded(part: nil, warnings: [.unusableSourceDropped(type: type)])
            }
            source = .data(value: data, mimeType: mimeType)
        } else {
            throw error(.keyNotFound, index: index, key: "source", "Missing source")
        }
        return Decoded(part: try makeMedia(type: type, source: source, id: nil, metadata: nil),
                       warnings: [.legacyFlatShapeTranslated(type: type)])
    }

    // MARK: - Encoding

    /// Encodes a part in the 1.0 shape. Returns `nil` for a part type this package does not
    /// know (a custom conformer), which the caller skips.
    static func encode(_ part: any ContentPart) -> [String: Any]? {
        if let text = part as? TextPart {
            var dict: [String: Any] = ["type": "text", "text": text.text]
            applyCommon(&dict, id: text.id, metadata: text.metadata)
            return dict
        }
        if let binary = part as? BinaryInputContent {
            return translated(binary).flatMap(encode)
        }
        let media: (source: PartSource, id: String?, metadata: Data?)
        switch part {
        case let part as ImagePart: media = (part.source, part.id, part.metadata)
        case let part as AudioPart: media = (part.source, part.id, part.metadata)
        case let part as VideoPart: media = (part.source, part.id, part.metadata)
        case let part as DocumentPart: media = (part.source, part.id, part.metadata)
        default: return nil
        }
        var dict: [String: Any] = ["type": part.type, "source": encode(media.source)]
        applyCommon(&dict, id: media.id, metadata: media.metadata)
        return dict
    }

    /// Translates a retired `binary` value to its 1.0 part, by the same rules as decoding.
    static func translated(_ binary: BinaryInputContent) -> (any ContentPart)? {
        let source: PartSource
        if let data = binary.data {
            source = .data(value: data, mimeType: binary.mimeType)
        } else if let url = binary.url {
            source = .url(value: url, mimeType: binary.mimeType)
        } else if let id = binary.id {
            source = .file(value: id, provider: nil, mimeType: binary.mimeType)
        } else {
            return nil
        }
        return try? makeMedia(type: legacyKind(forMimeType: binary.mimeType), source: source, id: nil, metadata: nil)
    }

    private static func encode(_ source: PartSource) -> [String: Any] {
        switch source {
        case let .data(value, mimeType):
            return ["type": "data", "value": value, "mimeType": mimeType]
        case let .url(value, mimeType):
            var dict: [String: Any] = ["type": "url", "value": value]
            if let mimeType { dict["mimeType"] = mimeType }
            return dict
        case let .file(value, provider, mimeType):
            var dict: [String: Any] = ["type": "file", "value": value]
            if let provider { dict["provider"] = provider }
            if let mimeType { dict["mimeType"] = mimeType }
            return dict
        }
    }

    private static func applyCommon(_ dict: inout [String: Any], id: String?, metadata: Data?) {
        if let id { dict["id"] = id }
        if let metadata, let value = try? JSONSerialization.jsonObject(with: metadata, options: [.fragmentsAllowed]) {
            dict["metadata"] = value
        }
    }

    // MARK: - Helpers

    /// The 1.0 part kind for a retired `binary` part: its MIME family if that is a media
    /// part, otherwise a document.
    private static func legacyKind(forMimeType mimeType: String) -> String {
        let family = String(mimeType.prefix(while: { $0 != "/" }))
        return ["image", "audio", "video"].contains(family) ? family : "document"
    }

    private static func makeMedia(type: String, source: PartSource, id: String?, metadata: Data?) throws -> any ContentPart {
        switch type {
        case "image": return ImagePart(source: source, id: id, metadata: metadata)
        case "audio": return AudioPart(source: source, id: id, metadata: metadata)
        case "video": return VideoPart(source: source, id: id, metadata: metadata)
        default: return DocumentPart(source: source, id: id, metadata: metadata)
        }
    }

    private static func optionalString(_ object: [String: Any], _ key: String, index: Int) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let string = raw as? String else {
            throw error(.typeMismatch, index: index, key: key, "\(key) must be a string")
        }
        return string
    }

    private static func metadata(_ object: [String: Any], index: Int) throws -> Data? {
        guard let raw = object["metadata"], !(raw is NSNull) else { return nil }
        return try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
    }

    private enum Failure { case keyNotFound, typeMismatch, dataCorrupted }

    private struct PartKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = "Index \(intValue)"; self.intValue = intValue }
    }

    private static func error(_ kind: Failure, index: Int, key: String, _ message: String) -> DecodingError {
        let path: [CodingKey] = [PartKey(intValue: index)!, PartKey(stringValue: key)!]
        let context = DecodingError.Context(codingPath: path, debugDescription: message)
        switch kind {
        case .keyNotFound: return .keyNotFound(PartKey(stringValue: key)!, context)
        case .typeMismatch: return .typeMismatch(String.self, context)
        case .dataCorrupted: return .dataCorrupted(context)
        }
    }
}
