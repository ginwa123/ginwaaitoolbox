# Spawn Sub-Agent Refresh Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refreshing the page mid-run no longer collapses a running `spawn_sub_agent` card to "0 sub-agents" — it rehydrates running rows from the backend and keeps following live progress until the final `<results>` envelope arrives.

**Architecture:** Keep the current ephemeral SSE progress events as the live path (no change to `role="subagent_progress"` wire shape); add a backend in-memory progress snapshot registry (tool_call_id → per-agent rows) that survives page refresh but not server restart, expose it via a snapshot read (piggyback on existing session-messages GET or a tiny new GET endpoint), and make `ChatView.loadChatHistory` rehydrate `subAgentProgressMap` from that snapshot for any tool row still in placeholder (`<data>`, no `<results>`) state.

**Tech Stack:** Zig 0.16 backend (`subagent_progress.zig`, `tools_exec_spawn_sub_agent.zig`, session-messages GET handler), Vue 3 frontend (`helpers/subagentProgress.ts`, `ChatView.vue`, `SpawnSubAgent.vue`), SQLite `llm_history` (read-only for this fix — no migration), SSE `event_bus` (`llm_full`).

## Global Constraints

- DONT KILL the port 8081 server; functional tests use harness free ports 8080..8199 (see `tests/functional/harness.py` + `README.md` ⛔ section).
- Verification via isolated functional tests booting fresh `nalar` binary against tmpdir HOME — NEVER `nohup ./zig-out/bin/nalar + curl` (leaks process, misses route-order / empty-slice-as-NULL / strict-validator bugs). See `.nalar/skills/replay-frontend-wire-payload-in-functional-tests`.
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena slices in handlers; KEEP `rows.deinit()` (sqlite finalize) + file/socket closes.
- SSE wire contract: any new/renamed `event_type` must change all 3 sites (backend `onEventSend*` emitter + `additionalEventTypes` in `api/index.ts` + named-event dispatch chain). This plan deliberately adds NO new event_type (reuses `llm_full` + `role="subagent_progress"`).
- No migration, no schema change, no config shape change. Progress stays out of `llm_history` (never fed to LLM).
- Follow existing patterns: `subagent_progress.zig` pure builder + inline tests; `helpers/subagentProgress.ts` pure reducer + vitest; static-contract tests for route order.
- `pnpm` (not npm/bun) for webapp scripts; `vue-tsc --build` emits stray `.js` — delete before commit.

## Background / Root Cause (verified 2026-09-04, two parallel researchers)

- Backend `src/ai_workflow/tui/agentic_loop/subagent_progress.zig:17-20` — "No DB writes (progress is ephemeral; the final `<results>` envelope remains the source of truth)". `emitProgressEventWith` (L211-270) pushes directly on `event_bus` (per-session + central `llm`, `event_type="llm_full"`), bypassing `onEventSendLLMHistory`. Nothing with `role='subagent_progress'` is ever INSERTed (`insert_llm_histories.zig` column list has no such columns; `SseEventLLMHistory` in `sse_on_event_send_llm_history.zig:19-52` has no `status/agent_index/total_agents` fields).
- Frontend state is ChatView-local `subAgentProgressMap = ref<SubAgentProgressMap>({})` (`ChatView.vue:899-904`), fed solely by live `bus.on('llm')` handler (`:2107-2130`, `role==='subagent_progress'` → `applyProgressEvent` + early return, "ephemeral, NOT persisted"). Two `clearProgressFor` sites on final envelope (L2248-2258 placeholder-update path, L2361-2371 push path). Plain `ref` → remount/refresh re-inits to `{}` (contrast `agentError` Pinia store which survives remounts — but even Pinia would not survive full page reload).
- `loadChatHistory` (`ChatView.vue:1315`, mapper L1362-1380) + `api.getChatHistory` (`api/index.ts:1208-1311`, `GET /llm/session/:id/messages`) carry only persisted columns (`tool_calls_json/tool_call_id/...`) — zero references to progress map. Mid-run refresh sees at most the empty placeholder row written by `handle_tool.zig:554-567`, so `SpawnSubAgent.vue` (`inLiveMode = liveProgress.length>0 && agents.length===0`, L145-147) falls through to "0 sub-agents".
- Backend workflow threads keep running after refresh (refresh only drops the SSE subscription) — so the fix is rehydration, not resurrection. Server restart is out of scope (map is process memory; on restart show honest "interrupted" fallback).

## File Map (create / modify)

- EDIT `src/ai_workflow/tui/agentic_loop/subagent_progress.zig` — add snapshot registry (mutex-guarded HashMap) + snapshot getter.
- EDIT `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` — write registry on launched/completed/failed + clear on final envelope.
- EDIT session-messages GET handler (whichever serves `GET /llm/session/:id/messages` — likely `src/ai_workflow/tui/*session_messages_get*.zig`) — attach `subagent_progress_snapshot` for placeholder rows, OR new tiny `GET /api/subagent/progress?tool_call_id=` handler + route in `main.zig` (AFTER literal routes to avoid `:param` shadowing; static-contract test locks order).
- EDIT `src/apps/desktop/src/helpers/subagentProgress.ts` — add snapshot → map rehydrator (reuse `applyProgressEvent` shape).
- EDIT `src/apps/desktop/src/components/views/ChatView.vue` — call rehydrator at end of `loadChatHistory` for placeholder `spawn_sub_agent` rows; keep existing live bus + clear-on-envelope logic untouched.
- EDIT `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` — only if needed: render "reconnecting…" / "interrupted by restart" fallback states.
- NEW `docs/superpowers/plans/2026-09-04-spawn-subagent-refresh-persistence.md` (this file).
- NEW/EDIT tests: `subagent_progress_test.zig` (registry), `tools_exec_spawn_sub_agent_test.zig` (registry writes), `subagentProgress.spec.ts` (rehydrator), `ChatView.subagent-refresh.spec.ts` (loadChatHistory rehydrate), `tests/functional/subagent_refresh_test.py` (harness: launch long subagents → refresh-equivalent GET → assert snapshot non-empty → await completion → assert final envelope).

## Decision: snapshot registry vs persist-to-DB (why snapshot wins)

- Persisting each progress event as `llm_history` rows would pollute the LLM context (`get_llm_histories` feeds history to the model; `is_feed_to_llm` filtering would need surgery) and bloat the DB with high-churn `elapsed_ms` updates.
- Snapshot registry keeps the original "No DB writes" design invariant, adds ~100 lines Zig + ~50 lines TS, and degrades honestly on server restart (empty snapshot → "interrupted" UI, same as today but labeled).
- Rejected alternative documented: moving `subAgentProgressMap` to Pinia alone — fixes ChatView remount (session switch) but NOT full page reload (JS memory wiped). Still worth doing as a 5-line follow-up inside Task 4, not as the fix.

---

## Tasks

### Task 1 — Backend: snapshot registry in `subagent_progress.zig` (TDD)

- [ ] Read `src/ai_workflow/tui/agentic_loop/subagent_progress.zig:1-120` (contract, types, builder) + `tools_exec_spawn_sub_agent.zig:43-60` (thread args) to match field names.
- [ ] Write failing test in `subagent_progress_test.zig` (or inline `test` block per repo convention — check where the 6 existing wire-shape tests live): `upsertProgress(tool_call_id, event)` then `getSnapshot(tool_call_id)` returns rows; `clearSnapshot(tool_call_id)` empties; `done→running` regress guard preserved.
- [ ] Run it to confirm it fails (`zig build test --summary all` filtered or `zig test` on the file per repo docs).
- [ ] Implement minimal registry: `std.StringHashMap` (or existing map pattern in codebase — grep `StdioRegistry`/`HttpRegistry` for the process-global + mutex idiom) keyed by `tool_call_id`, value = per-agent rows (`agent_name/status/agent_index/total_agents/subagent_session_id/elapsed_ms`); `upsert` on every emit, `clear` helper for final envelope. All mutex-protected; never blocks emit (emit stays fire-and-forget, errors caught+logged).
- [ ] Run tests to green; commit.

### Task 2 — Backend: wire registry writes into emit sites + clear on final envelope

- [ ] Read `tools_exec_spawn_sub_agent.zig:115-145` (FailHelpers), `:203-216` (launched), `:293-302` (failed), `:344-369` (completed/failed branches), `:528-560` (final envelope after `group.await()`).
- [ ] Write failing static-contract test (repo `*_test.zig` grep-window pattern): registry `upsert` called at launched/completed/failed sites + `clear` called after final envelope build.
- [ ] Run to confirm fail.
- [ ] Implement: call registry `upsert` alongside each existing `emitProgressEvent` (same args, no wire change); call `clear` right after final `<results>` envelope is built (but keep rows until envelope persisted + SSE sent so late refreshers still see completion — clear AFTER `updateToolResultById` + `sendSSEForMessageById`, not before).
- [ ] Per-request arena check: registry owns its own copies (dupe `tool_call_id`/`agent_name` into registry allocator, NOT `ctx.allocator` arena) — snapshot must outlive the request scope.
- [ ] Run `zig build test --summary all` green; commit.

### Task 3 — Backend: expose snapshot on the read path (no migration)

- [ ] Read the handler serving `GET /llm/session/:id/messages` (grep `session/:id/messages` route registration in `main.zig`; note registration ORDER — new literal route must precede `/:param` siblings or it gets shadowed; add static-contract test asserting order like `tasks_get_test.zig` does).
- [ ] Decide: (a) piggyback — for each returned row where `tool_name==='spawn_sub_agent'` AND `response_content` has `<data>` but no `<results>`, attach `subagent_progress: [...]` from registry; or (b) separate `GET /api/subagent/progress?tool_call_id=` returning the same array. Prefer (a) — one round-trip, no new route-order risk; fall back to (b) if the messages handler can't see the registry without layering violation.
- [ ] Write failing test: seed registry with 3 launched rows → GET messages → assert snapshot array present on placeholder row, absent on completed (`<results>`) rows and non-spawn rows.
- [ ] Run to confirm fail.
- [ ] Implement minimal read (registry mutex read-lock, copy into response arena via `ctx.allocator` — response copies ARE arena-owned, correct here).
- [ ] Functional harness check (isolated tmpdir HOME, free port, NOT 8081): boot binary, create session, launch long-running spawn_sub_agent, GET messages mid-run, assert snapshot length matches launched count.
- [ ] Run `zig build test --summary all` green; commit.

### Task 4 — Frontend: rehydrate `subAgentProgressMap` in `loadChatHistory`

- [ ] Read `ChatView.vue:1315-1400` (`loadChatHistory` + mapper), `helpers/subagentProgress.ts:102-173` (`applyProgressEvent`/`clearProgressFor`), `SpawnSubAgent.vue:143-156` (`inLiveMode`/`liveSummary`).
- [ ] Write failing vitest `ChatView.subagent-refresh.spec.ts`: mock `getChatHistory` returning one placeholder `spawn_sub_agent` row WITH `subagent_progress: [3 running rows]` → mount → assert `subAgentProgressMap[tool_call_id]` has 3 rows and card shows "3 running" (use `document.querySelector`, NOT `wrapper.find`, if Teleport involved — per `vue-teleport-vitest-document-queryselector` skill).
- [ ] Run to confirm fail (`pnpm test:unit` filtered).
- [ ] Implement: at end of `loadChatHistory` (after `messages.value` set), for each placeholder spawn row with snapshot, `subAgentProgressMap.value[tool_call_id] = snapshot` (map-by-replacement for reactivity, same as `applyProgressEvent`). Do NOT touch live bus handler or clear-on-envelope sites. Optional 5-line bonus: move `subAgentProgressMap` to Pinia (like `useAgentErrorStore`) so session-switch remount also survives — but snapshot rehydrate remains the reload fix.
- [ ] Handle empty-snapshot-after-restart: if placeholder row has no snapshot (server restarted, registry wiped), `SpawnSubAgent.vue` shows honest fallback "Sub-agent run interrupted (page reloaded after server restart) — final result unavailable" instead of "0 sub-agents". Keep copy short.
- [ ] Run `pnpm test:unit` (expect +N new, 0 fail), `vue-tsc --noEmit -p tsconfig.app.json` clean; delete stray `.js` emissions; commit.

### Task 5 — E2E + regression verification

- [ ] Write `tests/functional/subagent_refresh_test.py` (harness pattern — see `tests/functional/agent_knowledge_edit_test.py` for exact-body replay): (1) launch session with long subagents, (2) mid-run GET messages → assert snapshot non-empty + placeholder present, (3) await completion → GET again → assert `<results>` envelope + snapshot cleared, (4) refresh-equivalent re-GET → assert final renders without live rows.
- [ ] Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/subagent_refresh_test.py -v` green.
- [ ] Run full gates: `zig build test --summary all` (0 fail), `pnpm test:unit` (0 fail), `zig build nalar-desktop --summary all` (steps OK).
- [ ] Grep new `subagent_progress` name across backend emitter + `additionalEventTypes` + dispatch chain to prove no wire-contract break (should appear in NONE of the three — no new event_type by design).
- [ ] Commit + open PR (worktree per repo habit, e.g. `worktree/spawn-subagent-refresh-persist`); leave card in `in_review_task` for human review — DO NOT merge.

## Pitfalls

- Registry copies must NOT borrow `ctx.allocator` arena memory (freed at request end) — dupe keys/rows into registry-owned allocator or they dangle. Response copies SHOULD use `ctx.allocator` (freed with the request, correct).
- Clearing too early hides completion from late refreshers — clear only after envelope UPDATE + SSE send, and keep serving the final envelope from DB (existing path) afterwards.
- `elapsed_ms` goes stale the moment it's snapshotted — frontend should keep ticking display from snapshot timestamp (existing `formatElapsed` already does) or freeze with "as of reload" hint; never poll the snapshot in a loop (one rehydrate per `loadChatHistory`, live SSE takes over after).
- Route-order shadowing: if a new GET route is added, register literal BEFORE `/:param` siblings and lock with static-contract test.
- Empty-slice-as-NULL: `tool_call_id=""` binds as SQL NULL — snapshot lookup must skip empty ids (same guard as existing `clearProgressFor` call sites).

## Verification

- [ ] Plan saved here and reviewed by user before execution.
- [ ] Mid-run refresh shows "N running" rows (not "0 sub-agents"); live SSE continues updating them; completion flips to final `<results>` and clears the map entry.
- [ ] Post-completion refresh shows final envelope (unchanged behavior).
- [ ] Server-restart mid-run shows honest "interrupted" fallback (not fake "0 sub-agents", not a hang).
- [ ] `zig build test --summary all`: 0 fail. `pnpm test:unit`: 0 fail. Functional `subagent_refresh_test.py`: green. `zig build nalar-desktop`: steps OK.
