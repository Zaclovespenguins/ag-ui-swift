# B12 Schema Diff: Swift types vs AG-UI 1.0 `schema.json`

Source: `docs/spec/1.0/schema.json` from https://github.com/ag-ui-protocol/ag-ui, fetched from `main` at upstream commit `85a427d0558d0b117191690bad287da299acc91d` (2026-10-21). The file was not vendored; C8 owns the harness.

Method: every `$defs` entry for messages, `ToolCall`/`FunctionCall`, `Tool`, `Context`, events, `Interrupt`, `ResumeEntry`, and `RunAgentInput` was compared field by field with the Swift model, its decoder/DTO, and (for messages) `MessageEncoder`. Only confirmed divergences are listed. The schema uses `unevaluatedProperties: false`, so an extra property on the wire is a violation, not a leniency.

## Fixed in this change

| # | Swift | Schema | Evidence | Fix |
|---|-------|--------|----------|-----|
| 1 | `MessageEncoder` dropped `encryptedValue` for developer, system, user, assistant, and tool messages. The model, DTOs, and `ToolCall` all carry it; only reasoning encoded it. The value was lost on round trip. | `BaseMessage.encryptedValue` (developer, system, assistant, user); `ToolMessage.encryptedValue`; `ReasoningMessage.encryptedValue`; `ToolCall.encryptedValue` | `Sources/AGUICore/Encoding/MessageEncoder.swift` (`encode*Message`) | Encode `encryptedValue` for all five roles when non-nil. |
| 2 | `MessageEncoder` emitted `name` for `ToolMessage`. | `ToolMessage` "stands alone rather than composing BaseMessage, because it carries no name"; `unevaluatedProperties: false` | Schema `$defs/ToolMessage` properties: id, role, content, toolCallId, error, encryptedValue, metadata | Stop encoding `name` for tool messages. The `name` property stays on the Swift type and is still decoded. |
| 3 | `TextMessageStartEvent` decode threw when `role` was absent. | `TextMessageStartEvent.required = [type, messageId]`; `role` is optional | `TextMessageStartEvent.swift` used `decode`, and a test asserted the throw | `decodeIfPresent`, defaulting to `"assistant"`. A wrong-typed `role` still throws. |

`ToolMessage.error` is already encoded and decoded and matches the schema (a string, alongside `content`). No change.

## Deferred: owned by other work

| Item | Swift | Schema | Owner |
|------|-------|--------|-------|
| `metadata` | Missing on every event, every message, and `ToolCall`. Already present on `Tool`, `Interrupt`, and `ResumeEntry` (as `Data?`). | `Metadata` on `BaseEvent`, `BaseMessage`, `ToolMessage`, `ActivityMessage`, `ReasoningMessage`, `ToolCall`, `Tool`, `Interrupt`, `ResumeEntry`, `IdentityCapabilities` | C4 |
| `subagentRunId` | Only on `Interrupt`. Missing on messages. No `SUBAGENT_STARTED`/`FINISHED`/`ERROR` events (`SubagentStartedEvent` etc.) or `SubagentFinishedOutcome`. | `Attributable.subagentRunId` on messages and interrupts; three subagent events | C1 |
| Content-part and tool-result shape | Integrated: `resultContent` represents text or parts on both types; text accessors are optional. | `oneOf [string, array<ContentPart>]` for both | Resolved by B3/B4 |
| Pre-existing test failure | The stale legacy-image assertion was reproduced and updated in baseline commit `fbab061`; both image tests now pass. | AG-UI 1.0 content parts | Resolved during integration |

## Deferred: confirmed, not fixed (not small or not clearly owned)

1. `RunStartedEvent` has no `protocolVersion`; `RunAgentInput` has no `protocolVersion`. Both are optional strings in the schema.
2. `RunFinishedEvent` and `RunErrorEvent` have no `usage` (`array<TokenUsage>`), and there is no `TokenUsage` type.
3. `Tool.parameters` is required on decode, but the schema requires only `name` and `description`. A tool without `parameters` fails to decode. Fixing it needs a decision on the in-memory default.
4. `TextMessageStartEvent.role` and `TextMessageChunkEvent.role` are free-form strings. The schema restricts them to `TextMessageRole` (developer, system, assistant, user), which excludes `tool`. The Swift types accept `"tool"`. Tightening is a source-breaking change to a public `String` property.
5. `ReasoningMessageStartEvent.role` is a free `String`. The schema requires the constant `reasoning`.
6. `AgentCapabilities` and its sub-objects (`IdentityCapabilities`, `ToolsCapabilities`, and so on) are in the schema. A repo-wide search found no Swift model for them. Out of B12's listed scope; flag for the C8 harness.

## Checked and matching (no action)

- `Interrupt`: `id` and `reason` required; `message`, `toolCallId`, `expiresAt` strings. `reason` is an open string (`InterruptReason`), matching "an open string rather than an enumeration".
- `ResumeEntry`: `interruptId`, `status` (`resolved` or `cancelled`), `payload`, `metadata`.
- `ToolCall` (`id`, `type: "function"`, `function`, `encryptedValue`), `FunctionCall` (`name`, `arguments` as a string), `Context` (`description`, `value`).
- Event field names and required sets for text message, tool call, state, activity, step, raw, custom, reasoning (including `REASONING_ENCRYPTED_VALUE` and its subtype), and `RunFinishedOutcome` (success with `pendingToolCallIds`, interrupt, cancelled).
- Lenient but not conflicting: `SystemMessage.content` and `ToolMessage.content` are accepted when absent (schema requires them); `Interrupt.responseSchema` accepts any JSON on decode (schema: object). These affect only invalid input, so they are not listed as divergences. `Interrupt` is not encoded by this package.
