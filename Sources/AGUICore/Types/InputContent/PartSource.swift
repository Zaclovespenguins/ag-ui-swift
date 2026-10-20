// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Where a media part's bytes come from (`PartSource` in `schema.json`).
public enum PartSource: Sendable, Hashable {
    /// Bytes carried inline, base64-encoded. The MIME type is required because nothing
    /// else tells a consumer how to read them.
    case data(value: String, mimeType: String)

    /// Bytes referenced by URL and fetched by whoever needs them. The MIME type is
    /// optional because the response can say.
    case url(value: String, mimeType: String?)

    /// Bytes already held by a provider under a handle it issued, such as an OpenAI file id.
    ///
    /// The handle is opaque: a consumer **must not** fetch it, parse it, or read a scheme
    /// out of it. `provider` is the lowercase vendor id (`openai`, `anthropic`, `google`)
    /// when the producer knows it.
    case file(value: String, provider: String?, mimeType: String?)
}
