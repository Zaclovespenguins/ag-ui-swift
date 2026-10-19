// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import Foundation

/// Whether an interrupt was answered or abandoned.
public enum ResumeStatus: String, Codable, Hashable, Sendable {

    /// The user answered the interrupt; the answer is in `ResumeEntry.payload`.
    case resolved

    /// The interrupt was abandoned and carries no answer.
    case cancelled
}

/// The client's answer to one `Interrupt`, sent in `RunAgentInput.resume`.
///
/// A resumed run must answer every open interrupt from the previous run. A
/// denial is a `.resolved` entry whose payload says so (for example
/// `{"approved": false}`); `.cancelled` means the interrupt was abandoned.
///
/// - Note: Interrupts are a draft extension of the AG-UI protocol.
public struct ResumeEntry: Codable, Hashable, Sendable {

    /// The `Interrupt.id` being answered.
    public let interruptId: String

    /// Whether the interrupt was answered or abandoned.
    public let status: ResumeStatus

    /// The answer, as raw JSON. Any JSON value, including a scalar such as `true`.
    ///
    /// Should match the interrupt's `responseSchema` when it has one.
    public let payload: Data?

    /// Envelope information about the response, such as signatures or routing
    /// keys, as a raw JSON object.
    public let metadata: Data?

    /// Creates a resume entry.
    ///
    /// - Parameters:
    ///   - interruptId: The interrupt being answered
    ///   - status: Whether it was answered or abandoned
    ///   - payload: Optional answer as raw JSON
    ///   - metadata: Optional envelope information as a raw JSON object
    public init(interruptId: String, status: ResumeStatus, payload: Data? = nil, metadata: Data? = nil) {
        self.interruptId = interruptId
        self.status = status
        self.payload = payload
        self.metadata = metadata
    }

    /// Creates an entry that answers an interrupt.
    ///
    /// - Parameters:
    ///   - interruptId: The interrupt being answered
    ///   - payload: Optional answer as raw JSON
    ///   - metadata: Optional envelope information as a raw JSON object
    public static func resolved(interruptId: String, payload: Data? = nil, metadata: Data? = nil) -> ResumeEntry {
        ResumeEntry(interruptId: interruptId, status: .resolved, payload: payload, metadata: metadata)
    }

    /// Creates an entry that abandons an interrupt without answering it.
    ///
    /// - Parameters:
    ///   - interruptId: The interrupt being abandoned
    ///   - metadata: Optional envelope information as a raw JSON object
    public static func cancelled(interruptId: String, metadata: Data? = nil) -> ResumeEntry {
        ResumeEntry(interruptId: interruptId, status: .cancelled, metadata: metadata)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case interruptId, status, payload, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interruptId = try container.decode(String.self, forKey: .interruptId)
        status = try container.decode(ResumeStatus.self, forKey: .status)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)?.data()
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)?.data()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interruptId, forKey: .interruptId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(payload.map(JSONValue.init(data:)), forKey: .payload)
        try container.encodeIfPresent(metadata.map(JSONValue.init(data:)), forKey: .metadata)
    }
}
