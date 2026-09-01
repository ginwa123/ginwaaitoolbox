# Fix `spawn_sub_agent` shows "0 sub-agents" while sub-agents are running

**Goal:** When the LLM calls `spawn_sub_agent` with N sub-agents, the chatview card must show N rows in `running` state immediately — not "0 sub-agents" until all N finish. The current live-progress system (subagent_progress.zig + ChatView.vue + SpawnSubAgent.vue) was built to fix this but still shows 0 due to two wire mismatches.

**Branch:** `fix/spawn-sub-agent-zero-display`
**Task:** spawn sub agent bugs — show 0 while in process

---

## Background — What Already Exists

| Layer | File | State |
|-------|------|-------|
| `subagent_progress.zig` builds `role="subagent_progress"` JSON and emits on `llm` bus | `src/ai_workflow/tui/agentic_loop/subagent_progress.zig` | ✅ exists, 3 emit sites in `tools_exec_spawn_sub_agent.zig` (launched/completed/failed) |
| `tools_exec_spawn_sub_agent.zig` threads `tool_call_id` + `total_agents` through `SubAgentThreadArgs` | `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig:43,516` | ✅ exists |
| `ChatView.vue` routes `role="subagent_progress"` into `subAgentProgressMap: Record<tool_call_id, SubAgentProgress[]>` | `src/apps/desktop/src/components/views/ChatView.vue:2077` | ✅ exists |
| `SpawnSubAgent.vue` renders `progress` prop when `agents.length==0` (inLiveMode) | `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue:145` | ✅ exists |
| `handle_tool.zig` inserts placeholder rows BEFORE dispatch (Phase 1) | `src/ai_workflow/tui/agentic_loop/handle_tool.zig:378` | ✅ exists, but `is_emit_sse=false` |
| `handle_tool.zig` updates placeholder IN PLACE and emits SSE via `sendSSEForMessageById` | `src/ai_workflow/tui/agentic_loop/handle_tool.zig:730` | ✅ exists, but `tool_call_id = msg.id` (row id) |

---

## Root Cause Analysis

### Bug 1 — Key mismatch: progress map key ≠ message lookup key

- **Progress events** are keyed by `tool_call.id` (the LLM's original id, e.g. `call_abc123`). This is `ctx.tool_call_id` threaded from `handle_tool.dispatchFromRegistry` → `ToolExecContext.tool_call_id` → `SubAgentThreadArgs.tool_call_id` → `emitProgressEvent(.tool_call_id = ...)`.
- **Frontend lookup** is `subAgentProgressMap[msg.tool_call_id]` where `msg.tool_call_id` comes from the SSE `tool_call_id` field.
- **SSE `tool_call_id` is the DB row id** (`msg.id`, the nanosecond `created_at`), NOT the original `tool_call.id`. See `handle_tool.zig:795`:
  ```zig
  .tool_call_id = msg.id, // ROW ID, not column value
  ```
  The DB column `tool_call_id` holds the original id (`call_abc123`), but the SSE wire overwrites it with the row id (`1787...`). REST (`get_llm_histories`) returns the column value (original id); SSE returns the row id. They disagree.
- **Result:** `subAgentProgressMap["call_abc123"]` exists, but `msg.tool_call_id` is `"1787..."` → lookup returns `null` → `inLiveMode = false` → `agentCount = 0` → "0 sub-agents".

### Bug 2 — Placeholder never reaches the frontend during execution

- Phase 1 inserts the placeholder with `is_emit_sse=false` (no SSE). The placeholder only becomes visible after Phase 3's `updateAndSendToolResult` emits the final `<results>` envelope.
- `spawn_sub_agent` runs for minutes (N parallel sub-agents). During that window, the frontend has **no tool message** for this `tool_call_id`, so there is **no `<SpawnSubAgent>` component instance** to render progress into — even if Bug 1 were fixed, the progress map has nowhere to display.
- The assistant message's `tool_calls_json` is emitted (via `sendSSEForLatestMessage`), but `groupToolNames` only shows a "TOOLS: spawn_sub_agent" pill, not the card.

### Bug 3 — Timing: progress events can arrive before the placeholder

- `runSubAgent` emits `launched` immediately after `session_id` is allocated (line 207). If the placeholder SSE were added, it would still race: progress `launched` could arrive before the placeholder's SSE. The reducer (`applyProgressEvent`) creates rows on demand (`while (next.length <= index) push`), so it handles out-of-order, but the component must exist to render them.

---

## File Map

### EDIT (5 files)

| File | Change |
|------|--------|
| `src/ai_workflow/tui/agentic_loop/handle_tool.zig` | Emit placeholder SSE immediately after Phase 1 insert; fix `sendSSEForMessageById` to send BOTH `tool_call_id` (original) and `id` (row id) OR change wire to original id |
| `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` | Ensure `tool_call_id` threaded correctly; optionally also thread `placeholder_id` (row id) so progress can be keyed by both |
| `src/ai_workflow/tui/agentic_loop/subagent_progress.zig` | Add `placeholder_id` field to `ProgressEventInput` and wire JSON (optional, for dual-key lookup) |
| `src/apps/desktop/src/components/views/ChatView.vue` | Fix progress lookup to handle both keys; ensure placeholder message is rendered immediately |
| `src/apps/desktop/src/helpers/subagentProgress.ts` | Support dual-key map or fallback lookup |

### NEW (1 file)

| File | Purpose |
|------|---------|
| `src/apps/desktop/src/components/views/__tests__/ChatView.spawn-sub-agent-live.spec.ts` | Regression: placeholder + progress key match |

---

## Procedure

### Task 1 — Fix the wire mismatch (backend)

**Option A (recommended): Make SSE `tool_call_id` be the original id, keep `id` as row id**

- In `handle_tool.zig:sendSSEForMessageById`, change:
  ```zig
  .tool_call_id = msg.tool_call_id, // original LLM id, not msg.id
  ```
  Keep `msg.id` as the SSE `id` field (already there). Frontend's `Message.id` is already `event.id`, and `toolExpandKey` prefers `msg.id` over `msg.tool_call_id`, so expand-state is unaffected.
- Verify REST and SSE now agree: both return original `tool_call_id`. Dedupe in `ChatView.vue:2181` will now correctly match `m.tool_call_id === event.tool_call_id`.

**Option B (alternative): Dual-key — send both**

- Keep `tool_call_id = msg.id` for backward compat, add new field `original_tool_call_id = msg.tool_call_id` to `SseEventLLMHistory`.
- Frontend lookup tries `subAgentProgressMap[msg.tool_call_id] ?? subAgentProgressMap[msg.original_tool_call_id]`.
- More code, but zero risk to existing expand-state/dedupe.

**Pick one.** Option A is cleaner (single source of truth). Option B is safer if other code depends on row-id wire.

- [ ] Read `src/ai_workflow/tui/agentic_loop/handle_tool.zig:740-813` and `src/ai_workflow/tui/agentic_loop/on_event_sent.zig:42-96` to confirm `SseEventLLMHistory.tool_call_id` semantics.
- [ ] Change `sendSSEForMessageById` to use `msg.tool_call_id` (original) instead of `msg.id`.
- [ ] Update `sendSSEForLatestMessage` similarly if it also affects tool messages (it currently uses `msg.id` for tool_call_id too — check if that path is used for tool results).
- [ ] Add static-contract test in `handle_tool.zig` that greps for `tool_call_id = msg.tool_call_id` and fails if `tool_call_id = msg.id` reappears.

### Task 2 — Emit placeholder SSE immediately

- In `handle_tool.zig` Phase 1 loop (after `insertLLMHistories`), call `sendSSEForMessageById` for the newly inserted placeholder id. This gives the frontend a tool message with empty `<data></data>` immediately, so `<SpawnSubAgent>` mounts and can show live progress.
- The placeholder content is `wrapToolOutput(..., true, null, "")` — `SpawnSubAgent.vue` will parse `agents.length==0` and, with `progress` now non-null (after Bug 1 fix), enter `inLiveMode` and render N running rows.
- Ensure the placeholder SSE uses the same `tool_call_id` (original id) so the progress map lookup matches.

- [ ] In `handle_tool.zig:551` (after `list_id_that_was_loaded.append`), add:
  ```zig
  try sendSSEForMessageById(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, false, true, id_llm_history);
  ```
- [ ] Verify the placeholder's `response_content` is the empty-data envelope (not the final `<results>`), so `agents.length==0` and `inLiveMode` triggers.
- [ ] Test: placeholder SSE arrives before any `launched` progress event; progress still renders (reducer creates rows on demand).

### Task 3 — Frontend: make progress lookup resilient

- In `ChatView.vue:3006`, change:
  ```vue
  :progress="msg.tool_call_id ? subAgentProgressMap[msg.tool_call_id] : null"
  ```
  to handle both keys if Option B is chosen, or just ensure it uses the now-correct original id if Option A is chosen.
- If Option A, no frontend change needed beyond verifying the lookup now matches.
- If Option B, change to:
  ```ts
  const progressForMsg = (msg: Message) => {
    if (!msg.tool_call_id) return null
    return subAgentProgressMap[msg.tool_call_id] 
        ?? subAgentProgressMap[msg.original_tool_call_id ?? ''] 
        ?? null
  }
  ```
- Also ensure `subAgentProgressMap` is not cleared prematurely: `clearProgressFor` is called when the final tool result lands (`ChatView.vue:2268`). With placeholder SSE, the final result is an UPDATE to the same row id, so the clear should still trigger on `event.tool_name === 'spawn_sub_agent'`.

- [ ] Update `ChatView.vue` progress prop binding.
- [ ] Update `subagentProgress.ts` `applyProgressEvent` to handle `placeholder_id` if dual-key is used.
- [ ] Add frontend unit test: simulate placeholder SSE + 3 `launched` events + check `SpawnSubAgent` shows "3 sub-agents, 3 running".

### Task 4 — Handle progress-before-placeholder race

- Even with placeholder SSE, `launched` events may arrive before the placeholder message is processed (network reorder). The reducer already handles this (`while (next.length <= index) push`), but the component won't exist until the placeholder arrives.
- Solution: buffer progress events in `subAgentProgressMap` even when no matching message exists yet. When the placeholder later arrives, the component will immediately read the buffered progress.
- This is already the current behavior: `subAgentProgressMap` is a global ref, not tied to message existence. The only missing piece was the placeholder SSE — once it arrives, the buffered progress becomes visible.

- [ ] Verify by manual test: add artificial delay to placeholder SSE, emit progress first, confirm card shows correct count after placeholder arrives.

### Task 5 — Tests & verification

**Backend unit:**
- [ ] `zig build test --summary all` — existing 3003 tests still pass; new static-contract tests for `tool_call_id` wire.
- [ ] Add test in `handle_tool.zig` that asserts `sendSSEForMessageById` uses `msg.tool_call_id` not `msg.id`.

**Frontend unit:**
- [ ] `pnpm test:unit` — existing 2820 tests still pass.
- [ ] New test `ChatView.spawn-sub-agent-live.spec.ts`: mock SSE bus, emit placeholder + progress events, assert `SpawnSubAgent` renders "N sub-agents" with running/done/failed counts.

**Functional (harness, NOT live 8081):**
- [ ] Write `tests/functional/spawn_sub_agent_live_test.py` that boots nalar on isolated HOME + free port, creates a session, mocks LLM to return `spawn_sub_agent` with 2 sub-agents, asserts:
  1. Placeholder tool message appears via SSE with `tool_call_id` == original id.
  2. `role="subagent_progress"` events arrive with `status=launched` and `total_agents=2`.
  3. Final `<results>` envelope arrives and `subAgentProgressMap` is cleared.

**Manual smoke:**
- [ ] Run `zig build nalar-desktop`, open chat, trigger `spawn_sub_agent` with 3 trivial agents, verify card shows "3 sub-agents, 3 running" immediately, then transitions to "✓ 3" on completion.

---

## Pitfalls

- **Don't break expand-state:** `toolExpandKey` uses `msg.id || msg.tool_call_id`. Changing SSE `tool_call_id` to original id is safe because `msg.id` (row id) is still preferred. Verify no code does `msg.tool_call_id === msg.id` comparison.
- **Don't break dedupe:** `ChatView.vue:2181` dedupes on `tool_call_id`. After fix, REST and SSE will agree (both original id), so dedupe will actually work better (previously it never matched for tool messages).
- **Placeholder SSE must not duplicate:** The final `updateAndSendToolResult` also emits SSE for the same row id. The frontend dedupe (`dup` check at line 2181) should handle the duplicate (same `id`, same `tool_call_id`, same `content` after update? No, content differs: placeholder has empty data, final has `<results>`. So dedupe will NOT collapse them — the placeholder will be replaced by the final message via `messages.value.push` with same `id`? Actually `messages.value.push` adds a new entry; the old placeholder remains. Need to ensure the final update REPLACES the placeholder in `messages`, not appends a duplicate. Check `ChatView.vue:2203` — it pushes a new message for every `full` event, deduping only on `role+tool_call_id+content`. Placeholder and final have different content, so they would be treated as distinct messages → duplicate card. Fix: make the final SSE update the existing placeholder message in place (find by `id` and replace `content`), or make dedupe also check `id`.
- **Progress map memory leak:** `clearProgressFor` deletes the entry when final result lands. Ensure it uses the same key as `applyProgressEvent` (original id). If dual-key, clear both.

---

## Verification

- `zig build test --summary all`: 0 fail, 0 leak
- `pnpm test:unit`: 0 fail
- `pytest tests/functional/spawn_sub_agent_live_test.py -v`: 3/3 pass
- Manual: spawn 3 sub-agents, see "3 sub-agents, 3 running" within 100ms of LLM tool call, not "0 sub-agents"

---

## Out of Scope

- Changing the `spawn_sub_agent` tool's input schema or `SubAgentThreadArgs` structure beyond `tool_call_id` threading.
- Adding a new SSE `event_type` (the fix reuses `llm_full` with `role="subagent_progress"` per existing contract).
- Persisting progress to DB (progress remains ephemeral, final `<results>` is source of truth).
