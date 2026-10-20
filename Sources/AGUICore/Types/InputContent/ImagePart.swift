// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// An image part (`ImagePart` in `schema.json`).
public struct ImagePart: ContentPart {
    /// The content type discriminator (always `"image"`).
    public let type: String

    /// Optional identifier for this part within its message.
    public let id: String?

    /// Where the image's bytes come from.
    public let source: PartSource

    /// Optional extra information about this part, as raw JSON.
    public let metadata: Data?

    /// Creates an image part.
    ///
    /// - Parameters:
    ///   - source: Where the image comes from
    ///   - id: Optional identifier for this part
    ///   - metadata: Optional raw JSON metadata
    public init(source: PartSource, id: String? = nil, metadata: Data? = nil) {
        self.type = "image"
        self.id = id
        self.source = source
        self.metadata = metadata
    }

    /// Creates an image part from a URL.
    ///
    /// - Parameters:
    ///   - url: URL of the image
    ///   - mimeType: Optional MIME type
    public init(url: String, mimeType: String? = nil) {
        self.init(source: .url(value: url, mimeType: mimeType))
    }

    /// Creates an image part from base64-encoded bytes.
    ///
    /// - Parameters:
    ///   - data: Base64-encoded bytes
    ///   - mimeType: MIME type of the bytes (required by the wire format)
    public init(data: String, mimeType: String) {
        self.init(source: .data(value: data, mimeType: mimeType))
    }
}

/// The pre-1.0 name of ``ImagePart``.
public typealias ImageInputContent = ImagePart
