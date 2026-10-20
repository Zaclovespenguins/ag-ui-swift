// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// A text part (`TextPart` in `schema.json`).
public struct TextPart: ContentPart {
    /// The content type discriminator (always `"text"`).
    public let type: String

    /// Optional identifier for this part within its message.
    public let id: String?

    /// The text.
    public let text: String

    /// Optional extra information about this part, as raw JSON.
    public let metadata: Data?

    /// Creates a text part.
    ///
    /// - Parameters:
    ///   - text: The text
    ///   - id: Optional identifier for this part
    ///   - metadata: Optional raw JSON metadata
    public init(text: String, id: String? = nil, metadata: Data? = nil) {
        self.type = "text"
        self.id = id
        self.text = text
        self.metadata = metadata
    }
}

/// The pre-1.0 name of ``TextPart``.
public typealias TextInputContent = TextPart
