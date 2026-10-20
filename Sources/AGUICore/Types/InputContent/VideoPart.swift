// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// A video part (`VideoPart` in `schema.json`).
public struct VideoPart: ContentPart {
    /// The content type discriminator (always `"video"`).
    public let type: String

    /// Optional identifier for this part within its message.
    public let id: String?

    /// Where the video's bytes come from.
    public let source: PartSource

    /// Optional extra information about this part, as raw JSON.
    public let metadata: Data?

    /// Creates a video part.
    ///
    /// - Parameters:
    ///   - source: Where the video comes from
    ///   - id: Optional identifier for this part
    ///   - metadata: Optional raw JSON metadata
    public init(source: PartSource, id: String? = nil, metadata: Data? = nil) {
        self.type = "video"
        self.id = id
        self.source = source
        self.metadata = metadata
    }

    /// Creates a video part from a URL.
    ///
    /// - Parameters:
    ///   - url: URL of the video
    ///   - mimeType: Optional MIME type
    public init(url: String, mimeType: String? = nil) {
        self.init(source: .url(value: url, mimeType: mimeType))
    }

    /// Creates a video part from base64-encoded bytes.
    ///
    /// - Parameters:
    ///   - data: Base64-encoded bytes
    ///   - mimeType: MIME type of the bytes (required by the wire format)
    public init(data: String, mimeType: String) {
        self.init(source: .data(value: data, mimeType: mimeType))
    }
}

/// The pre-1.0 name of ``VideoPart``.
public typealias VideoInputContent = VideoPart
