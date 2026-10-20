// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// An audio part (`AudioPart` in `schema.json`).
public struct AudioPart: ContentPart {
    /// The content type discriminator (always `"audio"`).
    public let type: String

    /// Optional identifier for this part within its message.
    public let id: String?

    /// Where the audio's bytes come from.
    public let source: PartSource

    /// Optional extra information about this part, as raw JSON.
    public let metadata: Data?

    /// Creates an audio part.
    ///
    /// - Parameters:
    ///   - source: Where the audio comes from
    ///   - id: Optional identifier for this part
    ///   - metadata: Optional raw JSON metadata
    public init(source: PartSource, id: String? = nil, metadata: Data? = nil) {
        self.type = "audio"
        self.id = id
        self.source = source
        self.metadata = metadata
    }

    /// Creates an audio part from a URL.
    ///
    /// - Parameters:
    ///   - url: URL of the audio
    ///   - mimeType: Optional MIME type
    public init(url: String, mimeType: String? = nil) {
        self.init(source: .url(value: url, mimeType: mimeType))
    }

    /// Creates an audio part from base64-encoded bytes.
    ///
    /// - Parameters:
    ///   - data: Base64-encoded bytes
    ///   - mimeType: MIME type of the bytes (required by the wire format)
    public init(data: String, mimeType: String) {
        self.init(source: .data(value: data, mimeType: mimeType))
    }
}

/// The pre-1.0 name of ``AudioPart``.
public typealias AudioInputContent = AudioPart
