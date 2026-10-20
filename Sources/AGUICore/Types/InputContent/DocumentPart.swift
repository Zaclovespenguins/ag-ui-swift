// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// A document part (`DocumentPart` in `schema.json`).
public struct DocumentPart: ContentPart {
    /// The content type discriminator (always `"document"`).
    public let type: String

    /// Optional identifier for this part within its message.
    public let id: String?

    /// Where the document's bytes come from.
    public let source: PartSource

    /// Optional extra information about this part, as raw JSON.
    public let metadata: Data?

    /// Creates a document part.
    ///
    /// - Parameters:
    ///   - source: Where the document comes from
    ///   - id: Optional identifier for this part
    ///   - metadata: Optional raw JSON metadata
    public init(source: PartSource, id: String? = nil, metadata: Data? = nil) {
        self.type = "document"
        self.id = id
        self.source = source
        self.metadata = metadata
    }

    /// Creates a document part from a URL.
    ///
    /// - Parameters:
    ///   - url: URL of the document
    ///   - mimeType: Optional MIME type
    public init(url: String, mimeType: String? = nil) {
        self.init(source: .url(value: url, mimeType: mimeType))
    }

    /// Creates a document part from base64-encoded bytes.
    ///
    /// - Parameters:
    ///   - data: Base64-encoded bytes
    ///   - mimeType: MIME type of the bytes (required by the wire format)
    public init(data: String, mimeType: String) {
        self.init(source: .data(value: data, mimeType: mimeType))
    }
}

/// The pre-1.0 name of ``DocumentPart``.
public typealias DocumentInputContent = DocumentPart
