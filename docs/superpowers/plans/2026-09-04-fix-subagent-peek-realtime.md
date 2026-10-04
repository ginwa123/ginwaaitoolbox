# Fix Sub-Agent Peek Realtime (Eye Icon Always Empty) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking the 👁 eye on a sub-agent (live or after done) shows its messages live and after completion instead of permanent `No messages yet.`

**Architecture:** Fix the sid transport first (URL-safe child session id + encode/decode), then fix the panel lifecycle (composable out of `computed` + refetch on completion), then close the realtime gap (parent-scoped `completed` triggers a refetch). No new SSE `event_type`, no migration, no schema change.

**Tech Stack:** Zig backend (`tools_exec_spawn_sub_agent.zig`, `router.zig`, `session_messages_get.zig`, `llm_history.zig`), Vue frontend (`SpawnSubAgent.vue`, `ChatView.vue`, `useSubAgentPeek.ts`, `SubAgentPeekPanel.vue`, `api/index.ts`), SQLite `llm_history`, SSE `llm_chunk`/`llm_full` + `subagent_progress` role.

## Global Constraints

- DONT KILL THE PORT 8081 SERVER — functional tests use another port (harness picks 8080..8199 excl. 8081).
- Verification via isolated functional harness (`tests/functional/harness.py` boots fresh `pabrikcore-linux-x86_64` against tmpdir HOME), NEVER `nohup ./zig-out/bin/pabrik + curl` live server.
- TDD: failing test first (red), minimal fix (green), regression suite, commit per task. Never delete existing tests to make green.
- Git worktree for all implementation (`worktree/fix-subagent-peek-realtime`); open PR for `in_review_task`.
- SSE wire-format contract: any new/renamed `event_type` must change all 3 sites (backend emitter + `additionalEventTypes` + dispatch chain). This plan adds NO new event_type — do not add one.
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena memory in handlers; keep `rows.deinit()` for sqlite stmts.
- Frontend: `pnpm test:unit` (not npm), `vue-tsc --noEmit` clean; backend: `zig build test --summary all` green.

## Root-Cause Summary (from 3 parallel investigators, 2026-09-04)

1. **P0 — sid not URL-safe (reproduces "empty even after done").** Child sid = `subagent_{ns}_{raw_agent_name}` (`tools_exec_spawn_sub_agent.zig:169-172`, only non-empty/≤256 validated in `spawn_sub_agent.zig:289-296`). Peek interpolates raw with NO `encodeURIComponent` (`useSubAgentPeek.ts:181`, same in `api/index.ts:1246`). Router stores path segment raw with NO `urlDecode` (`router.zig:689`; `urlDecode` in `http_parser.zig:30` only wired to form/query). Space → `%20` literal lookup → `WHERE h.session_id=?` matches 0 rows → 200 `messages:[]`. `/` → segment-count mismatch (`router.zig:695`) → 404 → `silent:true` swallows (`apiFetch :84-91`, `useSubAgentPeek.ts:197-200`). Single-token names (`code-reviewer`) work; `backend-implementer` with space/specials fails. Screenshot shows `backend-implementer` — matches.
2. **P1 — composable inside `computed` (frontend-only always-empty).** `ChatView.vue:319-327` calls `useSubAgentPeek()` (registers `onMounted/onUnmounted` at `useSubAgentPeek.ts:224-230`) inside a `computed`. Each re-eval creates fresh refs + new mount closure; fetch fires 0/N times or detaches from rendered `peek.messages.value` (`:3722`). Panel then sees `[]` → `SubAgentPeekPanel.vue:234-239` empty state.
3. **P2 — fetch-once + parent-scoped completion (live gap + stale after done).** `fetchInitial` runs once on mount; no `watch(sessionId)`, no poll, no refetch on `completed` (`useSubAgentPeek.ts:170-201,224-238`). Completion signals are all parent-scoped and dropped by peek's `session_id===sid` filter (`:212`): progress `completed/failed` (`subagent_progress.zig:263` sets `session_id=parent`), parent `<results>` envelope (`handle_tool.zig:671,745`), placeholder SSE (`:563-567`). Sub-agent's own terminal `llm_full` IS child-scoped (`workflow.zig:1205-1233`) but ephemeral — open-after-done never sees it. Zero rows → `status=streaming` (finish_reason gate `:189-192` never true) → same `No messages yet.` pixels.
4. **Ruled OUT:** DB SELECT is correct (`WHERE h.session_id=?`, LEFT JOIN, no parent filter — `llm_history.zig:633-662`); SSE pre-registration correct (`llm_chunk|llm_full` in `additionalEventTypes :3239-3240` + dispatch `:3334-3343`); route-order shadowing none (`main.zig:330-345`, distinct literal tails); missing child `sessions` row harmless (LEFT JOIN).
5. **P3 minor — unescaped envelope XML** (`tools_exec_spawn_sub_agent.zig:549-556` raw `<session_id>/<response>`; name with `<>&` corrupts `SpawnSubAgent.vue:61,68` regex). Fix with escaping + test.
6. **P4 minor — snapshot wiped at completion** (`:585` + `:385` clear; `subagent_progress_get.zig:13,41` returns `[]` after done). Peek must NOT depend on progress endpoint for sid — envelope sid (persisted in parent history) is the source of truth. No code change unless a consumer uses progress-for-sid-after-done; document it.

## File Map (touch / read-only)

Touch:
- `src/ai_workflow/tui/agentic_loop/tools_exec_spawn_sub_agent.zig` — slugify sid + escape envelope XML.
- `src/modules/agent/tools/spawn_sub_agent.zig` — tighten name validation message (keep accepting, slugify downstream; do NOT newly reject names and break compat).
- `src/modules/custom_http_server/src/router.zig` (+ `http_parser.zig` if needed) — url-decode `:session_id` path param (or decode at handler).
- `src/ai_workflow/tui/http_handlers/session_messages_get.zig` — static-contract test target (decode expectation), no logic change if router decodes.
- `src/apps/desktop/src/composables/useSubAgentPeek.ts` — `encodeURIComponent`, `watch(sessionId)` refetch, listen for parent `completed` with matching `subagent_session_id` → refetch, fix premature `tool_calls→complete`.
- `src/apps/desktop/src/components/views/ChatView.vue` — move `useSubAgentPeek` out of `computed` into setup-scope + pass-through.
- `src/apps/desktop/src/components/pabrik/SpawnSubAgent.vue` — `encodeURIComponent`-safe sid handling (no logic change if composable encodes; add regression spec for sid with space).
- `src/apps/desktop/src/api/index.ts` — `getChatHistory`-adjacent encode (same bug shape at `:1246`); verify `additionalEventTypes` untouched.
- Tests: `*_test.zig` inline/static-contract, `tests/functional/subagent_peek_test.py` (new), `useSubAgentPeek.spec.ts` + `SpawnSubAgent.spec.ts` (new/extend).

Read-only (verify, don't change unless test proves otherwise):
- `src/ai_workflow/tui/agentic_loop/llm_history.zig:600-662` (SELECT), `workflow.zig:754-793,1205-1233`, `subagent_progress.zig`, `on_event_sent.zig:355-366`, `sse_on_event_send_llm_history.zig:192-203`, `src/main.zig:311,331`, `SubAgentPeekPanel.vue` (presentational).

## Task Breakdown (TDD + worktree, bite-sized)

### A — Worktree + reproduction scaffold
- [ ] A1. Write failing frontend spec: `useSubAgentPeek` with `sessionId='subagent_1_backend implementer'` (space) asserts fetch URL is encoded (`%20`) — RED.
- [ ] A2. Write failing backend static-contract: `GET /api/llm/session/subagent_1_backend%20implementer/messages` decodes to stored sid — RED (unit-level router/handler test, no live server).
- [ ] A3. Write failing functional test `tests/functional/subagent_peek_test.py::test_peek_after_done_with_space_name` replaying exact frontend wire (spawn sub-agent named `backend implementer`, wait done, `GET .../messages` with raw vs encoded sid) — RED. Harness picks free port (never 8081).
- [ ] A4. Create worktree `worktree/fix-subagent-peek-realtime` via `set_git_worktree` (branch `worktree/fix-subagent-peek-realtime`), commit scaffold only.

### B — P0 sid transport fix (backend + frontend encode/decode)
- [ ] B1. Backend test RED: slugify/encode helper for child sid (`subagent_{ns}_{slug(name)}`, slug = spaces→`_` or percent-safe; keep uniqueness via ns prefix) in `tools_exec_spawn_sub_agent.zig` — assert `backend implementer` → `backend_implementer`, `/`/`%`/`<>&` stripped/escaped, empty-name fallback.
- [ ] B2. Implement slugify (GREEN) + keep envelope `<session_id>` = slugged sid (single source of truth).
- [ ] B3. Router/handler test RED: path param `%20`/`%2F` decodes before DB lookup (covers legacy rows with spaces created pre-slugify).
- [ ] B4. Implement decode (GREEN): `router.zig` param decode via existing `urlDecode` OR handler-level decode — prefer router-level so all `:session_id` routes benefit; verify no double-decode.
- [ ] B5. Frontend test RED: `useSubAgentPeek.fetchInitial` + `api.getChatHistory` use `encodeURIComponent(sessionId)`.
- [ ] B6. Implement encode (GREEN) in `useSubAgentPeek.ts:181` + `api/index.ts:1246`.
- [ ] B7. Run `zig build test --summary all` + `pnpm test:unit` — no regressions; commit B.

### C — P3 envelope XML escaping (backend, small)
- [ ] C1. Test RED: agent name `a<b>&c` round-trips through envelope regex (`SpawnSubAgent.vue:61,68`) — currently corrupts.
- [ ] C2. Implement escaping (GREEN) for `<session_id>`/`<response>`/`<error>` in `tools_exec_spawn_sub_agent.zig:544-566` (escape `&<>"` or CDATA with `]]>` split per `enrichCompactionXml` precedent) + frontend parse test GREEN.
- [ ] C3. Verify suite; commit C.

### D — P1 composable-out-of-computed (frontend lifecycle)
- [ ] D1. Test RED: `ChatView` peek wiring — `useSubAgentPeek` called once per panel open (not per computed re-eval), `fetchInitial` fires exactly once on mount with correct sid.
- [ ] D2. Implement (GREEN): move `useSubAgentPeek({sessionId,agentName,instruction})` out of `computed` (`ChatView.vue:319-327`) to setup-scope driven by `nav.peekPanel` (watch or direct props), pass `status/messages/reload` through to `SubAgentPeekPanel :3715-3727`.
- [ ] D3. Add `watch(()=>payload.sessionId)` → `fetchInitial` + `closeSse` cleanup (covers eye-click from agent A → agent B without unmount).
- [ ] D4. `pnpm test:unit` + `vue-tsc --noEmit` clean; commit D.

### E — P2 refetch-on-completion + status correctness (frontend realtime)
- [ ] E1. Test RED: panel opened mid-run with 0 rows → on parent-scoped `subagent_progress completed/failed` with matching `subagent_session_id` → refetches and shows messages (currently stays empty).
- [ ] E2. Implement (GREEN): `useSubAgentPeek` subscribes to `bus.on('llm')` for `role==='subagent_progress'` events where `event.subagent_session_id===sid` + `(completed|failed)` → `fetchInitial()`; also handle direct child terminal `llm_full finish_reason=stop` → `status=complete` (already) WITHOUT closing subscription prematurely on `tool_calls` (fix `:152-159` to only complete on `stop|length|content_filter`, keep streaming on `tool_calls`).
- [ ] E3. Test RED: open-after-done with rows present → `status=complete` immediately via `last.finish_reason` (covers persisted `COALESCE(h.finish_reason,'')` wire).
- [ ] E4. Verify no new `event_type` added (3-site grep: new name must appear in emitter + `additionalEventTypes` + dispatch — assert none added); `pnpm test:unit` green; commit E.

### F — End-to-end verification + PR
- [ ] F1. Functional suite GREEN: `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/subagent_peek_test.py -v` (new: space-name after-done, single-token regression, live-open-then-complete refetch if harness supports SSE; at minimum the two GET-shape tests).
- [ ] F2. Full regression: `zig build test --summary all` (0 fail) + `pnpm test:unit` (all pass) + `vue-tsc --noEmit` clean.
- [ ] F3. Manual wire replay (functional harness only, never port 8081): open eye mid-run → messages stream; open after done → full history; name with space → works; refresh-after-done → works via envelope sid.
- [ ] F4. Push worktree branch, open PR, move card to `in_review_task` (human reviews PR). Do NOT move to `merged` (human-only).

## Pitfalls

- Don't add a new SSE `event_type` for sub-agents — `llm_chunk`/`llm_full` already cover it; a new name without the 3-site update silently drops (EventSource).
- Don't gate the eye on `success/response` — gate on `sessionId` presence (`SpawnSubAgent.vue:191,201` already correct); tool-only runs have empty text but valid sid.
- Don't make peek depend on `GET /api/subagent/progress/:tool_call_id` after done — snapshot is cleared on envelope build by design.
- Don't newly reject agent names with spaces (compat) — slugify downstream + decode legacy rows.
- Don't `defer free` arena memory in handlers; keep `rows.deinit()`.
- Don't test against port 8081; don't `nohup` a live binary — harness only.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-04-fix-subagent-peek-realtime.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins (card stays `in_review_planning`)
