# AGUISwift: AG-UI 1.0 Conformance Plan

> **Goal**: make the AGUISwift client conform to **AG-UI protocol 1.0**.
> **Supersedes**: `plans/OLD_IMPLEMENTATION_PLAN.md` (April 2026 Kotlin-parity plan). The Kotlin SDK is now an API reference only, not the target.

## Baseline

| Item | Value |
|---|---|
| Spec target | AG-UI **1.0**, frozen: `docs/spec/1.0/` in [ag-ui-protocol/ag-ui](https://github.com/ag-ui-protocol/ag-ui) |
| Upstream snapshot | `main` @ `b959aa6` (2026-10-20) |
| Draft (1.1) | `docs/spec/draft/changelog.mdx` lists no changes yet. Re-check before each release. |
| Repo snapshot | B4–B13 integration through `06faa79`, October 21, 2026; see the integration handoff |
| Validation at snapshot | Integration build, 1,584 tests, iOS simulator build, and representative reference-schema checks passed. Scoped SwiftLint failed; see the handoff for counts and limitations. |

**Sources of truth, in order:** `1.0/schema.json` (structure), the normative pages under `1.0/` (behavior), then `1.0/changelog.mdx` (summary). Upstream *release notes* and the `docs.ag-ui.com/concepts/*` pages are integration changelogs and explainers, not the spec. Where they disagree with `1.0/`, `1.0/` wins. (Example: the concepts page says a partial resume yields `RunError`; the 1.0 pattern page makes coverage the *consumer's* rule.)

**Notation.** `MUST`/`SHOULD` are the spec's own strength. Priorities: **P0** wire-breaking or aborts valid streams; **P1** violates a MUST; **P2** SHOULD or polish; **P3** optional or deferred. Page references are relative to `docs/spec/1.0/`. Items marked *(verify)* come from reading code or a spec summary and need a failing test before anyone acts on them.

---

## A. Covered today

Verified in code unless marked. The baseline and integration work described here are committed.

| # | Area | Evidence |
|---|---|---|
| A1 | **28 of 31 event types** (every 1.0 `EventType` except the three `SUBAGENT_*`): lifecycle, text, tool call, state, activity, reasoning, raw, custom | `Sources/AGUICore/EventType.swift` |
| A2 | **Reasoning replaces thinking**, including `REASONING_ENCRYPTED_VALUE`. Legacy `THINKING_*` wire events are remapped to `REASONING_*` at decode (the translate-don't-drop rule, `basic/versioning`) | `AGUIEventDecoder.swift` |
| A3 | **Run outcome**: `.success(pendingToolCallIds:)`, `.interrupt([Interrupt])`, `.cancelled`; absent outcome means success; malformed interrupt outcome fails decode | `RunFinishedOutcome.swift`, `20b36c0` |
| A4 | **Interrupt / ResumeEntry / `RunAgentInput.resume`** (omitted from the wire when nil); builder `resume(_:)` | `20b36c0` |
| A5 | **Activity** snapshot and delta events and `ActivityMessage` | `Events/ActivityEvents/` |
| A6 | **Chunk transformer, state manager and patch applicator, subscribers, tool registry/executor, circuit breaker, SSE parser/transport** | Kotlin-parity work, now on `main` |
| A7 | **Basic stream verifier**: first event, run lifecycle, balanced messages/tool calls/steps, multi-run reset | `EventVerifier.swift` (gaps in B8) |
| A8 | **SDK interrupt flow.** `StatefulAgUiAgent` tracks pending interrupts per thread, `resume(threadId:entries:)`, `InterruptError` (unknown ids, expired interrupts answered with anything but `.cancelled`), `sendMessage` throws while any are pending; `resume` passthrough in `AbstractAgent`/`RunAgentParameters`/`EventStream`. Committed in `205d780`. | Tests in `StatefulAgUiAgentInterruptTests`, `RunAgentParametersResumeTests` |

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

### B3. Content parts changed shape on the wire (P0, implemented)
`basic/run-input`, `schema.json` (`ContentPart`, `PartSource`). The previous `ImageInputContent` wire shapes were **flat** (`url`, `data`, `detail`, `mimeType` beside `type`). 1.0 parts carry `source`, a discriminated union: `data` (`value`, required `mimeType`), `url` (`value`, optional `mimeType`), or `file` (`value`, optional `provider`/`mimeType`). Current implementation:
- `ContentPart`, `TextPart`, media parts, and `PartSource` implement the nested shape, including opaque file sources and optional IDs/metadata.
- Legacy input-content names remain aliases; flat/binary inputs translate to current parts. Legacy image assertions were corrected during integration.
- See [migration guidance](../docs/COMPATIBILITY.md#content-parts-and-tool-results). Automatic warning routing and broader conformance coverage remain C7/C8.

### B4. Tool results carry parts (P1, integrated)
`ToolResultContent` represents text or ordered content parts on `ToolMessage` and `ToolCallResultEvent`. Empty parts still answer the call. String initializers remain available; `ToolCallResultEvent.content` is now `String?`, and `resultContent` exposes either shape. Flattening joins text with newlines, drops other parts without placeholders, and returns warnings for the caller to surface. Automatic warning routing remains C7.

### B5. Strict optional DTO fields (P1, integrated)
Hand-decoded optional strings, booleans, and string arrays use throwing readers: absence/null reads as nil, while a present wrong type throws. The sweep covers lifecycle, activity, raw-event, user, tool, and reasoning DTO fields. Existing JSON boolean discrimination is retained. This is DTO validation; the stream-wide processing/warning work remains B1/C7.

### B6. "Absent means absent" for `null` (P1, integrated)
Optional fields are omitted on encode and null optionals are treated as absent on decode. Empty `RunAgentInput.state` is omitted, never emitted as null; absent/null state decodes to `{}`. Null values inside state, forwarded properties, metadata, and resume payload objects are preserved. A whole null `ResumeEntry.payload` remains omitted, matching the pinned schema's `not: {type: null}` rule. A live claude-agent-sdk adapter smoke test has not been run.

### B7. `RunAgentInput` shape (P1/P2, integrated)
Empty `tools` and `context` are omitted and decode as empty when absent/null. `protocolVersion` is available on the input and builder and participates in equality/hash. Its default remains nil; version negotiation, the `"1.0"` send default, and `RunStartedEvent.protocolVersion` remain C2. `forwardedProps` still defaults to and encodes `{}`.

### B8. Stream verifier lifecycle and patterns (P1, integrated)
- Late `RUN_ERROR` after `RUN_FINISHED` passes through; `AbstractAgent.runAgent` reports the producer failure as `AgentRunError`, distinct from `AGUIProtocolError` for consumer rejection.
- Any new `RUN_STARTED` resets per-run tracking, including after errors. `RUN_ERROR` ends open items.
- Reasoning spans/messages, first-chunk identifiers, repeated opener fields, and reopening consistency are verified.
- Activity delta without a prior snapshot is skipped and reported through the warning hook.
- Subagent ownership/nesting and per-owner steps remain C1.

### B9. Activity messages are stripped before sending (P1, integrated)
The builder, abstract-agent send path, and HTTP transport strip display-only activity messages while preserving the remaining input fields, including `protocolVersion`. Local history and direct `JSONEncoder` encoding can retain activity messages; every package send boundary strips them. Tests cover raw inputs, builders, SDK history, and transport requests.

### B10. Resume coverage (P1, integrated for send paths)
`ResumeValidator.validate(entries:pending:now:)` rejects uncovered, unknown, duplicate, and expired resolved entries. Expired interrupts can be cancelled. `StatefulAgUiAgent.resume` and `AgUiAgent.sendMessage(_:resume:answering:)` use it; the stateless caller supplies `answering:`.
- Duplicate entries and the normal new run following `.cancelled` are covered and resolved.
- `HttpAgent`, `AbstractAgent.runAgent(parameters:)`, and `run(input:)` still leave interrupt coverage to their caller. The abstract agent records the latest streamed outcome for finalization, not pending interrupts.
- Producer-side unrecognized-entry warnings are separate from consumer-side rejection of unknown ids; producer warning handling remains open.

### B11. Cancelled outcome surface (P2, integrated)
`AgentSubscriber.onRunCancelled` has a default no-op implementation. Producer cancellation, local abort, and transport cancellation do not invoke success/failure finalization. Both view models expose `lastRunWasCancelled` and keep cancellation out of `lastError`; a late producer error supersedes the cancelled flag. No `RUN_FINISHED` is synthesized when a consumer abandons a stream. Producer errors now reach failure subscribers and the `runAgent` caller as `AgentRunError`.

### B12. Message and tool-call fields (P2, schema diff completed)
See [B12_SCHEMA_DIFF.md](B12_SCHEMA_DIFF.md), using upstream schema commit `85a427d0558d0b117191690bad287da299acc91d`. Message encoding preserves `encryptedValue`, omits `ToolMessage.name`, and retains `ToolMessage.error` alongside content. Missing text-start role defaults to assistant. Metadata, attribution, usage, capabilities, `Tool.parameters` defaults, and public role-string tightening remain deferred as listed in the diff.

### B13. HTTP/SSE transport (P2, integrated)
LF/CRLF framing, comments, and data-only dispatch are covered. Mid-stream failures are not retried/resumed; pre-stream connection retries make fresh requests. Both HTTP run entry points reject truncation, including an unfinished final run after replay. A present non-SSE content type is rejected before decoding; a missing header remains tolerated for compatibility. Legacy cursor inspection/explicit header APIs remain available but automatic AG-UI 1.0 streaming does not use `Last-Event-ID`.

Integration details, validation commands, compatibility notes, and remaining limitations are recorded in [the integration handoff](../handoffs/2026-10-21-b4-b13-integration.md).

---

## C. Remaining work and partial implementations

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
- `RunAgentInput.protocolVersion: String?` is implemented; `RunStartedEvent.protocolVersion: String?` remains open. A 1.0 consumer **MUST** send `"1.0"` (omit only when the peer is known to predate the field). The format is `MAJOR.MINOR`, compared numerically per component (`1.10` > `1.9`).
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

### C8. Conformance harness (P0, partially implemented)
`ReferenceSDKWireTests` now decodes encoder 1.0.3 fixtures and exports three requests; `scripts/validate-wire-reference.cjs` validates them against core schemas and the pinned JSON Schema. These representative checks passed during integration. Remaining work:
- Vendor `1.0/schema.json` (pinned to the upstream SHA above) under `Tests/.../Fixtures/`.
- Fixtures of events and inputs produced by `@ag-ui/encoder`, decoded in tests.
- Validate what the package **sends** (`RunAgentInput` incl. messages and content parts) against the schema. The package takes no JSON Schema dependency (only `swift-docc-plugin`), so run validation from a script under `scripts/` plus a CI step, or keep a small in-test checker. **Decision.**
- A field-level diff of Swift types against the schema that drives B12.

### C9. Optional: HTTP + Protobuf binding (P3)
`basic/transports/http-protobuf`: negotiated by media type, 4-byte length-prefixed frames, same verdicts as JSON. Needs a protobuf dependency, so it needs a decision record first. Not required for 1.0 conformance of an SSE client *(verify the "all implementations MUST" scope in `basic/index`)*.

### C10. Docs and housekeeping (P2, documentation refreshed)
- README, architecture, and compatibility/migration documentation now describe the implemented features and remaining gaps.
- Historical handoffs retain their original context. Earlier working-tree deletion and WIP notes describe the pre-integration baseline, not current outstanding work.
- Continue updating this plan and `AGENTS.md` after each implementation phase.

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
3. **B3:** implementation landed; choose release/versioning policy for the content-part API and wire changes.
4. ~~**B10:** where does resume coverage live?~~ Resolved: `ResumeValidator` in AGUICore; `AgUiAgent` takes `answering:` (see B10).
5. **C7:** warning mechanism (callback/stream on config, or add a logger as its own decision).
6. **C8:** schema validation via script and CI, or an in-test checker.
7. **C1:** shape of the subagent observation API.
8. **C9:** is protobuf in scope for 1.x of this package at all?

## Watch list (not planned)

- Draft 1.1 (`docs/spec/draft`): empty changelog at the snapshot. Recheck.
- `MetaEvent` (`metaType`, `payload`) appears on the `docs.ag-ui.com` events page as a draft event but is **not** in the 1.0 `EventType` enum; do not implement until it lands in the spec.
- The reference SDKs' generated types (`@ag-ui/core`, `src/generated/`) are the practical cross-check for any field that the schema description leaves ambiguous.
