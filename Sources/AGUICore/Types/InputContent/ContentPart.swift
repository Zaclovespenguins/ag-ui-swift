// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// One part of a message body, as defined by AG-UI 1.0 (`ContentPart` in `schema.json`).
///
/// A part is what a person sends in a user message. Parts are discriminated by
/// `type`; the wire values are `"text"`, `"image"`, `"audio"`, `"video"` and
/// `"document"`.
///
/// - ``TextPart``: plain text
/// - ``ImagePart``, ``AudioPart``, ``VideoPart``, ``DocumentPart``: media whose bytes
///   come from a ``PartSource``
///
/// ``BinaryInputContent`` is retired in 1.0. It is still accepted as input and translated
/// to one of the parts above; it is never sent.
///
/// - SeeAlso: ``PartSource``, ``UserMessage``
public protocol ContentPart: Sendable, Hashable {
    /// The wire discriminator (`"text"`, `"image"`, `"audio"`, `"video"` or `"document"`).
    var type: String { get }

    /// Optional identifier for this part within its message.
    var id: String? { get }

    /// Optional extra information about this part, as raw JSON.
    ///
    /// Unconstrained by the protocol. Stored as `Data` like other arbitrary JSON fields.
    var metadata: Data? { get }
}

/// The pre-1.0 name of ``ContentPart``.
public typealias InputContent = ContentPart
