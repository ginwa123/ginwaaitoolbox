# Agent Error Card — Dedicated Component for Agentic-Loop Error Messages

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render agentic-loop error/retry diagnostics (e.g. `[Retry 1/10] StreamInterrupted … Server said: …`) in a dedicated red-tinted collapsible error card instead of as a plain user-style chat bubble.

**Architecture:** The backend already emits these diagnostics ONLY over SSE (`is_skip_db = true` — never persisted). We thread an explicit `is_error` boolean flag from the 3 diagnostic sites in `workflow.zig` through `insertLLMHistories` → `onEventSendLLMHistory` → the `llm_full` SSE JSON payload. The frontend's `ChatView` intercepts `full` events carrying `is_error: true`, routes them into a separate reactive list, and renders them with a NEW `AgentErrorCard.vue` component — they never enter `messages.value`, so they can't be mistaken for real chat turns.

**Tech Stack:** Zig backend (workflow.zig, insert_llm_histories.zig, sse_on_event_send_llm_history.zig) + Vue 3 / TypeScript frontend (api/index.ts, ChatView.vue, new AgentErrorCard.vue).

## Global Constraints

- **No migration, no schema change.** All 3 diagnostic sites already pass `.is_skip_db = true` (locked by existing test `"all three diagnostic sites keep is_skip_db=true"` in workflow.zig). These messages are live-only; a page refresh clears them. That behavior stays.
- **No new SSE event_type name.** We reuse `llm_full` and add a FIELD to its JSON payload. The "add event names in pairs" rule does NOT trigger because the event name is unchanged — verify this stays true (do not introduce `llm_error`).
- **Tests live INLINE with impl** (user convention, PR #316 review): `test "..."` blocks at the bottom of the same .zig file. For self-grepping static-contract tests, read source via `std.Io.Dir.cwd().readFileAlloc(...)` and expect grep-string counts to include the test's own literals.
- **Never kill port 8081.** Functional testing uses the pytest harness (ports 8080–8199) if needed; this plan should be verifiable with unit/static tests alone since no HTTP route changes.
- Zig 0.16: single-init `var` must be `const`; SQLite argv is string-typed only.
- Arena-owned strings in the workflow loop: never manually free detail slices.

## Background — Current Wire Path (verified 2026-08-25)

```
workflow.zig saveRetryAttemptMessage (:1400)
  └─ insertLLMHistories({ .role = agent.Role.user.to_str(),      ← WHY IT LOOKS LIKE A CHAT MESSAGE
                          .finish_reason = "null",
                          .is_skip_db = true,
                          .is_emit_sse = true })
       └─ onEventSendLLMHistory → SseEventLLMHistory JSON
            └─ event_type "llm_full" on bus "llm"
                 └─ api/index.ts dispatch (eventType === 'llm_full' → channels.llm.onEvent)
                      └─ ChatView.vue offLlm handler (:2254)
                           └─ event.type === 'full' branch (:2326) pushes into messages.value
                                └─ rendered as a normal user bubble
```

The 3 backend emit sites (all inside workflow.zig):
1. `saveRetryAttemptMessage` (:1400) — called from the retry-catch (~:1041) and the unexpected-finish_reason path (~:1242).
2. Soft TooManyRetries bail (~:869 area, `.is_skip_db = true`).
3. Hard TooManyRetries bail (~:921 area, `.is_skip_db = true`).

Sites 2–3 build their own `insertLLMHistories` calls directly (not via `saveRetryAttemptMessage`) — ALL THREE need the flag.

## File Structure

| File | Change |
|---|---|
| `src/ai_workflow/tui/agentic_loop/sse_on_event_send_llm_history.zig` | Add `is_error: bool = false` to `SseEventLLMHistory`; include in JSON payload. Inline tests. |
| `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig` | Pass `input.is_error` (new field on… actually read from entity) through to `onEventSendLLMHistory`. Inline test. |
| `src/ai_workflow/tui/agentic_loop/llm_history_row.zig` | Add `is_error: bool = false` to the `LLMHistory` entity struct (the carrier between workflow → insert → SSE). |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | Set `.is_error = true` at all 3 diagnostic sites. Static-contract inline tests. |
| `src/apps/desktop/src/api/index.ts` | Add `is_error?: boolean` to `SseEvent` interface. |
| `src/apps/desktop/src/components/chat/AgentErrorCard.vue` | NEW — the dedicated error component. |
| `src/apps/desktop/src/__tests__/AgentErrorCard.spec.ts` | NEW — component tests. |
| `src/apps/desktop/src/components/views/ChatView.vue` | Intercept `is_error` full-events → `agentErrors` ref; render `<AgentErrorCard>`; clear on session switch. |

Note: check where `LLMHistory` struct actually lives (`llm_history_row.zig` per the import in insert_llm_histories.zig) before editing — if the struct is shared with DB-row parsing, prefer adding the flag to `InsertLLMHistoriesInput` + `SseEventLLMHistory` only, and threading it as a separate param, to avoid touching DB row mapping. Decide at Task 1 start; the plan below assumes the least-invasive variant: **flag lives on `InsertLLMHistoriesInput` and `SseEventLLMHistory`, NOT on the DB entity** — workflow.zig passes `.is_error = true` as an input field, insert_llm_histories forwards `obj.is_error` to the SSE payload. This keeps llm_history_row.zig untouched.

---

## Task 1 — Backend: `is_error` flag through the SSE payload

**Files:** `insert_llm_histories.zig`, `sse_on_event_send_llm_history.zig`

- [ ] Write failing test FIRST in `sse_on_event_send_llm_history.zig` (inline, bottom of file, mirroring the existing `captured_llm_event` capture-harness tests): emit with `.is_error = true` and assert the captured JSON contains `"is_error": true`. Add a second assertion case: default (flag unset) serializes as `"is_error": false`.
- [ ] Run `zig build test --summary all` — new tests FAIL (field doesn't exist → compile error counts as fail).
- [ ] Add `is_error: bool = false` to `SseEventLLMHistory` (sse_on_event_send_llm_history.zig:19) and to `InsertLLMHistoriesInput` (insert_llm_histories.zig:14).
- [ ] In `inserLLMHistories` SSE block (~line 198), forward `.is_error = obj.is_error` into the `onEventSendLLMHistory` input; in `onEventSendLLMHistory`, copy it into the payload struct. std.json serializes bools natively — no string conversion needed.
- [ ] Run tests again — PASS.
- [ ] Commit: `feat(sse): thread is_error flag through llm_full payload`

## Task 2 — Backend: set the flag at the 3 diagnostic sites

**Files:** `workflow.zig`

- [ ] Write failing static-contract test (inline in workflow.zig, next to the existing `"all three diagnostic sites keep is_skip_db=true"` test): grep each of the 3 diagnostic windows for `.is_error = true` (expect ≥1 occurrence per window; remember self-grep double-counting — the test literal itself adds occurrences, count accordingly).
- [ ] Run — FAIL.
- [ ] Add `.is_error = true` to:
  - the `insertLLMHistories` call inside `saveRetryAttemptMessage` (~:1440),
  - the soft-bail diagnostic insert (~:869),
  - the hard-bail diagnostic insert (~:921).
- [ ] Run — PASS. Full suite green: `zig build test --summary all`.
- [ ] Commit: `feat(workflow): mark agentic-loop diagnostics as is_error on the wire`

## Task 3 — Frontend: type + AgentErrorCard component

**Files:** `api/index.ts`, NEW `components/chat/AgentErrorCard.vue`, NEW `__tests__/AgentErrorCard.spec.ts`

- [ ] Add `is_error?: boolean` to `SseEvent` (api/index.ts:1362 block) with a comment pointing at sse_on_event_send_llm_history.zig.
- [ ] Write failing component tests (`AgentErrorCard.spec.ts`): renders title "Agent error"; parses `[Retry N/M]` out of content into a retry chip (`data-testid="agent-error-retry"`); splits "Server said:" suffix into a detail section (`data-testid="agent-error-detail"`); collapsed by default, click toggles expansion (`data-testid="agent-error-toggle"`); red-tinted styling consistent with DeleteMemory.vue's error block (`text-red-500` family); `data-testid="agent-error-card"` on root.
- [ ] Run `bun run test:unit -- AgentErrorCard` — FAIL (component missing).
- [ ] Implement `AgentErrorCard.vue`: props `{ content: string }`. Computed: `retryLabel` (regex `\[Retry (\d+/\d+)\]`), `headline` (error name + source, e.g. `StreamInterrupted (callDynamicAgentNew)`), `serverDetail` (text after `Server said:`), `delayMs` (`Retrying in (\d+)ms`). Layout mirrors CompactionCard.vue structure (header row + collapsible body) but with error semantics. Keep it dumb — no store access, no emits beyond none needed.
- [ ] Run tests — PASS.
- [ ] Commit: `feat(ui): AgentErrorCard component for agentic-loop error diagnostics`

## Task 4 — Frontend: ChatView routing

**Files:** `components/views/ChatView.vue`

- [ ] In the `offLlm` handler's `full` branch (~:2326), BEFORE the dedupe/push logic: `if (event.is_error) { push {id, content, ts} onto agentErrors ref; return }` — error events never touch `messages.value`, streaming-content cleanup still applies.
- [ ] Clear `agentErrors` wherever `messages.value` is reset on session switch (same lifecycle as `streamingContent.value = ''` at ~:2246 and in loadChatHistory fresh-load path).
- [ ] Template: render `<AgentErrorCard v-for="err in agentErrors" :key="err.id" :content="err.content" />` AFTER the virtual scroller / at the bottom of the transcript area (they're transient live diagnostics — pinning them below the scroll region avoids VirtualScroller estimated-height desync; do NOT put them inside the scroller slot).
- [ ] Unit test (new spec or extend an existing ChatView spec if one covers the SSE handler): dispatching a `full` event with `is_error: true` does NOT add to messages and DOES surface the card; a normal `full` event is unaffected.
- [ ] Run `bun run test:unit` + `bun run type-check` (CI covers src/__tests__ — must be the project script, see macOS-runner memory).
- [ ] Commit: `feat(chatview): route is_error SSE events to AgentErrorCard`

## Task 5 — Verification & wrap-up

- [ ] `zig build test --summary all` — 0 fail, 0 leak.
- [ ] `cd src/apps/desktop && bun run test:unit && bun run type-check` — green.
- [ ] Manual smoke (optional, harness on port ≠ 8081): trigger a retry against a bad base_url profile and confirm the card renders with retry chip + server detail, and disappears on refresh (is_skip_db semantics preserved).
- [ ] Update kanban: milestone comment; move to `in_review_task` when done (human reviews; `merged` is human-only).

## Pitfalls

- **Self-grep double counting** in workflow.zig static tests — the test's own string literals match the grep. Count expected occurrences including the test body (see convention-tests-inline-with-impl memory).
- **Don't add a new SSE event name** — reusing `llm_full` avoids the 3-site event-name pairing dance entirely. If someone proposes `event_type = "llm_error"`, stop: that requires backend emitter + additionalEventTypes + dispatch chain all in lockstep.
- **VirtualScroller height estimates** — anything rendered inside the scroller slot must participate in the estimate model; that's why error cards render OUTSIDE it.
- **`logger.?` deref** in onEventSendLLMHistory tests — always pass a real `Logger.init(...)`, mirroring existing tests.
- **Zig 0.16**: `std.Io.Dir.cwd().readFileAlloc(testing.io, path, max)` signature for source-grepping tests; no `std.process.getEnvVarOwned`.

## Verification

- [ ] Plan saved to docs/superpowers/plans/
- [ ] Header complete
- [ ] Tasks are bite-sized with test-first steps
- [ ] User reviews before execution
