# AGUISwift Architecture

AGUISwift is a Swift 5.9 package for iOS 16+ and macOS 13+. It targets AG-UI 1.0; full conformance remains in progress. See the [compatibility guide](docs/COMPATIBILITY.md) for current behavior and migration details.

## Module dependencies

```text
Your application
       │
  AGUIAgentSDK
   ┌───┼───────┐
AGUIClient  AGUITools
   └───┼───────┘
    AGUICore
```

`AGUICore` has no module dependencies. `AGUIClient` and `AGUITools` each depend on core; `AGUIAgentSDK` depends on all three. Each library is a separate package product. The only external package dependency is `swift-docc-plugin`.

## AGUICore

Core contains protocol value types, JSON encoding and decoding, domain identifiers, and serialization adapters. Arbitrary JSON fields use raw `Data`.

- Events cover run and step lifecycle, text messages, tool calls, state and message snapshots, JSON Patch deltas, activity, reasoning, raw, and custom events: 28 protocol event types plus an internal unknown-event sentinel.
- `AGUIEventDecoder` dispatches through per-category decoder registries and DTOs. Legacy thinking events translate to reasoning events.
- Messages support text and media content parts with data, URL, or opaque provider file sources. Tool messages and tool-result events support text or ordered parts.
- `RunAgentInput` and its builder carry messages, state, tools, context, forwarded properties, resume entries, and an optional protocol version.
- `RunFinishedOutcome`, `Interrupt`, `ResumeEntry`, and `ResumeValidator` model terminal outcomes and validate interrupt answers.
- Domain identifiers (`ThreadId`, `RunId`, `EventTimestamp`) remain separate from their serialization wrappers and adapters.

## AGUIClient

The client module implements HTTP/SSE transport and custom-agent infrastructure.

- `HttpAgent` sends run inputs and decodes streamed responses. It rejects present non-SSE content types and streams that end before the final run terminates.
- `SseParser` handles LF/CRLF framing, comments, and data dispatch. Pre-stream connection retries create fresh requests; interrupted streams are not automatically resumed or retried.
- Event streams expand chunks, verify lifecycle and message consistency, and apply state and message updates. Reasoning spans and activity snapshot ordering are checked alongside text, tool, and step lifecycles.
- `AbstractAgent` coordinates runs, state, and subscribers. Producer failures use `AgentRunError`; consumer protocol rejection uses `AGUIProtocolError`. Cancellation has its own subscriber callback.
- Activity messages are retained for display but stripped at package send boundaries.

## AGUITools

The tool framework provides tool registration, executors, execution management, circuit breakers, and error handling. It depends only on protocol types, so it can be used without the HTTP client or high-level SDK.

## AGUIAgentSDK

- `AgUiAgent` is stateless: callers supply context and the interrupts being answered.
- `StatefulAgUiAgent` maintains conversation history and pending interrupts per thread, sends history, and validates resume coverage before continuing.
- `ChatAgent`, configuration builders, and `ConversationHistoryManager` provide higher-level interaction APIs.
- Both view models expose cancellation through `lastRunWasCancelled` without treating it as `lastError`; a later producer error supersedes cancellation.
- `ClientToolResponseHandler` exists, but its complete-history continuation and reply forwarding still need work.

## Concurrency and validation

The implementation uses async/await, actors for shared mutable state, and explicit main-actor isolation for UI-facing types. Streaming owners retain and cancel background task handles. Diagnostics must not expose credentials or complete user content; verifier diagnostics are debug-only.

Tests are organized by module under `Tests/`. They cover decoding, encoding, verification, transport, tools, history, interrupts, and cancellation with mocked external dependencies. Reference SDK fixtures and a request-schema validator supplement Swift round trips. See [validation instructions](docs/COMPATIBILITY.md#validation).

## Remaining protocol work

Subagent events and attribution, protocol version negotiation, token usage, complete metadata propagation/merge semantics, capability models, and a unified processing/warning pipeline remain open. Unknown-event and unknown-outcome behavior still need conformance decisions. HTTP/Protobuf is deferred. The [conformance plan](plans/IMPLEMENTATION_PLAN.md) tracks these separately from implemented features.
