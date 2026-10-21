// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Tests for B4: tool results that are a string or an ordered array of content parts.
final class ToolResultContentTests: XCTestCase, AGUIEventDecoderTestHelpers {

    private let png = "iVBORw0KGgo="

    private func eventJSON(content: String) -> Data {
        Data("""
        {"type":"TOOL_CALL_RESULT","messageId":"m1","toolCallId":"c1","content":\(content)}
        """.utf8)
    }

    private func messageJSON(content: String?) -> Data {
        let contentField = content.map { ",\"content\":\($0)" } ?? ""
        return Data("""
        {"id":"t1","role":"tool","toolCallId":"c1"\(contentField)}
        """.utf8)
    }

    // MARK: - Value type

    func testStringLiteralIsText() {
        let content: ToolResultContent = "ok"
        XCTAssertEqual(content, .text("ok"))
    }

    func testEqualityAndHashingCompareParts() {
        let a = ToolResultContent.parts([TextPart(text: "a"), ImagePart(url: "https://x.test/i.png")])
        let b = ToolResultContent.parts([TextPart(text: "a"), ImagePart(url: "https://x.test/i.png")])
        let reordered = ToolResultContent.parts([ImagePart(url: "https://x.test/i.png"), TextPart(text: "a")])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, reordered)
        XCTAssertNotEqual(a, .text("a"))
    }

    // MARK: - Event decoding

    func testEventDecodesStringContent() throws {
        let event = try makeStrictDecoder().decode(eventJSON(content: "\"72F\"")) as? ToolCallResultEvent
        XCTAssertEqual(event?.resultContent, .text("72F"))
        XCTAssertEqual(event?.content, "72F")
    }

    func testEventDecodesOrderedParts() throws {
        let json = """
        [{"type":"text","text":"chart"},
         {"type":"image","source":{"type":"data","value":"\(png)","mimeType":"image/png"}},
         {"type":"text","text":"done"}]
        """
        let event = try makeStrictDecoder().decode(eventJSON(content: json)) as? ToolCallResultEvent
        guard case let .parts(parts)? = event?.resultContent else { return XCTFail("expected parts") }
        XCTAssertEqual(parts.map(\.type), ["text", "image", "text"])
        XCTAssertNil(event?.content, "string accessor is nil for part content")
    }

    func testEventWithEveryPartDroppedStillDecodes() throws {
        let json = #"[{"type":"hologram","x":1}]"#
        let event = try makeStrictDecoder().decode(eventJSON(content: json)) as? ToolCallResultEvent
        XCTAssertNotNil(event, "the result must still answer the call")
        XCTAssertEqual(event?.resultContent, .parts([]))
        XCTAssertEqual(event?.toolCallId, "c1")
    }

    func testEventEmptyArrayDecodes() throws {
        let event = try makeStrictDecoder().decode(eventJSON(content: "[]")) as? ToolCallResultEvent
        XCTAssertEqual(event?.resultContent, .parts([]))
    }

    func testEventRejectsNonStringNonArrayContent() {
        XCTAssertThrowsError(try makeStrictDecoder().decode(eventJSON(content: "42")))
        XCTAssertThrowsError(try makeStrictDecoder().decode(eventJSON(content: "{\"a\":1}")))
        XCTAssertThrowsError(try makeStrictDecoder().decode(eventJSON(content: "null")))
    }

    func testEventRejectsMalformedPart() {
        XCTAssertThrowsError(try makeStrictDecoder().decode(eventJSON(content: #"[{"type":"text"}]"#)))
        XCTAssertThrowsError(try makeStrictDecoder().decode(eventJSON(content: #"["not an object"]"#)))
    }

    // MARK: - Message decoding

    func testMessageDecodesStringContent() throws {
        let message = try MessageDecoder().decode(messageJSON(content: "\"hi\"")) as? ToolMessage
        XCTAssertEqual(message?.content, "hi")
        XCTAssertEqual(message?.resultContent, .text("hi"))
    }

    func testMessageDecodesParts() throws {
        let json = #"[{"type":"text","text":"a"},{"type":"image","source":{"type":"url","value":"https://x.test/i.png"}}]"#
        let message = try MessageDecoder().decode(messageJSON(content: json)) as? ToolMessage
        guard case let .parts(parts)? = message?.resultContent else { return XCTFail("expected parts") }
        XCTAssertEqual(parts.map(\.type), ["text", "image"])
    }

    func testMessageWithAllPartsDroppedKeepsToolCallId() throws {
        let message = try MessageDecoder().decode(messageJSON(content: #"[{"type":"hologram"}]"#)) as? ToolMessage
        XCTAssertEqual(message?.toolCallId, "c1")
        XCTAssertEqual(message?.resultContent, .parts([]))
    }

    func testMessageAbsentContentStaysEmptyText() throws {
        let message = try MessageDecoder().decode(messageJSON(content: nil)) as? ToolMessage
        XCTAssertEqual(message?.content, "")
    }

    func testMessageRejectsWrongContentType() {
        XCTAssertThrowsError(try MessageDecoder().decode(messageJSON(content: "7")))
    }

    // MARK: - Encoding

    func testMessageEncodesPartsAsArrayInOrder() throws {
        let message = ToolMessage(
            id: "t1",
            resultContent: .parts([TextPart(text: "a"), ImagePart(url: "https://x.test/i.png")]),
            toolCallId: "c1"
        )
        let data = try MessageEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
        XCTAssertNotNil(content[1]["source"])
    }

    func testMessageEncodesEmptyPartsAsEmptyArray() throws {
        let message = ToolMessage(id: "t1", resultContent: .parts([]), toolCallId: "c1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: MessageEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual((object["content"] as? [Any])?.count, 0)
        XCTAssertEqual(object["toolCallId"] as? String, "c1")
    }

    func testMessageStringContentStillEncodesAsString() throws {
        let message = ToolMessage(id: "t1", content: "ok", toolCallId: "c1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: MessageEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "ok")
    }

    func testMessageRoundTripsParts() throws {
        let original = ToolMessage(
            id: "t1",
            resultContent: .parts([TextPart(text: "a", id: "p1"), DocumentPart(source: .file(value: "f_1", provider: "x", mimeType: nil))]),
            toolCallId: "c1"
        )
        let decoded = try MessageDecoder().decode(MessageEncoder().encode(original)) as? ToolMessage
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Flattening for an old peer

    func testFlattenTextIsUnchangedAndSilent() {
        let flat = ToolResultContent.text("ok").flattened()
        XCTAssertEqual(flat.text, "ok")
        XCTAssertTrue(flat.warnings.isEmpty)
    }

    func testFlattenTextOnlyPartsJoinsWithoutWarning() {
        let flat = ToolResultContent.parts([TextPart(text: "a"), TextPart(text: "b")]).flattened()
        XCTAssertEqual(flat.text, "a\nb")
        XCTAssertTrue(flat.warnings.isEmpty)
    }

    func testFlattenDropsNonTextWithWarningAndNoPlaceholder() {
        let flat = ToolResultContent.parts([
            TextPart(text: "a"),
            ImagePart(url: "https://x.test/i.png"),
            AudioPart(source: .url(value: "https://x.test/a.mp3", mimeType: nil)),
            TextPart(text: "b")
        ]).flattened()
        XCTAssertEqual(flat.text, "a\nb")
        XCTAssertEqual(flat.warnings, [.partDroppedWhenFlattening(type: "image"),
                                       .partDroppedWhenFlattening(type: "audio")])
    }

    func testFlattenEmptyPartsIsEmptyStringNoWarning() {
        let flat = ToolResultContent.parts([]).flattened()
        XCTAssertEqual(flat.text, "")
        XCTAssertTrue(flat.warnings.isEmpty)
    }

    func testFlattenOnlyMediaIsEmptyStringWithWarnings() {
        let flat = ToolResultContent.parts([ImagePart(url: "https://x.test/i.png")]).flattened()
        XCTAssertEqual(flat.text, "")
        XCTAssertEqual(flat.warnings.count, 1)
    }
}
