# AGUISwift: AG-UI 1.0 Conformance Plan

> **Goal**: make the AGUISwift client conform to **AG-UI protocol 1.0**.
> **Supersedes**: `plans/OLD_IMPLEMENTATION_PLAN.md` (April 2026 Kotlin-parity plan). The Kotlin SDK is now an API reference only, not the target.

## Baseline

| Item | Value |
|---|---|
| Spec target | AG-UI **1.0**, frozen: `docs/spec/1.0/` in [ag-ui-protocol/ag-ui](https://github.com/ag-ui-protocol/ag-ui) |
| Upstream snapshot | `main` @ `b959aa6` (2026-10-20) |
| Draft (1.1) | `docs/spec/draft/changelog.mdx` lists no changes yet. Re-check before each release. |
| Repo snapshot | `feature/interrupt-resume` @ `4337612`, plus uncommitted B10 work in the tree |
| Validation at snapshot | `swift build` passes; `swift test` reports "All tests passed". Not run: `swiftlint`, iOS/macOS `xcodebuild`. |

**Sources of truth, in order:** `1.0/schema.json` (structure), the normative pages under `1.0/` (behavior), then `1.0/changelog.mdx` (summary). Upstream *release notes* and the `docs.ag-ui.com/concepts/*` pages are integration changelogs and explainers, not the spec. Where they disagree with `1.0/`, `1.0/` wins. (Example: the concepts page says a partial resume yields `RunError`; the 1.0 pattern page makes coverage the *consumer's* rule.)

**Notation.** `MUST`/`SHOULD` are the spec's own strength. Priorities: **P0** wire-breaking or aborts valid streams; **P1** violates a MUST; **P2** SHOULD or polish; **P3** optional or deferred. Page references are relative to `docs/spec/1.0/`. Items marked *(verify)* come from reading code or a spec summary and need a failing test before anyone acts on them.

---

## A. Covered today

Verified in code unless marked. "WIP" means present in the working tree but not committed.

| # | Area | Evidence |
|---|---|---|
| A1 | **28 of 31 event types** (every 1.0 `EventType` except the three `SUBAGENT_*`): lifecycle, text, tool call, state, activity, reasoning, raw, custom | `Sources/AGUICore/EventType.swift` |
| A2 | **Reasoning replaces thinking**, including `REASONING_ENCRYPTED_VALUE`. Legacy `THINKING_*` wire events are remapped to `REASONING_*` at decode (the translate-don't-drop rule, `basic/versioning`) | `AGUIEventDecoder.swift:114` |
| A3 | **Run outcome**: `.success(pendingToolCallIds:)`, `.interrupt([Interrupt])`, `.cancelled`; absent outcome means success; malformed interrupt outcome fails decode | `RunFinishedOutcome.swift`, `20b36c0` |
| A4 | **Interrupt / ResumeEntry / `RunAgentInput.resume`** (omitted from the wire when nil); builder `resume(_:)` | `20b36c0` |
| A5 | **Activity** snapshot and delta events and `ActivityMessage` | `Events/ActivityEvents/` |
| A6 | **Chunk transformer, state manager and patch applicator, subscribers, tool registry/executor, circuit breaker, SSE parser/transport** | Kotlin-parity work, now on `main` |
| A7 | **Basic stream verifier**: first event, run lifecycle, balanced messages/tool calls/steps, multi-run reset | `EventVerifier.swift` (gaps in B8) |
| A8 | **SDK interrupt flow.** `StatefulAgUiAgent` tracks pending interrupts per thread, `resume(threadId:entries:)`, `InterruptError` (unknown ids, expired interrupts answered with anything but `.cancelled`), `sendMessage` throws while any are pending; `resume` passthrough in `AbstractAgent`/`RunAgentParameters`/`EventStream`. Committed in `205d780`. | `git status`; tests in `StatefulAgUiAgentInterruptTests`, `RunAgentParametersResumeTests` |

---

## B. Implemented, but the spec has shifted under it

### B1. Unknown material aborts instead of surviving (P0)
`basic/processing`: an unrecognized event type, undescribed property, or unrecognized union member **MUST NOT abort the run**; application code **MUST NOT** see it; a malformed *known* field is fatal. Today `AGUIEventDecoder.Configuration.unknownEventStrategy` defaults to `.throwError`, so any event added in 1.1+ kills the stream. Also covers dropping unknown properties and emitting a warning (see C7).
- Tests first: unknown event type mid-stream is dropped and the stream continues; unknown property on a known event is stripped; unknown `outcome.type` follows B2.
- Files: `Decoding/AGUIEventDecoder.swift`, `Decoding/Registry/*`, `EventStream.swift`.
- **Decision for the user:** change the default (breaking for anyone relying on throw) or keep `.throwError` as opt-in and make the SDK layer always pass `.dropUnknown`.

### B2. `RunFinishedOutcome.unknown(type:)` conflicts with "stripped" (P1, decision)
`events/lifecycle`: an unrecognized outcome is unrecognized material, stripped like the rest; stripped optional fields leave the field absent; **absent means success**. We expose `.unknown(type:)` publicly (added in `20b36c0` so unknown outcomes are "never read as success"). The spec's reading is the opposite, and its note says a new terminal state reaches old consumers as success by design.
- Also unresolved: a legacy *string* outcome (such as `"completed"`) is a known field carrying a value the schema rejects, so it is arguably malformed and fatal rather than `.unknown`.
- **Decision:** (a) follow the spec: strip to absent and warn; or (b) keep `.unknown` as a documented, deliberate deviation recorded in a decision record. Recommend (a) unless a consumer needs to see it.

### B3. Content parts changed shape on the wire (P0, breaking)
`basic/run-input`, `schema.json` (`ContentPart`, `PartSource`). Swift's `ImageInputContent` etc. are **flat** (`url`, `data`, `detail`, `mimeType` beside `type`). 1.0 parts carry `source`, a discriminated union: `data` (`value`, required `mimeType`), `url` (`value`, optional `mimeType`), or `file` (`value`, optional `provider`/`mimeType`). Consequences:
- Messages we **send** in the flat shape may be rejected by 1.0 producers; messages we **receive** in the 1.0 shape fail to decode.
- `file` source is new in 1.0; it is opaque: **MUST NOT** be fetched or parsed.
- Every part gains optional `id`; the text part gains `metadata`.
- Type renames (`InputContent`→`ContentPart`, `TextInputContent`→`TextPart`, `PartSource`, `DataSource`, `UrlSource`); the wire `type` values are unchanged. Keep the old names as `typealias`es.
- `binary` is retired: translate it (to a `data`/`url` part by its fields) with a warning rather than drop it. Python marks `BinaryInputContent` deprecated. Audio is **not** retired.
- A consumer that cannot use a part **MUST NOT** fail the run.
- Tests first: round-trip each part kind; decode fixtures from `@ag-ui/encoder`; validate encoded output against `schema.json` (C8); legacy flat/binary input is translated, with a warning.
- Files: `Types/InputContent/*`, `Decoding/InputContentDTO/*`, `Decoding/MessageDTO/UserMessageDTO`, `Encoding/MessageEncoder.swift`, `Examples/` call sites if any. **Semver:** major bump of the 0.x API surface.

### B4. Tool results carry parts (P1)
`events/tool-calls#result-content`: `TOOL_CALL_RESULT.content` and `ToolMessage.content` are a **string or an ordered `[ContentPart]`**. Both are `String` in Swift, so an array result fails to decode. Depends on B3. Also: a result **MUST still answer the call** even if every part was dropped, and flattening for an old peer **MUST warn** and **MUST NOT** insert placeholders. `TOOL_CALL_RESULT` mints its own message and does not reopen the call.

### B5. Silent `as?` casts break "malformed is fatal" (P1)
`basic/processing`: a known field with a schema-rejected value **MUST** fail the run, never be repaired, coerced or ignored. Decoding has ~84 `as?` casts (for example `object["subagentRunId"] as? String`, `jsonObject["url"] as? String`), each of which turns a wrong-typed value into "absent".
- One sweep of the DTO layer: absent → nil, present-but-wrong-type → `EventDecodingError`. Tests per DTO for a wrong-typed optional field.
- Related to the earlier `fix/json-bool-coercion` work; keep that behavior.

### B6. "Absent means absent" for `null` (P1)
`basic/index#absent-means-absent`: producers **MUST** omit empty optionals, never send `null`; a consumer reading an optional set to `null` treats it as omitted. Null *inside* payloads (`state`, `forwardedProps`, patch values, `Metadata` values) is data and **MUST** be preserved. Audit all encoders and decoders for both directions. Also covers `RunAgentInput.state` (`null` ≙ absent ≙ `{}`) and `forwardedProps` (a whole `null` ≙ omitted).

### B7. `RunAgentInput` shape (P1/P2)
`basic/run-input`: `tools` and `context` optional (absent ≙ empty; MAY omit empty), `protocolVersion` field missing (see C2). `state` defaults to `{}` today, which is correct. Activity messages: see B9.

### B8. Stream verifier vs 1.0 lifecycle and patterns (P1)
Read from `EventVerifier.swift`; each needs a failing test first *(verify)*:
- **Late `RUN_ERROR` after `RUN_FINISHED` is admitted** (`events/lifecycle`) and **MUST** be treated as a failed run; today everything after `RUN_FINISHED` throws.
- **`RUN_STARTED` after `RUN_ERROR`** should return to Active; `runError` is never reset, so the next run's events throw.
- **`RUN_ERROR` ends whatever was open**; per-run tracking resets on any new `RUN_STARTED`, not only after `runFinished`.
- **Reasoning rules**: spans matched by `messageId`; no duplicate open span; all closed before `RUN_FINISHED`; message start/content/end discipline; chunk first-carry rules. Currently no reasoning cases at all.
- **Chunk rules** (`basic/patterns/streaming`): first chunk **MUST** carry `messageId` (text/reasoning) or `toolCallId` + `toolCallName`; continuation repeating an opener field with a *different* value is fatal.
- **Closed items may reopen** if the reopening start agrees with the original; **MUST NOT act on tool args before `TOOL_CALL_END`**.
- **Subagent rules** (ownership, nesting, "run MUST NOT finish with an active invocation"): arrive with C1.
- Steps are per-owner once attribution exists.
- Activity delta without a prior snapshot is skipped with a warning, never fatal (`events/activity`).
- The "run is failed" surface: a stream the consumer rejects and a `RUN_ERROR` the producer sent **MUST** stay distinguishable to application code.

### B9. Activity messages must not be sent back (P1)
`basic/run-input`: a consumer **MUST** strip activity messages from `messages` before sending. `MessageEncoder` encodes them and the SDK/client never strips (no activity handling found in `AGUIAgentSDK`/`AGUIClient`). Fix in the input-building path (`RunAgentInputBuilder` / history manager) so every send path is covered. Tests: history with an activity message sends none.

### B10. Resume coverage on the non-stateful path (P1, done for send paths)
`basic/patterns/interrupt-resume`: a consumer **MUST** reject, before sending, a resume list that leaves an interrupt uncovered or resolves an expired one; omission is not abandonment.
- **Decided:** the check is `ResumeValidator.validate(entries:pending:now:)` in AGUICore (with `InterruptError`), used by `StatefulAgUiAgent.resume` and by `AgUiAgent.sendMessage(_:resume:answering:)`. No lower layer tracks interrupts (`AbstractAgent` keeps messages and state but not run outcomes, and hardcodes `threadId`), so the stateless caller supplies `answering:`. Passing `resume` without it fails as unknown ids.
- `HttpAgent`, `AbstractAgent.runAgent(parameters:)`, and `run(input:)` do not validate; the caller owns coverage. Revisit if `AbstractAgent` ever tracks outcomes.
- Still open: a producer-side mismatch (unrecognized entry id) is a warning, not a failure, per the spec; we throw for unknown ids on the consumer side. After `.cancelled` the next run is a normal new run, not a resume.

### B11. Cancelled outcome surface (P2)
`events/lifecycle#cancelled-runs`: a consumer **MUST NOT** present a cancelled run as success **or** as an error. Audit `AgentSubscriber`, `StateManager`, `ChatAgent`/view-model, and `ConversationHistoryManager` for code that treats any non-error `RUN_FINISHED` as success. A consumer abandoning a stream **MUST NOT** synthesize a `RUN_FINISHED`.

### B12. Message and tool-call fields (P2, needs a schema diff)
Compare every Swift message, `ToolCall`, `Tool`, `Context`, event, and the existing `ResumeEntry`/`Interrupt` against `schema.json` field by field (C8 automates it). Known candidates: `metadata` on messages and events (C4); `Attributable.subagentRunId` on messages and interrupts (C1); `encryptedValue` placement (`ToolMessage`, `ToolCall`, `ReasoningMessage`; `DeveloperMessage` currently has one); `ToolMessage.error` stays alongside content; `TextMessageRole`. Interrupt `reason` and `responseSchema` (object only) per schema.

### B13. Transport (P2)
`basic/transports/http-sse`: LF framing, ignore SSE fields other than `data`, tolerate comment lines, never infer success from a closed connection, no resumption. `SseParser` also accepts CR/CRLF (permitted for consumers). Confirm the other behaviors with tests; check the `HttpAgent` error path rejects bad input "before `RUN_STARTED`" through the transport error.

---

## C. Not started

### C1. Subagents (P0 for decode, P1 for rules)
`events/subagents`, `schema.json` (`SubagentStarted/Finished/ErrorEvent`, `SubagentInfo`, `SubagentFinishedOutcome`, `Attributable`).
- New events: `SUBAGENT_STARTED` (`subagentRunId`, `name`, optional `description`, `parentSubagentRunId`, `parentToolCallId`, `parentMessageId`), `SUBAGENT_FINISHED` (optional `result`; `outcome`: `success` | `suspended` with optional `interruptIds`), `SUBAGENT_ERROR` (`message`, optional `code`). A new event touches `EventType`, `Events/`, `Decoding/EventDTO/`, and `Decoding/Registry/` (AGENTS.md).
- Attribution: optional `subagentRunId` on content/progress events, message types, and `Interrupt` (already present there). Run-scoped events (`RUN_*`, `MESSAGES_SNAPSHOT`) never carry it. It **MUST NOT** be `null`.
- Verifier: announce-before-use, no duplicate active id, no id reuse after finish within a run, every announced invocation closed before `RUN_FINISHED`, `RUN_ERROR` abandons all, continuation tag must agree with its opener, parent must be an active invocation, parallel interleaving without cross-closing, unattributed streams accepted.
- Chunk continuations are ambiguous without attribution; a chunk stream **MUST NOT** outlive its owner.
- Consumers: subagent state updates apply to the run's single state (no private state). Add `AgentSubscriber` hooks and `StateManager` handling; usage rolls up to the run (C3).
- **Decision:** public API shape for observing subagents (subscriber hooks vs an event-only surface).

### C2. Protocol version negotiation (P0)
`basic/versioning#version-negotiation`, `basic/run-input#protocolversion`.
- `RunAgentInput.protocolVersion: String?` and `RunStartedEvent.protocolVersion: String?`. A 1.0 consumer **MUST** send `"1.0"` (omit only when the peer is known to predate the field). The format is `MAJOR.MINOR`, compared numerically per component (`1.10` > `1.9`).
- A consumer meeting a newer or uninterpretable producer version proceeds and **SHOULD** warn.
- A configuration switch to omit the field for known-old servers. Keep the default on.
- Tests: encode includes it; decode of `RUN_STARTED` with and without it; numeric comparison; warning on a newer version.

### C3. Token usage (P1)
`events/lifecycle#token-usage`, `TokenUsage` in the schema. `RUN_FINISHED.usage` and `RUN_ERROR.usage`: array of `TokenUsage` (`provider`, `model`, `inputTokens`, `outputTokens`, `totalTokens`, `cachedInputTokens`, `cacheWriteInputTokens`, `reasoningTokens`); counts are non-negative integers within JS safe-integer range; an absent count is **not** zero. The consumer sums totals; do not add parts to totals.

### C4. Metadata and merge semantics (P1)
`basic/metadata`, `basic/index#metadata`. Optional `metadata` object on events, messages, tool calls, tools, interrupts and resume entries; never `null` when present; open by key (values may be `null`); key `ag-ui` reserved. A consumer **MUST** merge accumulated metadata per key, last write wins, no recursion, per the "where each event's metadata lands" table. Store as raw `Data` or `JSONValue` per AGENTS.md.

### C5. Frontend tool round-trip and `ClientToolResponseHandler` (P1)
`events/tool-calls#frontend-tools` and the known gap in AGENTS.md. A run that stops on a frontend tool call finishes as success (never interrupt) and may list unanswered calls in `pendingToolCallIds`; the continuing thread **MUST** answer every one. `ClientToolResponseHandler` should send the **full history** and a **fresh `runId`**, and pass the agent's reply through rather than discard it. Tests with `MockHTTPClient`/`MockToolRegistry`.

### C6. Agent capabilities (P2/P3)
`basic/capabilities`, `AgentCapabilities` and its group types in the schema. Declarations are informative, omitted means undeclared, retrieval is left to the implementation, and a consumer **MUST NOT** reject a stream because of one. Add the value types (all optional, open `custom`) and defer any retrieval API.

### C7. Processing pipeline and warnings (P0, design)
`basic/processing`. Make the ordering explicit and testable on every path that produces events: **middleware (retired-shape translation) → expansion of chunks → enforcement (drop unknown, strip unknown members, fail on malformed) → verification → application code**. Both transports must reach the same verdict. Needs a warning channel: there is no logging framework (AGENTS.md), and warnings **MUST NOT** be silenced by default (`basic/versioning`). **Decision:** a warning callback/`AsyncStream` on the client configuration versus adopting a logger; this is a separate decision per AGENTS.md. Retired shapes (`THINKING_*`, binary content, the `subAgents` capability key, which is *not* read) go in a registry with their replacements.

### C8. Conformance harness (P0, first)
AGENTS.md already requires checking against the reference SDK. Make it mechanical:
- Vendor `1.0/schema.json` (pinned to the upstream SHA above) under `Tests/.../Fixtures/`.
- Fixtures of events and inputs produced by `@ag-ui/encoder`, decoded in tests.
- Validate what the package **sends** (`RunAgentInput` incl. messages and content parts) against the schema. The package takes no JSON Schema dependency (only `swift-docc-plugin`), so run validation from a script under `scripts/` plus a CI step, or keep a small in-test checker. **Decision.**
- A field-level diff of Swift types against the schema that drives B12.

### C9. Optional: HTTP + Protobuf binding (P3)
`basic/transports/http-protobuf`: negotiated by media type, 4-byte length-prefixed frames, same verdicts as JSON. Needs a protobuf dependency, so it needs a decision record first. Not required for 1.0 conformance of an SSE client *(verify the "all implementations MUST" scope in `basic/index`)*.

### C10. Docs and housekeeping (P2)
- State the supported spec version (1.0) in `README.md` and `ARCHITECTURE.md`; migration notes for B3 and B2.
- `AGENTS.md` "Known gaps" after each phase; keep `IMPLEMENTATION_PLAN.md` references in `AGENTS.md` pointing at `plans/`.
- Working tree hygiene (not part of this plan's code): the tree currently shows large uncommitted deletions (`Examples/ChatApp/`, `plans/*.md`, article drafts) alongside the interrupt WIP. Split commits so the interrupt work and the deletions are separate.

---

## Phases

Every phase is test-first on a feature branch from an up-to-date `main`, with `swift build` and `swift test` green before each commit (AGENTS.md). Doc comments on all new public API.

| Phase | Contents | Why this order |
|---|---|---|
| **0. Baseline** | C8 harness; B12 schema diff. Output: a list of confirmed divergences replacing every *(verify)* above. | Everything else is judged against it. |
| **1. Wire safety (P0)** | B1 + C7 (pipeline and warnings), C2 (`protocolVersion`), B3 (content parts), B5, B6, B7 | These make the client talk to and survive a 1.0 producer. B3 is the breaking one. |
| **2. Subagents** | C1 (events, attribution, verifier rules, subscriber) | Large, but isolated; needs B8's verifier restructure first. |
| **3. Verifier and lifecycle** | B8 (late `RUN_ERROR`, error recovery, reasoning, chunk rules), B11 | Uses the Phase 0 failing tests. |
| **4. SDK flows** | B9, C5, B2 resolution | Application-facing behavior. |
| **5. Additive fields** | B4 (tool result parts), C3 (usage), C4 (metadata), C6 (capabilities types) | Safe additions; no one is blocked on them. |
| **6. Optional** | C9 (protobuf), B13 extras | Deferred. |

## Decisions needed from you

1. **B1:** change the default for unknown events, or keep `.throwError` opt-in and force the SDK layer to tolerate?
2. **B2:** follow the spec (strip unknown outcomes to absent, warn) or keep `.unknown(type:)` as a recorded deviation? Legacy string outcomes: fatal or unknown?
3. **B3:** accept a breaking release for the content-part wire change?
4. ~~**B10:** where does resume coverage live?~~ Resolved: `ResumeValidator` in AGUICore; `AgUiAgent` takes `answering:` (see B10).
5. **C7:** warning mechanism (callback/stream on config, or add a logger as its own decision).
6. **C8:** schema validation via script and CI, or an in-test checker.
7. **C1:** shape of the subagent observation API.
8. **C9:** is protobuf in scope for 1.x of this package at all?

## Watch list (not planned)

- Draft 1.1 (`docs/spec/draft`): empty changelog at the snapshot. Recheck.
- `MetaEvent` (`metaType`, `payload`) appears on the `docs.ag-ui.com` events page as a draft event but is **not** in the 1.0 `EventType` enum; do not implement until it lands in the spec.
- The reference SDKs' generated types (`@ag-ui/core`, `src/generated/`) are the practical cross-check for any field that the schema description leaves ambiguous.
