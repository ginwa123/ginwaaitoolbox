# Spawn Sub-Agent Live Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chatview's `spawn_sub_agent` tool card show live per-sub-agent progress (running / done / failed counts, per-agent status rows, live peek) while sub-agents are still running, instead of showing "0 sub-agents" until all of them finish.

**Architecture:** The backend's `execSpawnSubAgent` already tracks per-thread state in `SharedResults` (session_id set within ms of launch, `completed_count` atomic) but emits nothing until `group.await()` joins all threads. We add a tiny progress-event emitter called from inside each sub-agent thread at 3 lifecycle points (launched / completed / failed). Events ride the EXISTING `llm_full` SSE channel (no new event_type → no 3-site wire-contract churn) as `role="subagent_progress"` payloads keyed by the parent's `tool_call_id`. The frontend's `SpawnSubAgent.vue` learns to render a live state from these events, and ChatView routes them into a per-tool-call progress map. The final `<results>` XML remains the source of truth on completion — progress events are ephemeral UI sugar.

**Tech Stack:** Zig 0.16 backend (`std.Io.Group`, `onEventSendLLMHistory` SSE emitter), Vue 3 + TypeScript frontend (SSE bus `bus.on('llm')`, existing `SpawnSubAgent.vue` + `useSubAgentPeek.ts`).

## Global Constraints

- **DO NOT kill the port 8081 server.** Functional tests must use the harness (free port 8080–8199).
- **No new SSE event_type.** Adding one requires the 3-site contract (backend emitter map + `additionalEventTypes` + dispatch chain in `api/index.ts`). We deliberately reuse `llm_full` with a new `role` value to avoid that churn. If review prefers a dedicated `subagent_progress` event type, the 3 sites MUST change together (see Pitfalls).
- **No DB schema changes, no migration.** Progress events are ephemeral; the final tool result row is already persisted by `updateAndSendToolResult`.
- **Thread safety:** sub-agent threads run concurrently on `std.Io.Group`. The event bus (`di.event_bus`) is shared; `onEventSendLLMHistory` allocates from its own arena per call and only reads its inputs — safe to call from any thread. All per-thread state lives in the thread's own `SubAgentThreadArgs` slot; the only shared mutation is the existing `completed_count` atomic.
- **Sub-agents cannot spawn sub-agents** (workflow.zig:1604 strips the tool) — progress events only ever come from depth-1 threads, so no recursion concerns.
- **LLM must not see progress events.** They are SSE-only; never write them to `llm_history` (do NOT call `saveMessage` for them).
- **Backward compat:** a frontend that ignores `role="subagent_progress"` events must behave exactly as today (they're filtered out by role checks everywhere else).
- Test commands: `zig build test --summary all` (backend), `cd src/apps/desktop && bun run test` (frontend vitest), `bun run build` (vue-tsc + vite).

## Root-Cause Summary (from investigation)

1. `tools_exec_spawn_sub_agent.zig:381` — `group.await()` blocks until ALL sub-agents finish; the `<results>` XML is built only after that (lines 389–411). Until then the parent's tool placeholder row (`handle_tool.zig:492–527`) has `response_content=""`.
2. The frontend card (`SpawnSubAgent.vue`) parses ONLY the final `<results>` envelope, so mid-run it renders the fallback "spawn_sub_agent 0 sub-agents" (the user's screenshot).
3. Each thread DOES know its `session_id` almost immediately (`tools_exec_spawn_sub_agent.zig:110–123`) and `SharedResults.completed_count` (line 241) ticks on completion — the data exists, it just never reaches the UI.

## File Structure (files to touch)

| File | New/Edit | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/subagent_progress.zig` | NEW | Pure helper: build + emit one progress event (testable without threads) |
| `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` | EDIT | Call emitter at 3 lifecycle points; pass `tool_call_id` through `ToolExecContext` |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | EDIT | Add `tool_call_id: []const u8 = ""` to `ToolExecContext` |
| `src/ai_workflow/tui/agentic_loop/handle_tool.zig` | EDIT | Populate `ctx.tool_call_id` when building `ToolContext` |
| `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent_test.zig` | NEW | Static-contract + unit tests for the emitter |
| `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` | EDIT | Accept live `progress` prop; render per-agent status rows mid-run |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | Route `role="subagent_progress"` SSE events into a per-tool_call_id map; pass to component |
| `src/apps/desktop/src/components/tool_outputs/__tests__/SpawnSubAgent.spec.ts` | EDIT | Tests for live-progress rendering |
| `src/apps/desktop/src/components/views/__tests__/ChatView.subagent-progress.spec.ts` | NEW | Test the SSE → progress-map routing |

---

### Task 1 — Backend: progress event emitter helper (pure, testable)

**Files:** `src/ai_workflow/tui/agentic_loop/subagent_progress.zig` (NEW), `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent_test.zig` (NEW), `src/root.zig` (EDIT — re-export), `src/ai_workflow/tui/test_runner.zig` (EDIT — test discovery, see gotcha in memory: mod.zig re-export alone does NOT make tests discoverable).

- [ ] Write failing test first in `tools_exec_spawn_sub_agent_test.zig`:
  - `buildProgressEventJson renders launched/completed/failed statuses` — call the pure builder for each status and assert the JSON contains `"role":"subagent_progress"`, the parent `tool_call_id`, agent `name`, `status`, `index`, `total`, and `session_id` (when non-empty).
  - `buildProgressEventJson omits session_id field when empty` — failed-before-session-creation path.
  - `buildProgressEventJson sanitizes invalid UTF-8 in agent names` — a name with a raw 0x89 byte must not produce invalid JSON (use the same `helpers.sanitize.sanitizeUtf8` the SSE layer uses).
- [ ] Run `zig build test --summary all` — confirm the 3 new tests FAIL (file not imported yet → compile error counts as red).
- [ ] Implement `subagent_progress.zig`:

  ```zig
  pub const ProgressStatus = enum { launched, completed, failed };

  pub const ProgressEventInput = struct {
      parent_session_id: []const u8,
      tool_call_id: []const u8,
      agent_name: []const u8,
      status: ProgressStatus,
      agent_index: usize,      // 0-based position in the spawn batch
      total_agents: usize,
      session_id: []const u8 = "",   // sub-agent's own session ("" if not yet created)
      elapsed_ms: i64 = 0,
  };

  /// Builds the JSON payload string (caller owns, arena-friendly).
  pub fn buildProgressEventJson(allocator: std.mem.Allocator, input: ProgressEventInput) ![]u8;

  /// One-shot: build + emit on the llm channel. Fire-and-forget:
  /// errors are logged, never propagated (progress must never kill a sub-agent).
  pub fn emitProgressEvent(input: ProgressEventInput) void;
  ```

  Wire shape (matches `SseEventLLMHistory` fields so it flows through the existing `llm_full` pipe untouched):

  ```json
  {
    "type": "full",
    "role": "subagent_progress",
    "session_id": "<parent session_id>",
    "tool_call_id": "<parent tool_call_id>",
    "agent_name": "research-frontend",
    "status": "launched",
    "agent_index": 0,
    "total_agents": 3,
    "subagent_session_id": "subagent_1787..._research-frontend",
    "elapsed_ms": 0,
    "content": "",
    "loop_index": 0, "temperature": 0, "is_thinking": false,
    "is_input": false, "is_output": false, "model": "", "cwd": ""
  }
  ```

  Implementation of `emitProgressEvent`: call `nalarcore.getSingleton()`, then the same `onEventSendLLMHistory` path `sendSSEForMessageById` uses (see `handle_tool.zig:716` for the call shape) with `role = "subagent_progress"` and empty content. Wrap the whole body in `catch |err| { logger.warnFmt(...) }` — never propagate.
- [ ] Re-export in `src/root.zig` (`pub const subagent_progress = @import("ai_workflow/tui/agentic_loop/subagent_progress.zig");`) and add the test import in `src/ai_workflow/tui/test_runner.zig`.
- [ ] Run `zig build test --summary all` — 3 new tests PASS, zero regressions.
- [ ] **Commit:** `feat(subagent): pure progress-event builder + emitter helper`

### Task 2 — Backend: emit from sub-agent threads + thread tool_call_id

**Files:** `src/ai_workflow/tui/agentic_loop/tools.zig` (EDIT), `src/ai_workflow/tui/agentic_loop/handle_tool.zig` (EDIT), `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` (EDIT), test file from Task 1 (EDIT).

- [ ] Write failing static-contract test: grep the `execSpawnSubAgent` function body (the `pub fn execSpawnSubAgent` → EOF window, same technique as `design_model_group_test.zig`) and assert it contains all three `emitProgressEvent` call sites with `.status = .launched`, `.status = .completed`, `.status = .failed`. Also assert `ToolExecContext` (tools.zig) declares `tool_call_id`.
- [ ] Run `zig build test --summary all` — new test FAILS (red).
- [ ] Add `tool_call_id: []const u8 = ""` to `ToolExecContext` in `tools.zig` (default empty so all other exec files compile untouched).
- [ ] In `handle_tool.zig` where `ToolContext` is built (~line 531), add `.tool_call_id = tool_call.id` — wait, `ToolContext` is built ONCE before the dispatch loop, but `tool_call_id` is per-call. Check the actual struct: if `ToolContext` is per-loop, instead pass `tc.id` into `execSpawnSubAgent` via the existing `ToolExecContext` only if it's constructed per tool_call; otherwise add a `tool_call_id` parameter to `dispatchTool`'s spawn branch. **Executor note:** read `handle_tool.zig:530–610` first and pick the minimal-diff path; the invariant is only "execSpawnSubAgent must know the parent's tool_call_id for THIS call".
- [ ] In `tools_exec_spawn_sub_agent.zig`:
  - Capture `tool_call_id` into `SubAgentThreadArgs` (new field).
  - In `runSubAgent`, AFTER session_id is stored in shared results (~line 123), call `emitProgressEvent(.{ .status = .launched, .agent_index = args_ptr.thread_idx, .total_agents = <total>, ... })`. Add `total_agents: usize` to `SubAgentThreadArgs` too.
  - On each early-return error path (session_id alloc fail, copy fail, workflow error, getLatestMessage fail, empty response): call `emitProgressEvent(.{ .status = .failed, ... })` right before setting `error_message`/returning. Simplest: wrap the existing body — set a local `var failed_emitted = false;` and emit in a single `fail()` closure-style helper per branch, OR emit once at each `return` site (there are ~6; prefer a small `fn failSubAgent(args_ptr, err_msg)` helper that sets the slot + emits + returns).
  - After `success = true` is set (~line 230), call `emitProgressEvent(.{ .status = .completed, .session_id = sess_id, ... })`.
  - Elapsed: capture `std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds` at thread start; compute ms at each emit.
- [ ] Run `zig build test --summary all` — static-contract test PASSES, full suite green.
- [ ] Manual smoke (optional but recommended): run the binary on port 8080 (NEVER 8081), send a message that triggers a 2-agent spawn, watch `~/.config/nalar/agent.db` + logs for 6 progress events (2 launched + 2 completed/failed).
- [ ] **Commit:** `feat(subagent): emit launched/completed/failed progress events from sub-agent threads`

### Task 3 — Frontend: SpawnSubAgent.vue live-progress rendering

**Files:** `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` (EDIT), `src/apps/desktop/src/components/tool_outputs/__tests__/SpawnSubAgent.spec.ts` (EDIT).

- [ ] Write failing component tests in `SpawnSubAgent.spec.ts`:
  - `renders live progress rows when progress prop is set and content has no results` — mount with `content=""` (or placeholder content) + `progress` prop = `[{ name:'a', status:'running', index:0 }, { name:'b', status:'done', index:1 }]`; assert 2 rows render, one with a spinner/running indicator, one with ✓.
  - `shows running count in header while in progress` — header shows `2 sub-agents · 1 running · 1 done` (or equivalent) instead of `0 sub-agents`.
  - `failed row shows ✗ and error styling`.
  - `final results still render when content arrives (progress prop ignored)` — mount with a full `<results>` envelope + stale progress prop; the parsed-results view wins.
  - `peek button on a running row emits peek with its subagent_session_id`.
- [ ] Run `bun run test -- SpawnSubAgent` — new tests FAIL (red).
- [ ] Implement in `SpawnSubAgent.vue`:
  - New optional prop: `progress?: SubAgentProgress[] | null` where `SubAgentProgress = { name: string; status: 'running'|'done'|'failed'; index: number; total: number; sessionId?: string; elapsedMs?: number }`.
  - Computed `displayRows`: if `parsedResults` (from content) is non-empty → existing behavior (final envelope wins). Else if `progress` non-empty → render live rows from progress. Else → current empty fallback.
  - Header: when in live mode show `N sub-agents · R running · D done · F failed` with a subtle pulse animation on running rows (CSS only, respect existing dark theme tokens).
  - Running rows: spinner dot + agent name + elapsed chip; done rows: green ✓ + peek button (reuse existing `peekAgent` emit — sessionId comes from `progress[i].sessionId`); failed rows: red ✗.
  - Keep the existing expand/collapse affordance; in live mode the body auto-shows the row list (no `+` needed until results land).
- [ ] Run `bun run test -- SpawnSubAgent` — all PASS; `bun run build` clean (vue-tsc).
- [ ] **Commit:** `feat(chatview): SpawnSubAgent card renders live per-agent progress rows`

### Task 4 — Frontend: ChatView SSE routing into per-tool progress map

**Files:** `src/apps/desktop/src/components/views/ChatView.vue` (EDIT), `src/apps/desktop/src/components/views/__tests__/ChatView.subagent-progress.spec.ts` (NEW).

- [ ] Write failing test for the routing logic. Extract the reducer into a small exported helper (e.g. `src/apps/desktop/src/helpers/subagentProgress.ts` with `applyProgressEvent(map, event) → new map`) so it's unit-testable without mounting ChatView:
  - `launched event creates running entry keyed by tool_call_id+agent_index`.
  - `completed event flips that agent to done`.
  - `failed event flips to failed`.
  - `events for other tool_call_ids don't cross-contaminate`.
  - `map is keyed so two concurrent spawn_sub_agent calls don't collide`.
- [ ] Run `bun run test -- subagentProgress` — FAIL (red).
- [ ] Implement `subagentProgress.ts` helper (pure functions, ~40 lines).
- [ ] Wire ChatView.vue:
  - In the existing `bus.on('llm', ...)` handler (~line 2033), add an early branch: `if (event.role === 'subagent_progress' && event.tool_call_id) { subAgentProgressMap.value = applyProgressEvent(subAgentProgressMap.value, event); return }` — BEFORE the existing full/chunk handling so progress events never touch message state.
  - New `const subAgentProgressMap = ref<Record<string, SubAgentProgress[]>>({})` keyed by `tool_call_id`.
  - In the `SpawnSubAgent` mount (~line 2839), pass `:progress="subAgentProgressMap[getToolCallIdForMessage(msg)] ?? null"`. The tool_call_id is already available on the message row (`msg.tool_call_id`) — verify the exact field name in the `Message` interface and reuse it.
  - Cleanup: when the final tool result arrives for that `tool_call_id` (existing SSE full-event path) OR on unmount, delete the map entry (progress is ephemeral; the final envelope takes over rendering).
- [ ] Run full frontend suite: `bun run test` (all files), `bun run build`. All green.
- [ ] **Commit:** `feat(chatview): route subagent_progress SSE events into live progress map`

### Task 5 — End-to-end verification + docs

**Files:** none new (verification only), plus this plan's checkbox updates.

- [ ] `zig build test --summary all` — full backend suite green, note the count.
- [ ] `cd src/apps/desktop && bun run test && bun run build` — full frontend suite green, note the count.
- [ ] Functional smoke via the python harness (NOT a live 8081 server): boot binary on a free port 8080–8199 with isolated HOME, drive a session whose reply calls spawn_sub_agent with 2 trivial agents, assert the SSE stream contains `role":"subagent_progress"` events between the placeholder insert and the final `llm_full` result. (If driving the LLM is impractical in the harness, assert at the unit level — Task 1/2 tests — and do a manual UI smoke instead; record which path was taken.)
- [ ] Manual UI smoke on port 8080: spawn a 3-agent research task; confirm the card shows live rows ticking from running → done, peek works mid-run on a done/running agent, and the final envelope replaces the live view.
- [ ] Update `docs/superpowers/plans/2026-08-23-spawn-sub-agent-live-progress.md` checkboxes as tasks complete.
- [ ] **Commit:** `test(subagent): e2e verification + plan checkbox sync`

## Pitfalls

- **SSE wire contract:** we deliberately reuse `llm_full` + a new `role` value. The browser drops UNKNOWN event *names*, but `llm_full` is already registered — a new role inside a known event name needs NO 3-site change. If a reviewer insists on a dedicated `subagent_progress` event name, you MUST change all 3 sites together: backend `event_type` mapping (`on_event_sent.zig`), `additionalEventTypes` (`api/index.ts:3093`), and the dispatch chain (`api/index.ts:3127+`). Half-done = silent feature death.
- **Don't write progress events to llm_history.** They are SSE-only. A `saveMessage` call here would pollute the LLM's context and the chat transcript.
- **Thread safety:** `emitProgressEvent` runs on sub-agent threads. It must not touch `shared_results` (except reading its own slot) and must never propagate errors — a progress-emission failure must not fail the sub-agent.
- **`getLatestMessage` trap:** do NOT emit progress by updating the parent's placeholder row + `sendSSEForLatestMessage` — that's the B1 bug pattern from PR #299 (latest-row race with parallel placeholders). Key everything by explicit `tool_call_id` and emit synthetic payloads instead.
- **Frontend dedupe:** ChatView's SSE full-handler dedupes on `role+content+tool_call_id` (PR #299). Progress events have a distinct role so they won't be eaten by that dedupe — but keep the early-return branch BEFORE the dedupe path anyway.
- **Vue reactivity:** mutate the progress map by REPLACEMENT (`map.value = { ...map.value, [key]: newRow }`), not in-place array push, or rows won't re-render.
- **Test discovery gotcha** (from memory): new Zig test files need an explicit `_ = @import(...)` in `src/ai_workflow/tui/test_runner.zig` AND/OR `src/root.zig` — a `mod.zig` re-export alone does NOT make tests run; symptom is test count unchanged.

## Verification

- [ ] `zig build test --summary all` green with new tests (baseline ~2536 pass — expect +8 or more)
- [ ] `bun run test` green (baseline 255 files / 2454 tests — expect +9)
- [ ] `bun run build` (vue-tsc + vite) clean
- [ ] Manual UI smoke: live rows visible mid-run on port 8080 (never 8081)
- [ ] Final `<results>` envelope still renders exactly as before when the tool completes
