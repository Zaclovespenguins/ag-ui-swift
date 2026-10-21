// Copyright (c) 2025 Perfect Aduh. MIT License. See LICENSE for details.

import AGUICore
import Foundation

/// AsyncSequence of AG-UI events from a streaming HTTP response.
///
/// `EventStream` integrates the complete event streaming pipeline:
/// 1. Reads bytes from HTTP response (any AsyncSequence<UInt8>)
/// 2. Parses Server-Sent Events (SSE) using SseParser
/// 3. Decodes AG-UI events using AGUIEventDecoder
/// 4. Handles errors gracefully
///
public struct EventStream<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    public typealias Element = any AGUIEvent

    // MARK: - Shared last-event-id box

    /// Reference box that lets the iterator write the last SSE id back to the stream.
    ///
    /// Using a class (reference semantics) means every iterator created from the same
    /// stream updates the same location, so callers can read `lastEventId` on the
    /// stream value after an iterator throws.
    ///
    /// Declared as an `actor` so the compiler synthesises `Sendable` automatically
    /// and serialises all reads and writes without manual locking.
    actor LastEventIdBox {
        var value: String?

        func set(_ newValue: String?) {
            value = newValue
        }
    }

    // MARK: - Stored properties

    /// The source byte stream from HTTP response.
    private let bytes: Bytes

    /// The AG-UI event decoder.
    private let decoder: AGUIEventDecoder

    private let requiresTerminalEvent: Bool

    /// Shared box updated by the iterator whenever a non-nil SSE `id:` field is seen.
    private let lastEventIdBox = LastEventIdBox()

    // MARK: - Public surface

    /// The most recent SSE event `id:` field received, or `nil` if none has arrived yet.
    ///
    /// Retained for diagnostics and compatibility. AG-UI 1.0 does not use SSE
    /// identifiers to resume a broken stream.
    public var lastEventId: String? { get async { await lastEventIdBox.value } }

    // MARK: - Initialization

    /// Creates a new event stream.
    ///
    /// - Parameters:
    ///   - bytes: Async sequence of bytes from HTTP streaming response
    ///   - decoder: AG-UI event decoder
    public init(bytes: Bytes, decoder: AGUIEventDecoder) {
        self.init(bytes: bytes, decoder: decoder, requiresTerminalEvent: false)
    }

    init(bytes: Bytes, decoder: AGUIEventDecoder, requiresTerminalEvent: Bool) {
        self.bytes = bytes
        self.decoder = decoder
        self.requiresTerminalEvent = requiresTerminalEvent
    }

    /// Creates an async iterator for streaming events.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            bytes: bytes.makeAsyncIterator(), decoder: decoder, lastEventIdBox: lastEventIdBox,
            requiresTerminalEvent: requiresTerminalEvent
        )
    }

    /// Iterator that processes streaming bytes into AG-UI events.
    ///
    /// The iterator maintains internal state for:
    /// - UTF-8 byte accumulation
    /// - SSE event parsing
    /// - Event queue management
    /// - Last-Event-ID tracking (via shared `LastEventIdBox`)
    public struct AsyncIterator: AsyncIteratorProtocol {
        /// Source byte iterator.
        private var bytesIterator: Bytes.AsyncIterator

        /// AG-UI event decoder.
        private let decoder: AGUIEventDecoder

        /// SSE parser for extracting events from stream.
        private var sseParser = SseParser()

        /// Queue of decoded events ready to return.
        private var eventQueue: [any AGUIEvent] = []

        /// Buffer for accumulating UTF-8 bytes.
        private var utf8Buffer: [UInt8] = []

        /// A fatal decoding error held back until the events decoded before it have been returned.
        private var pendingError: (any Error)?

        /// Shared reference that is updated with the most recent SSE `id:` value.
        private let lastEventIdBox: LastEventIdBox
        private let requiresTerminalEvent: Bool
        private var sawTerminalEvent = false

        /// Creates a new iterator.
        ///
        /// - Parameters:
        ///   - bytes: Source byte iterator
        ///   - decoder: AG-UI event decoder
        ///   - lastEventIdBox: Shared box written to whenever a non-nil SSE id is seen
        init(
            bytes: Bytes.AsyncIterator, decoder: AGUIEventDecoder, lastEventIdBox: LastEventIdBox,
            requiresTerminalEvent: Bool
        ) {
            self.bytesIterator = bytes
            self.decoder = decoder
            self.lastEventIdBox = lastEventIdBox
            self.requiresTerminalEvent = requiresTerminalEvent
        }

        /// Whether the raw event data has `"type": "RUN_FINISHED"`.
        private static func isRunFinished(_ data: Data) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object["type"] as? String == EventType.runFinished.rawValue
        }

        /// Returns the next AG-UI event from the stream.
        ///
        /// This method:
        /// 1. Returns queued events first
        /// 2. Reads and accumulates bytes until valid UTF-8
        /// 3. Parses SSE events from UTF-8 strings
        /// 4. Decodes AG-UI events from SSE data
        /// 5. Returns the next available event
        ///
        /// - Returns: Next event, or nil when stream ends
        /// - Throws: Network errors, or `ClientError.decodingError` when a `RUN_FINISHED`
        ///   event cannot be decoded. Other undecodable events are skipped.
        public mutating func next() async throws -> (any AGUIEvent)? {
            let event = try await decodeNext()
            if let event {
                if event is RunStartedEvent {
                    sawTerminalEvent = false
                } else if event is RunFinishedEvent || event is RunErrorEvent {
                    sawTerminalEvent = true
                }
            } else if requiresTerminalEvent && !sawTerminalEvent {
                throw ClientError.streamError("Connection closed before RUN_FINISHED or RUN_ERROR")
            }
            return event
        }

        private mutating func decodeNext() async throws -> (any AGUIEvent)? {
            // Return queued events first.
            // Yield before returning a buffered event so callers on the main actor
            // give the run loop a chance to render UI between events. Without this,
            // a burst of SSE data arriving in one network packet fills the queue and
            // all events are consumed synchronously — SwiftUI never sees the
            // intermediate streaming states (typing dots, streaming cursor).
            guard eventQueue.isEmpty else {
                await Task.yield()
                return eventQueue.removeFirst()
            }

            if let error = pendingError {
                pendingError = nil
                throw error
            }

            // Read and process bytes until we have events
            while let byte = try await bytesIterator.next() {
                utf8Buffer.append(byte)

                // Try to decode accumulated bytes as UTF-8
                if let string = String(bytes: utf8Buffer, encoding: .utf8) {
                    // Successful decode - process the chunk
                    utf8Buffer.removeAll()

                    // Parse SSE events from the string chunk
                    let sseEvents = sseParser.parse(string)

                    // Decode AG-UI events from SSE data
                    for sseEvent in sseEvents {
                        // Track the last-event-id for reconnection support.
                        // The id is captured before decoding so it is available even
                        // when the accompanying data fails to decode.
                        if let id = sseEvent.id {
                            await lastEventIdBox.set(id)
                        }

                        guard let data = sseEvent.data.data(using: .utf8) else {
                            // Skip events with invalid UTF-8 data
                            continue
                        }

                        do {
                            let event = try decoder.decode(data)
                            eventQueue.append(event)
                        } catch {
                            // A RUN_FINISHED that fails to decode (for example, a malformed
                            // interrupt outcome) must not be skipped: the run would end with
                            // neither a terminal event nor an error. Fail the stream instead,
                            // after returning the events decoded before it.
                            if Self.isRunFinished(data) {
                                pendingError = ClientError.decodingError(error)
                                break
                            }

                            // Non-fatal decoding errors are silently ignored
                            // The stream continues processing subsequent events
                            // Applications can implement custom error handling if needed
                            #if DEBUG
                            print("[EventStream] ⚠ Decode error: \(error) — raw: \(sseEvent.data.prefix(200))")
                            #endif
                        }
                    }

                    // Return first decoded event if available
                    guard eventQueue.isEmpty else {
                        return eventQueue.removeFirst()
                    }

                    if let error = pendingError {
                        pendingError = nil
                        throw error
                    }
                } else if utf8Buffer.count > 4 {
                    // Invalid UTF-8 sequence (UTF-8 characters are max 4 bytes)
                    // Skip the first byte and try to resynchronize
                    utf8Buffer.removeFirst()
                }
            }

            // Stream ended - return any remaining queued events
            guard eventQueue.isEmpty else {
                return eventQueue.removeFirst()
            }

            // No more events
            return nil
        }
    }
}
