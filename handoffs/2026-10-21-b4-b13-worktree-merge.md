# Handoff: B4–B13 worktrees, baseline test failure, merge plan

Date: 2026-10-21. Plan reference: `plans/IMPLEMENTATION_PLAN.md` sections B4–B13.

> Historical planning snapshot. B4–B13 are now committed and integrated; see [the completion report](2026-10-21-b4-b13-integration.md) for current status and validation.

Ten sub-agents (Sonnet 5.5) each implemented one section in its own git worktree under `.claude/worktrees/`. All ten finished. **Nothing is committed or merged.** Every worktree is based on `main` @ `1e792e2` with uncommitted changes, so each needs a commit on its branch before merging.

---

## 1. Baseline test failure

### `AGUICoreTests.UserMessageTests.testDecodingMultimodal`

- **Location:** `Tests/AGUICoreTests/Types/Messages/UserMessageTests.swift:195`
- **Message:** `Second part should be BinaryInputContent`
- **Fails on:** `main` (checked directly from the main checkout, which has no agent changes) and in every worktree that ran the full suite. B12 also confirmed it by stashing its changes.
- **Not caused by any agent.** It is a pre-existing failure that predates B4–B13.

**Root cause (read from the code, not yet fixed or re-run after a fix):**
The test decodes a user message whose second part is the legacy shape `{"type":"binary","mimeType":"image/jpeg","url":"https://example.com/photo.jpg"}` and asserts the result is a `BinaryInputContent`. Since `86549c6 feat: use AG-UI 1.0 content parts on the wire` (B3), `ContentPartCodec.decodeLegacyBinary` translates a retired `binary` part into a 1.0 part chosen by MIME family (`image/jpeg` becomes an image part with a `url` source) and reports `.legacyBinaryTranslated`. The test was never updated and still expects the old type. The decoder behavior is correct per B3 and the plan; the test is stale.

**Suggested fix (test change, not a decoder change):**
Assert that part 2 is the translated image part with a `url` source of `https://example.com/photo.jpg` and MIME type `image/jpeg`, instead of `BinaryInputContent`. Check the sibling test `testDecodingMultimodalWithMultipleParts` for the same assumption, and check any other tests that mention `BinaryInputContent` after decoding.

Fix this on its own small branch off `main` first (`fix/multimodal-decode-test`). Then every later merge can be judged against a green baseline.

### Other baseline observations

- **Possible stale SourceKit errors:** the IDE flagged `InterruptError has no member 'duplicateEntries'` in `ResumeValidatorTests.swift`. That case exists only in B10's worktree. Not confirmed. If it persists after the B10 merge, run `swift build --build-tests` to settle it.
- **Not run by any agent:** `swiftlint`, `xcodebuild` for iOS and macOS.
- **No post-merge run exists.** Each agent validated only its own worktree. No combination of branches has been built or tested.
- **Working tree on `main`:** `.swiftlint.yml` and `plans/OLD_IMPLEMENTATION_PLAN.md` show as deleted and uncommitted. Do not include those deletions in any of these commits (see `plans/IMPLEMENTATION_PLAN.md` C10 on splitting commits).

---

## 2. Worktrees

| Section | Branch | Tests added |
|---|---|---|
| B4 tool result parts | `worktree-agent-a8425b709036913dd` | 24 |
| B5 strict DTO decoding | `worktree-agent-a927a435f4082f05a` | 20 |
| B6 absent means absent | `worktree-agent-a33ddbbdaee65064a` | 26 |
| B7 `RunAgentInput` shape | `worktree-agent-ad78bbb5494f78c12` | 12 |
| B8 verifier rules | `worktree-agent-a776708d25574ca90` | 38 |
| B9 strip activity messages | `worktree-agent-a0a6f96ab24ff8ec6` | 12 |
| B10 resume edge cases | `worktree-agent-a20719384f5cd3b36` | 8 |
| B11 cancelled outcome | `worktree-agent-ab41ca4d3fc18c09a` | 14 |
| B12 schema diff and fixes | `worktree-agent-ac267af0c859b6c16` | 6 |
| B13 SSE transport | `worktree-agent-a59606da522605abc` | 19 |

Path for each: `.claude/worktrees/agent-<id>` (the part of the branch name after `worktree-agent-`).

---

## 3. File overlap between worktrees

Computed from `git status` in each worktree. Only files touched by two or more branches are listed.

| File | Branches |
|---|---|
| `Sources/AGUICore/Types/AgentExecution/RunAgentInput.swift` | B6, B7 |
| `Sources/AGUICore/Types/AgentExecution/RunAgentInputBuilder.swift` | B7, B9 |
| `Sources/AGUICore/Encoding/MessageEncoder.swift` | B4, B12 |
| `Sources/AGUICore/Decoding/MessageDTO/ToolMessageDTO.swift` | B4, B5 |
| `Sources/AGUIClient/AbstractAgent.swift` | B9, B11 |
| `Sources/AGUIClient/Transport/HttpTransport.swift` | B9, B13 |
| `Sources/AGUIAgentSDK/StatefulAgUiAgent.swift` | B4, B11 |

Branches with **no overlap at all:** B8, B10.
B12 overlaps only with B4. B5 overlaps only with B4. B13 overlaps only with B9. B6 overlaps only with B7. B11 overlaps with B9 and B4.

---

## 4. What can merge without much trouble

Commit each branch first. Merge into an up-to-date `main` through a feature branch, per `docs/WORKFLOW.md`. Run `swift build` and `swift test` after every merge.

**Safe (no file overlap, additive):**
- **B8** (`EventVerifier.swift` rewrite plus tests). Isolated to AGUIClient streaming. The rewrite is large, so review the behavior, but there is no merge risk.
- **B10** (adds `InterruptError.duplicateEntries(ids:)` plus tests). Isolated. The new public enum case could break exhaustive switches in code outside this repo.

**Safe once the one overlapping partner is handled (small, mechanical conflicts expected):**
- **B12**: merge before B4. Conflicts only in `MessageEncoder.swift`.
- **B5**: merge before B4. Its edits are single-line substitutions, written that way to limit conflicts. It conflicts only in `ToolMessageDTO.swift`.
- **B13**: merge before B9. It conflicts only in `HttpTransport.swift`.

Suggested order for the safe group: **B8, B10, B13, B12, B5**.

---

## 5. What needs careful review

### B6 and B7: merge together, by hand
Both edit `RunAgentInput.swift`, and B7 also edits `RunAgentInputBuilder.swift` and two assertions in `RunAgentInputTests`.
- **Behavioral conflict, not just a text conflict.** B6 changes encoding so an empty `state` (`{}`) is omitted (it used to encode as `"state": null`). B7's report says it left the empty-state `null` behavior untouched, and its new tests may assert the old behavior. After merging, run `RunAgentInputShapeTests` (B7) and `AbsentMeansAbsentTests` (B6) together and reconcile any state assertions.
- **Open risk:** the old `null` was there for claude-agent-sdk adapters. Omission has not been tried against one.
- **Wire changes to confirm acceptable:** empty `tools` and `context` are no longer sent (MAY in the spec), and `forwardedProps` stays always-encoded as `{}`.
- Decision pending from B6: a bare `null` in `ResumeEntry.payload` currently reads as omitted.

### B9: wire change, three-way overlap
- Overlaps `RunAgentInputBuilder.swift` (B7), `AbstractAgent.swift` (B11), and `HttpTransport.swift` (B13). Merge after B7, B11 and B13 and re-run its tests.
- Design choice to confirm: `RunAgentInput` itself still encodes activity messages. Stripping happens in the builder and the HTTP and abstract-agent send paths. A direct `JSONEncoder().encode(input)` would include them.

### B11: new public API
- Adds `AgentSubscriber.onRunCancelled` (default returns `nil`), `lastRunWasCancelled` on both view models, and changes how `AbstractAgent.runAgent` picks `onRunFinalized`, `onRunFailed` and `onRunCancelled`. Overlaps B9 (`AbstractAgent.swift`) and B4 (`StatefulAgUiAgent.swift`, comment-only on B11's side).
- TDD gap: the red state was seen only as a compile failure, so the behavior tests were not shown failing against the old code.
- Open item: nothing downstream marks a run as failed from a `RunErrorEvent` (B8 deferred it to B11, and B11 did not pick it up).

### B13: behavior change and deleted tests
- Three behavior changes: a stream closed without `RUN_FINISHED` or `RUN_ERROR` now throws `ClientError.streamError`, mid-stream failures are no longer retried, and a non-`text/event-stream` content type is rejected.
- **It deleted three tests** in `SseReconnectionTests` that asserted `Last-Event-ID` on retry. Confirm that is intended before merging.
- 14 of its 19 new tests were not individually seen failing first.
- `HttpAgent.run(_:endpoint:)` still ends quietly on a truncated stream.

### B4: merge last, most invasive
- Public API change: `ToolCallResultEvent.content` changes from `String` to `String?`, and a new `ToolResultContent` enum and `resultContent` property are added on both `ToolMessage` and `ToolCallResultEvent`. Touches 9 existing source files across all three non-tools modules.
- Overlaps B5 (`ToolMessageDTO.swift`), B12 (`MessageEncoder.swift`) and B11 (`StatefulAgUiAgent.swift`). After B5 and B12 are in, expect to re-apply B4's `ToolMessageDTO` and `MessageEncoder` changes on top of theirs, and re-check the B12 rule that `ToolMessage` must not encode `name`.
- Decisions to confirm: text parts joined with `"\n"` when flattened; the flatten API is unused until C2; a non-string, non-array result, or a non-object array item, is fatal.

### Other things reviewers should know
- **B12** changes `TextMessageStartEvent` so a missing `role` defaults to `"assistant"`, and `MessageEncoder` now encodes `encryptedValue` on five message types and omits `name` on `ToolMessage`. Its schema snapshot SHA (`85a427d0558d0b117191690bad287da299acc91d`) differs from the `b959aa6` in the plan baseline.
- **B7** left `RunStartedEvent.protocolVersion`, the `"1.0"` default, the version comparison and the warning to C2.
- **TDD gaps:** B7, B9, B10 and B11 saw the red state only as a compile failure or only partly, so spot-check that their new behavior tests would fail against the old code.

---

## 6. Recommended order

1. Fix the baseline test on its own branch (section 1).
2. **B8, B10** (no overlap).
3. **B13, B12, B5** (single mechanical overlap each).
4. **B6 + B7** together, by hand, then reconcile the `state` encoding.
5. **B11**, then **B9** (resolve the `AbstractAgent.swift`, `HttpTransport.swift` and builder overlaps).
6. **B4** last.
7. After each step run `swift build` and `swift test`. After step 6 run the whole suite once and also `swiftlint` and an iOS or macOS `xcodebuild`, which no agent ran.

## 7. Still open (not covered by B4–B13)

- C2 (`protocolVersion` negotiation), C3 (usage), C4 (metadata), C1 (subagents), C6 (capabilities), C7 (warning channel).
- `Tool.parameters` is required on decode, but the schema requires only `name` and `description`. No agent owns this.
- `role` on text-message start and chunk events, and on `ReasoningMessageStartEvent`, is a free string where the schema restricts it. Tightening it would break the public API.
- `plans/IMPLEMENTATION_PLAN.md`: B10's "Still open" bullet can now be marked resolved for duplicates and cancelled. No agent edited the plan.
- Commit message rule: `AGENTS.md` says no AI attribution in commits and conventional commits under 50 characters. The session's commit attribution reminder says to add a co-author trailer. `AGENTS.md` is the project rule, so confirm which applies before committing.
