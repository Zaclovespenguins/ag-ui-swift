// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Wire-format tests for AG-UI 1.0 content parts (`schema.json`: `ContentPart`, `PartSource`).
final class ContentPartTests: XCTestCase {

    private let decoder = MessageDecoder()
    private let encoder = MessageEncoder()

    // MARK: - Helpers

    private func decodeUser(parts: String) throws -> UserMessage {
        let json = #"{"id":"u1","role":"user","content":\#(parts)}"#
        let message = try decoder.decode(Data(json.utf8))
        return try XCTUnwrap(message as? UserMessage)
    }

    private func encodedParts(_ parts: [any ContentPart]) throws -> [[String: Any]] {
        let message = UserMessage.multimodal(id: "u1", parts: parts)
        let data = try encoder.encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["content"] as? [[String: Any]])
    }

    private func source(_ part: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(part["source"] as? [String: Any])
    }

    // MARK: - Encoding (1.0 shape)

    func test_encode_imageWithURLSource_usesSourceObject() throws {
        let part = ImagePart(source: .url(value: "https://example.com/a.png", mimeType: "image/png"))
        let encoded = try XCTUnwrap(encodedParts([part]).first)

        XCTAssertEqual(encoded["type"] as? String, "image")
        XCTAssertEqual(try source(encoded)["type"] as? String, "url")
        XCTAssertEqual(try source(encoded)["value"] as? String, "https://example.com/a.png")
        XCTAssertEqual(try source(encoded)["mimeType"] as? String, "image/png")
        // The flat 0.x fields must not leak onto the part.
        for key in ["url", "data", "mimeType", "detail"] {
            XCTAssertNil(encoded[key], key)
        }
    }

    func test_encode_urlSourceWithoutMimeType_omitsMimeType() throws {
        let part = VideoPart(source: .url(value: "https://example.com/v.mp4", mimeType: nil))
        let encoded = try XCTUnwrap(encodedParts([part]).first)
        XCTAssertNil(try source(encoded)["mimeType"])
    }

    func test_encode_audioWithDataSource() throws {
        let part = AudioPart(source: .data(value: "QUJD", mimeType: "audio/wav"))
        let encoded = try XCTUnwrap(encodedParts([part]).first)
        XCTAssertEqual(encoded["type"] as? String, "audio")
        XCTAssertEqual(try source(encoded)["type"] as? String, "data")
        XCTAssertEqual(try source(encoded)["value"] as? String, "QUJD")
        XCTAssertEqual(try source(encoded)["mimeType"] as? String, "audio/wav")
    }

    func test_encode_documentWithFileSource_keepsHandleOpaque() throws {
        let part = DocumentPart(source: .file(value: "file-abc123", provider: "openai", mimeType: "application/pdf"))
        let encoded = try XCTUnwrap(encodedParts([part]).first)
        XCTAssertEqual(try source(encoded)["type"] as? String, "file")
        XCTAssertEqual(try source(encoded)["value"] as? String, "file-abc123")
        XCTAssertEqual(try source(encoded)["provider"] as? String, "openai")
        XCTAssertEqual(try source(encoded)["mimeType"] as? String, "application/pdf")
    }

    func test_encode_fileSourceWithoutOptionals_omitsThem() throws {
        let part = DocumentPart(source: .file(value: "h", provider: nil, mimeType: nil))
        let encoded = try XCTUnwrap(encodedParts([part]).first)
        XCTAssertNil(try source(encoded)["provider"])
        XCTAssertNil(try source(encoded)["mimeType"])
    }

    func test_encode_partIdAndMetadata() throws {
        let metadata = Data(#"{"title":"Hit","score":0.5,"note":null}"#.utf8)
        let part = TextPart(text: "hello", id: "p1", metadata: metadata)
        let encoded = try XCTUnwrap(encodedParts([part]).first)

        XCTAssertEqual(encoded["id"] as? String, "p1")
        let meta = try XCTUnwrap(encoded["metadata"] as? [String: Any])
        XCTAssertEqual(meta["title"] as? String, "Hit")
        // null inside a payload is data and must be preserved.
        XCTAssertTrue(meta["note"] is NSNull)
    }

    func test_encode_absentIdAndMetadata_areOmittedNotNull() throws {
        let encoded = try XCTUnwrap(encodedParts([TextPart(text: "hi")]).first)
        XCTAssertNil(encoded["id"])
        XCTAssertNil(encoded["metadata"])
    }

    func test_encode_orderIsPreserved() throws {
        let encoded = try encodedParts([
            TextPart(text: "a"),
            ImagePart(source: .url(value: "u", mimeType: nil)),
            TextPart(text: "b")
        ])
        XCTAssertEqual(encoded.map { $0["type"] as? String }, ["text", "image", "text"])
    }

    // MARK: - Decoding (1.0 shape)

    func test_decode_eachMediaKindWithEachSource() throws {
        let message = try decodeUser(parts: """
        [
          {"type":"image","source":{"type":"url","value":"https://e.com/i.png"}},
          {"type":"audio","source":{"type":"data","value":"QUJD","mimeType":"audio/mpeg"}},
          {"type":"video","source":{"type":"file","value":"vid-1","provider":"google","mimeType":"video/mp4"}},
          {"type":"document","id":"d1","source":{"type":"url","value":"https://e.com/d.pdf","mimeType":"application/pdf"}}
        ]
        """)
        let parts = try XCTUnwrap(message.contentParts)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual((parts[0] as? ImagePart)?.source, .url(value: "https://e.com/i.png", mimeType: nil))
        XCTAssertEqual((parts[1] as? AudioPart)?.source, .data(value: "QUJD", mimeType: "audio/mpeg"))
        XCTAssertEqual(
            (parts[2] as? VideoPart)?.source,
            .file(value: "vid-1", provider: "google", mimeType: "video/mp4")
        )
        let doc = try XCTUnwrap(parts[3] as? DocumentPart)
        XCTAssertEqual(doc.id, "d1")
        XCTAssertEqual(doc.source, .url(value: "https://e.com/d.pdf", mimeType: "application/pdf"))
    }

    func test_decode_textPartWithIdAndMetadata() throws {
        let message = try decodeUser(parts: #"[{"type":"text","id":"t1","text":"hi","metadata":{"k":[1,2]}}]"#)
        let part = try XCTUnwrap(message.contentParts?.first as? TextPart)
        XCTAssertEqual(part.id, "t1")
        XCTAssertEqual(part.text, "hi")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(part.metadata)) as? [String: Any])
        XCTAssertEqual(meta["k"] as? [Int], [1, 2])
    }

    func test_decode_nullOptionalFieldsTreatedAsAbsent() throws {
        let message = try decodeUser(parts: """
        [{"type":"image","id":null,"metadata":null,"source":{"type":"url","value":"u","mimeType":null}}]
        """)
        let part = try XCTUnwrap(message.contentParts?.first as? ImagePart)
        XCTAssertNil(part.id)
        XCTAssertNil(part.metadata)
        XCTAssertEqual(part.source, .url(value: "u", mimeType: nil))
    }

    func test_decode_unknownPropertiesAreStripped() throws {
        let message = try decodeUser(parts: """
        [{"type":"image","future":1,"source":{"type":"url","value":"u","future":true}}]
        """)
        XCTAssertEqual((message.contentParts?.first as? ImagePart)?.source, .url(value: "u", mimeType: nil))
    }

    func test_decode_unknownPartTypeIsDroppedNotFatal() throws {
        let message = try decodeUser(parts: """
        [{"type":"text","text":"a"},{"type":"hologram","source":{}},{"type":"text","text":"b"}]
        """)
        XCTAssertEqual(message.contentParts?.compactMap { ($0 as? TextPart)?.text }, ["a", "b"])
    }

    func test_decode_unknownSourceTypeDropsThePartNotTheRun() throws {
        let message = try decodeUser(parts: """
        [{"type":"image","source":{"type":"teleport","value":"x"}},{"type":"text","text":"kept"}]
        """)
        XCTAssertEqual(message.contentParts?.count, 1)
        XCTAssertEqual((message.contentParts?.first as? TextPart)?.text, "kept")
    }

    // MARK: - Decoding: malformed known fields are fatal

    func test_decode_malformedKnownFieldsThrow() {
        let bad = [
            #"[{"type":"text"}]"#,                                                       // missing text
            #"[{"type":"text","text":5}]"#,                                              // wrong type
            #"[{"type":"text","text":"a","id":7}]"#,                                     // wrong-typed optional
            #"[{"type":"image"}]"#,                                                      // missing source
            #"[{"type":"image","source":"https://e.com/x.png"}]"#,                       // source not an object
            #"[{"type":"image","source":{"type":"data","value":"QUJD"}}]"#,              // data needs mimeType
            #"[{"type":"image","source":{"type":"data","value":"***","mimeType":"image/png"}}]"#, // bad base64
            #"[{"type":"image","source":{"type":"url"}}]"#,                              // missing value
            #"[{"type":"image","source":{"type":"url","value":"u","mimeType":3}}]"#,     // wrong-typed optional
            #"[{"type":"video","source":{"type":"file","value":"h","provider":9}}]"#     // wrong-typed optional
        ]
        for parts in bad {
            XCTAssertThrowsError(try decodeUser(parts: parts), parts)
        }
    }

    // MARK: - Round trip

    func test_roundTrip_everyPartKind() throws {
        let parts: [any ContentPart] = [
            TextPart(text: "t", id: "a", metadata: Data(#"{"x":1}"#.utf8)),
            ImagePart(source: .data(value: "QUJD", mimeType: "image/png"), id: "b"),
            AudioPart(source: .url(value: "https://e.com/a.mp3", mimeType: "audio/mpeg")),
            VideoPart(source: .file(value: "v", provider: "anthropic", mimeType: nil)),
            DocumentPart(source: .url(value: "https://e.com/d", mimeType: nil), metadata: Data(#"{"s":"m"}"#.utf8))
        ]
        let data = try encoder.encode(UserMessage.multimodal(id: "u1", parts: parts))
        let decoded = try XCTUnwrap(try decoder.decode(data) as? UserMessage)
        let again = try encoder.encode(decoded)

        let lhs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let rhs = try XCTUnwrap(JSONSerialization.jsonObject(with: again) as? NSDictionary)
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(decoded.contentParts?.count, 5)
    }

    // MARK: - Legacy input: translated, with warnings

    func test_decode_legacyBinaryImageURL_becomesImagePart() throws {
        let message = try decodeUser(parts: """
        [{"type":"binary","mimeType":"image/jpeg","url":"https://e.com/p.jpg"}]
        """)
        XCTAssertEqual(
            (message.contentParts?.first as? ImagePart)?.source,
            .url(value: "https://e.com/p.jpg", mimeType: "image/jpeg")
        )
    }

    func test_decode_legacyBinaryByMimeFamily() throws {
        let message = try decodeUser(parts: """
        [
          {"type":"binary","mimeType":"audio/wav","data":"QUJD"},
          {"type":"binary","mimeType":"video/mp4","url":"https://e.com/v"},
          {"type":"binary","mimeType":"application/pdf","data":"QUJD","filename":"a.pdf"}
        ]
        """)
        let parts = try XCTUnwrap(message.contentParts)
        XCTAssertTrue(parts[0] is AudioPart)
        XCTAssertTrue(parts[1] is VideoPart)
        XCTAssertTrue(parts[2] is DocumentPart)
        XCTAssertEqual((parts[2] as? DocumentPart)?.source, .data(value: "QUJD", mimeType: "application/pdf"))
    }

    func test_decode_legacyBinaryIDOnly_becomesFileSource() throws {
        let message = try decodeUser(parts: """
        [{"type":"binary","mimeType":"image/png","id":"blob-1"}]
        """)
        XCTAssertEqual(
            (message.contentParts?.first as? ImagePart)?.source,
            .file(value: "blob-1", provider: nil, mimeType: "image/png")
        )
    }

    func test_decode_legacyFlatImageAndDocument_areTranslated() throws {
        let message = try decodeUser(parts: """
        [
          {"type":"image","url":"https://e.com/i.png","detail":"high"},
          {"type":"document","data":"QUJD","mimeType":"application/pdf","title":"T"}
        ]
        """)
        XCTAssertEqual(
            (message.contentParts?[0] as? ImagePart)?.source,
            .url(value: "https://e.com/i.png", mimeType: nil)
        )
        XCTAssertEqual(
            (message.contentParts?[1] as? DocumentPart)?.source,
            .data(value: "QUJD", mimeType: "application/pdf")
        )
    }

    func test_decode_legacyFlatDataWithoutMimeType_isDroppedNotFatal() throws {
        let message = try decodeUser(parts: """
        [{"type":"image","data":"QUJD"},{"type":"text","text":"kept"}]
        """)
        XCTAssertEqual(message.contentParts?.count, 1)
    }

    func test_translator_reportsWarnings() throws {
        let object: [String: Any] = ["type": "binary", "mimeType": "image/png", "url": "u"]
        let result = try ContentPartCodec.decode(object, index: 0)
        XCTAssertNotNil(result.part)
        XCTAssertEqual(result.warnings, [.legacyBinaryTranslated])

        let flat: [String: Any] = ["type": "image", "url": "u", "detail": "low"]
        XCTAssertEqual(try ContentPartCodec.decode(flat, index: 0).warnings, [.legacyFlatShapeTranslated(type: "image")])

        let unknown: [String: Any] = ["type": "hologram"]
        let dropped = try ContentPartCodec.decode(unknown, index: 0)
        XCTAssertNil(dropped.part)
        XCTAssertEqual(dropped.warnings, [.unknownPartDropped(type: "hologram")])
    }

    func test_encode_deprecatedBinaryPart_isSentAs1_0Part() throws {
        let binary = BinaryInputContent(mimeType: "image/png", url: "https://e.com/p.png")
        let encoded = try XCTUnwrap(encodedParts([binary]).first)
        XCTAssertEqual(encoded["type"] as? String, "image")
        XCTAssertEqual(try source(encoded)["type"] as? String, "url")
        XCTAssertEqual(try source(encoded)["mimeType"] as? String, "image/png")
    }

    // MARK: - Source-less opaque file handling

    func test_fileSource_isNeverInterpreted() throws {
        // A handle that looks like a URL must be carried verbatim, not fetched or parsed.
        let message = try decodeUser(parts: """
        [{"type":"document","source":{"type":"file","value":"https://files.example/x?sig=1"}}]
        """)
        XCTAssertEqual(
            (message.contentParts?.first as? DocumentPart)?.source,
            .file(value: "https://files.example/x?sig=1", provider: nil, mimeType: nil)
        )
    }

    // MARK: - Type names

    func test_legacyTypeNamesAreAliases() {
        let part: InputContent = TextInputContent(text: "x")
        XCTAssertTrue(part is TextPart)
        XCTAssertTrue(ImageInputContent(url: "u", mimeType: "image/png") == ImagePart(url: "u", mimeType: "image/png"))
    }
}
