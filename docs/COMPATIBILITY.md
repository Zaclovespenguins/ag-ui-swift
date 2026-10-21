# Protocol compatibility and migration

This guide describes the implementation through the B4–B13 integration and reference-wire tests on October 21, 2026. AGUISwift targets AG-UI 1.0, but does not yet claim complete conformance. Historical integration commits and validation results are preserved in the [integration handoff](../handoffs/2026-10-21-b4-b13-integration.md).

## Content parts and tool results

User media uses the AG-UI 1.0 `source` union rather than flat media fields. `ContentPart` implementations include `TextPart`, `ImagePart`, `AudioPart`, `VideoPart`, and `DocumentPart`. Media `PartSource` values are inline base64 data with a required MIME type, URLs with an optional MIME type, or opaque provider file handles. File handles must not be fetched or parsed. Parts carry optional IDs and metadata.

Legacy input-content names remain available as aliases. Legacy flat media and retired binary inputs are translated to current parts; outgoing content uses the current shape. Applications should migrate to the part/source APIs and surface translation warnings.

`ToolMessage` and `ToolCallResultEvent` now expose `resultContent: ToolResultContent`, either `.text(String)` or `.parts([any ContentPart])`. Existing string initializers remain available. Text accessors, including `ToolCallResultEvent.content`, are optional: parts do not implicitly become text. An empty parts array still answers a tool call.

For a text-only peer, call `resultContent.flattened()`. It joins text parts with newlines and drops other parts without placeholders; surface the returned warnings. Automatic routing through a unified warning channel is still pending.

## Request encoding and message fields

- Empty state, tools, and context are omitted. Absent/null state becomes `{}` on decode; absent/null tools and context become empty arrays. `forwardedProps` still defaults to and encodes `{}`.
- Nil optional fields are omitted. Null values nested inside state, forwarded properties, metadata, and resume payload objects survive. A whole null resume payload is omitted.
- `RunAgentInput.protocolVersion` and its builder setter are available and survive send-path transformations. The default is nil; version negotiation and automatically sending `"1.0"` are not implemented. Set it explicitly when required by a peer.
- Display-only activity messages are stripped by the builder, abstract-agent send path, and HTTP transport. Local history and direct `JSONEncoder` output can retain them.
- Message encoding preserves `encryptedValue`. `ToolMessage.name` remains a local/decoded property but is omitted on send; `error` remains alongside content.
- Missing text-message start roles default to assistant. A present wrong-typed role fails decoding.
- Hand-decoded optional string, boolean, and string-array fields reject present wrong types. Missing/null optional values decode as absent. Malformed known fields must not be treated as unknown extensions.

## Outcomes, interrupts, and cancellation

`RunFinishedOutcome` supports success with pending tool-call IDs, interrupts, and cancellation. An absent outcome means success. Unknown outcomes still have a public representation; stripping them according to the target spec remains a conformance decision. A malformed `RUN_FINISHED` fails the stream with `ClientError.decodingError`.

`StatefulAgUiAgent` records pending interrupts per thread. Inspect `pendingInterrupts(for:)`, then call `resume(threadId:entries:)` with one entry per interrupt. New messages and chat are rejected with `InterruptError` while interrupts remain pending. `ResumeValidator` rejects missing, unknown, duplicate, and expired resolved answers; expired interrupts may be cancelled.

`AgUiAgent` keeps no interrupt history. Pass pending interrupts as `answering:` when using `sendMessage` with `resume:`. Low-level `HttpAgent`, `AbstractAgent.runAgent(parameters:)`, and `run(input:)` leave coverage validation to their caller.

`AgentSubscriber.onRunCancelled` defaults to a no-op. Producer cancellation, local abort, and transport cancellation use cancellation callbacks rather than success/failure finalization. Both view models expose `lastRunWasCancelled` and keep cancellation out of `lastError`. A late producer error clears the cancellation flag. Abandoning a stream does not synthesize `RUN_FINISHED`.

Producer `RUN_ERROR`, including one arriving after `RUN_FINISHED`, reaches failure subscribers and `runAgent` as `AgentRunError`. Consumer protocol rejection remains `AGUIProtocolError`.

## Stream verification and HTTP/SSE

The verifier resets per-run tracking on each `RUN_STARTED`, including after errors; `RUN_ERROR` closes open items. It validates reasoning spans/messages, first-chunk identifiers, repeated opener fields, and reopening consistency. Activity deltas without a preceding snapshot are skipped and reported through the warning hook. Subagent ownership rules remain unimplemented.

SSE supports LF/CRLF framing, comments, and data-only dispatch. A present non-SSE content type (including an empty header) is rejected before decoding; a missing header remains tolerated. Both HTTP run entry points reject truncated streams, including an unfinished final run following historical replay.

Pre-stream connection retries create fresh requests. Mid-stream failures are not automatically retried or resumed. Legacy cursor inspection and explicit header APIs remain available, but automatic AG-UI 1.0 streaming does not use `Last-Event-ID`.

## Remaining gaps

The [conformance plan](../plans/IMPLEMENTATION_PLAN.md) and [schema diff](../plans/B12_SCHEMA_DIFF.md) track:

- Three subagent event types, attribution, and ownership/nesting verification.
- Version negotiation and the default outgoing protocol version.
- Token usage, complete metadata propagation and merging, and capability models.
- Unknown-material handling and a unified translation, enforcement, and warning pipeline. Unknown event types still throw by default.
- Schema defaults for tool parameters and stricter public role types.
- Frontend tool continuation: `ClientToolResponseHandler` must send complete history with a fresh run ID and forward the agent reply.
- Broader automated conformance fixtures and schema validation in CI. HTTP/Protobuf remains deferred.

## Validation

Run from the repository root:

```sh
swift build
swift test
swift test --filter ReferenceSDKWireTests
```

`ReferenceSDKWireTests` decodes SSE produced by `@ag-ui/encoder` 1.0.3 and can export three representative Swift requests:

```sh
AGUI_WIRE_OUTPUT_PATH=/tmp/agui-requests.json swift test --filter ReferenceSDKWireTests
node scripts/validate-wire-reference.cjs /path/to/node_modules /tmp/agui-requests.json /path/to/schema.json
```

The Node modules directory must contain `@ag-ui/core` 1.0.3 and `ajv` with draft-2020 support. Supply the AG-UI 1.0 schema at upstream commit `85a427d0558d0b117191690bad287da299acc91d`. These dependencies and the schema must be supplied separately; the script does not install or download them. This validates representative requests, not every protocol shape.

The integration handoff records 1,584 passing tests, a successful build and iOS simulator build, and successful reference-schema validation. Its scoped SwiftLint run failed with 190 errors and 473 warnings; lint was not green. These are historical results, not a guarantee for future changes. A live adapter smoke test and a complete CI conformance harness remain open.
