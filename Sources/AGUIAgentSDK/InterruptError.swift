// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

/// Errors thrown before a run starts when a thread's interrupts are not handled correctly.
///
/// - Note: Interrupts are a draft extension of the AG-UI protocol.
public enum InterruptError: Error, Equatable, Sendable {

    /// The thread has pending interrupts that the request does not answer.
    ///
    /// Thrown by `sendMessage` and `chat` while a thread is paused, and by `resume`
    /// when its entries skip an interrupt.
    case unansweredInterrupts(ids: [String])

    /// The resume entries name interrupts that are not pending on the thread.
    case unknownInterrupts(ids: [String])

    /// The interrupt's deadline has passed, so it can only be cancelled.
    case expired(id: String)
}

extension InterruptError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unansweredInterrupts(let ids):
            return "Thread has \(ids.count) pending interrupt(s) not addressed by resume: \(ids.joined(separator: ", "))"
        case .unknownInterrupts(let ids):
            return "Resume references unknown interrupt id(s): \(ids.joined(separator: ", "))"
        case .expired(let id):
            return "Interrupt \(id) has expired and can no longer be answered. Cancel it to continue the thread."
        }
    }
}

/// Deadline checks for interrupts.
enum InterruptExpiry {

    /// Whether the interrupt's `expiresAt` is at or before `now`.
    ///
    /// Accepts ISO-8601 with or without fractional seconds. An absent or unparseable
    /// deadline is treated as not expired.
    static func isExpired(_ interrupt: Interrupt, now: Date = Date()) -> Bool {
        guard let raw = interrupt.expiresAt, let deadline = parse(raw) else { return false }
        return deadline <= now
    }

    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
