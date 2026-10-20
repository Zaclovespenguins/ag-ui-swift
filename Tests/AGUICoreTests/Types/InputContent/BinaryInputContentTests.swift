// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import XCTest
@testable import AGUICore

/// Tests for the BinaryInputContent type
final class BinaryInputContentTests: XCTestCase {
    // MARK: - Initialization Tests

    func testInitWithURL() {
        let content = BinaryInputContent(
            mimeType: "image/png",
            url: "https://example.com/image.png"
        )

        XCTAssertEqual(content.mimeType, "image/png")
        XCTAssertEqual(content.url, "https://example.com/image.png")
        XCTAssertNil(content.id)
        XCTAssertNil(content.data)
        XCTAssertNil(content.filename)
        XCTAssertEqual(content.type, "binary")
    }

    func testInitWithID() {
        let content = BinaryInputContent(
            mimeType: "application/pdf",
            id: "file-123"
        )

        XCTAssertEqual(content.mimeType, "application/pdf")
        XCTAssertEqual(content.id, "file-123")
        XCTAssertNil(content.url)
        XCTAssertNil(content.data)
    }

    func testInitWithData() {
        let base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="

        let content = BinaryInputContent(
            mimeType: "image/png",
            data: base64Data
        )

        XCTAssertEqual(content.mimeType, "image/png")
        XCTAssertEqual(content.data, base64Data)
        XCTAssertNil(content.id)
        XCTAssertNil(content.url)
    }

    func testInitWithAllFields() throws {
        let content = try BinaryInputContent(
            mimeType: "image/jpeg",
            id: "img-456",
            url: "https://example.com/photo.jpg",
            data: "base64data",
            filename: "vacation.jpg"
        )

        XCTAssertEqual(content.mimeType, "image/jpeg")
        XCTAssertEqual(content.id, "img-456")
        XCTAssertEqual(content.url, "https://example.com/photo.jpg")
        XCTAssertEqual(content.data, "base64data")
        XCTAssertEqual(content.filename, "vacation.jpg")
    }

    func testInitWithFilename() {
        let content = BinaryInputContent(
            mimeType: "application/pdf",
            url: "https://docs.example.com/report.pdf",
            filename: "quarterly-report.pdf"
        )

        XCTAssertEqual(content.filename, "quarterly-report.pdf")
    }

    // MARK: - Validation Tests

    func testInitFailsWithoutSourceFields() {
        XCTAssertThrowsError(
            try BinaryInputContent.validate(
                mimeType: "image/png",
                id: nil,
                url: nil,
                data: nil
            )
        ) { error in
            guard case BinaryInputContent.ValidationError.noSourceProvided = error else {
                XCTFail("Expected ValidationError.noSourceProvided but got \(error)")
                return
            }
        }
    }

    // MARK: - InputContent Protocol Conformance Tests

    func testConformsToInputContent() {
        let content: any InputContent = BinaryInputContent(
            mimeType: "image/png",
            url: "https://example.com/test.png"
        )

        XCTAssertEqual(content.type, "binary")
    }

    func testMixedInputContentArray() {
        let contents: [any InputContent] = [
            TextInputContent(text: "Check this image:"),
            BinaryInputContent(mimeType: "image/png", url: "https://example.com/photo.png"),
            TextInputContent(text: "What do you see?")
        ]

        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0].type, "text")
        XCTAssertEqual(contents[1].type, "binary")
        XCTAssertEqual(contents[2].type, "text")
    }

    // Decoding and encoding of the retired `binary` shape are covered in ContentPartTests.

    // MARK: - Equatable Tests

    func testEquality() {
        let content1 = BinaryInputContent(mimeType: "image/png", url: "https://test.com/1.png")
        let content2 = BinaryInputContent(mimeType: "image/png", url: "https://test.com/1.png")
        let content3 = BinaryInputContent(mimeType: "image/jpeg", url: "https://test.com/1.png")
        let content4 = BinaryInputContent(mimeType: "image/png", id: "img-1")

        XCTAssertEqual(content1, content2)
        XCTAssertNotEqual(content1, content3)
        XCTAssertNotEqual(content1, content4)
    }

    // MARK: - Hashable Tests

    func testHashable() {
        let content1 = BinaryInputContent(mimeType: "image/png", id: "img-1")
        let content2 = BinaryInputContent(mimeType: "image/png", id: "img-2")

        let set: Set<BinaryInputContent> = [content1, content2]
        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(content1))
        XCTAssertTrue(set.contains(content2))
    }

    // MARK: - Sendable Tests

    func testSendableConformance() {
        let content = BinaryInputContent(mimeType: "image/png", url: "https://test.com/img.png")

        Task {
            let capturedContent = content
            XCTAssertEqual(capturedContent.mimeType, "image/png")
        }
    }

    // MARK: - Real-world Usage Tests

    func testImageFromURL() {
        let imageContent = BinaryInputContent(
            mimeType: "image/jpeg",
            url: "https://photos.example.com/sunset.jpg",
            filename: "sunset.jpg"
        )

        XCTAssertEqual(imageContent.mimeType, "image/jpeg")
        XCTAssertNotNil(imageContent.url)
        XCTAssertEqual(imageContent.filename, "sunset.jpg")
    }

    func testPDFDocument() {
        let pdfContent = BinaryInputContent(
            mimeType: "application/pdf",
            id: "doc-report-2024",
            filename: "annual-report.pdf"
        )

        XCTAssertEqual(pdfContent.mimeType, "application/pdf")
        XCTAssertEqual(pdfContent.id, "doc-report-2024")
    }

    func testBase64EmbeddedImage() {
        let smallPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="

        let imageContent = BinaryInputContent(
            mimeType: "image/png",
            data: smallPNG,
            filename: "pixel.png"
        )

        XCTAssertEqual(imageContent.data, smallPNG)
        XCTAssertTrue(imageContent.data?.hasSuffix("==") ?? false)
    }

    func testAudioFile() {
        let audioContent = BinaryInputContent(
            mimeType: "audio/mpeg",
            url: "https://cdn.example.com/audio/track01.mp3",
            filename: "track01.mp3"
        )

        XCTAssertEqual(audioContent.mimeType, "audio/mpeg")
    }

    func testTypeAlwaysBinary() {
        let content1 = BinaryInputContent(mimeType: "image/png", url: "https://test.com/1.png")
        let content2 = BinaryInputContent(mimeType: "application/pdf", id: "doc-1")
        let content3 = BinaryInputContent(mimeType: "audio/wav", data: "base64data")

        XCTAssertEqual(content1.type, "binary")
        XCTAssertEqual(content2.type, "binary")
        XCTAssertEqual(content3.type, "binary")
    }
}
