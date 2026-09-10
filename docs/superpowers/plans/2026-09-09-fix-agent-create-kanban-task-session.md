# Fix `create_kanban_task` Agent Tool — Always Insert `sessions` + Initial `llm_history` User Row

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the LLM tool `create_kanban_task` behave like HTTP `POST /api/.../kanban/tasks` with `mode='create_session'` — every created card gets a `sessions` row + a visible initial user message in `llm_history`.

**Architecture:** Replace the conditional sessions INSERT in `src/modules/agent/tools/create_kanban_task.zig::executeCreateKanbanTaskToString` (step 11, line 665) with the unconditional HTTP-mirror path from `src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig:233-376` (full-column sessions INSERT + `llm_history` user-row INSERT + `session_created` SSE). No schema/migration change, no new tool params.

**Tech Stack:** Zig 0.16, SQLite (`SqliteBackend.exec`), existing `onEventSendSessions` / `onEventSendKanbanTask` SSE helpers, inline Zig tests + python functional harness (`tests/functional/harness.py`).

## Global Constraints

- `task.id == session.id` convention MUST hold (Migration 052). `sessions.name = trimmed_name` (NOT `task_id`) per `2026-08-13-kanban-task-session-name-match` plan.
- `INSERT OR IGNORE INTO sessions` (never bare `INSERT`) — a concurrent chat-spawn may have landed first.
- Per-request arena owns all duped slices — no `defer free` on arena memory inside handlers (see repo rule "Per-Request Arena Cleanup").
- `sessions` full shape: `(id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop)` with `VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)` — verbatim from `kanban_tasks_create.zig:248-249`.
- `llm_history` user-row shape: `(id, session_id, model, response_content, finish_reason, role, agent, parent_id, parent_session_id, is_input, image_url, is_feed_to_llm, created_at_nano, created_iso)` with `VALUES (?, ?, '', ?, 'null', 'user', 'Agent', ?, ?, 1, ?, 1, ?, '')` — verbatim from `kanban_tasks_create.zig:336-340`. `model=''` literal (NOT NULL + empty-slice-binds-as-NULL quirk).
- SSE contract: `session_created` via `onEventSendSessions(action="created")` must be added in pairs (backend emitter + `additionalEventTypes` + dispatch chain in `src/apps/desktop/src/api/index.ts`) — verify the frontend already registers `session_created`; if missing, add all three sites together.
- Functional verification MUST use the python harness on a non-8081 port (`NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v`), never `nohup` + `curl` a live server.
- DONT KILL the port 8081 server.

## Background / Root Cause

- Tool file: `src/modules/agent/tools/create_kanban_task.zig:646-708` — step 11 guards the sessions INSERT behind `if (input.is_auto_retry_until_stop != null or (selected_profile_model != null and len > 0))`. Plain agent-created cards (no flag, no profile) get NO `sessions` row → card exists in `workspace_item_tasks` + `kanban` join table but has no chat session; opening the card lazy-creates an empty session and the description is lost.
- Minimal-column INSERT when it does fire: `(id, name, status[, flag][, profile])` — missing `cwd`, `created_at/updated_at`, and defaults `profile=""` / `flag` normalization inconsistently vs HTTP.
- HTTP reference `src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig:233-376` (`is_create_and_run or is_create_session` branch): ALWAYS inserts the full sessions row, then for `is_create_session` inserts the initial user `llm_history` row (`"{name}\n\n{description}"`, `image_urls` wire value attached), then emits `session_created` SSE. The agent tool emits only the `kanban_task created` SSE (step 12) — no `session_created`, so `ChatsList` never refreshes.
- Older HTTP path `src/ai_workflow/tui/http_handlers/task_create.zig:643-656` is also conditional (only on `is_auto_retry_until_stop`) — it is NOT the reference; `kanban_tasks_create.zig` `create_session` is.
- Wrapper `src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig:40` (`const inner = create_kanban_task_mod.executeCreateKanbanTaskToString(...)`) needs no change — fix lives entirely inside `executeCreateKanbanTaskToString`.

## File Map

| File | Change |
|---|---|
| `src/modules/agent/tools/create_kanban_task.zig` (steps 11-12, ~lines 646-720) | Unconditional sessions INSERT + new llm_history INSERT + new session_created SSE; update header doc comment flow steps |
| `src/modules/agent/tools/create_kanban_task.zig` (inline `test` block, from line 726) | New unit tests: sessions row always exists, llm_history user row content, SSE/static-contract presence |
| `tests/functional/agent_create_kanban_task_session_test.py` (NEW) | End-to-end: tool-equivalent create → GET sessions row + GET llm_history user message (mirrors `kanban_task_get_test.py` harness pattern) |
| `docs/superpowers/plans/2026-09-09-fix-agent-create-kanban-task-session.md` (this file) | Review artifact |

No changes to: `tools_exec_create_kanban_task.zig` (pass-through), `tools_equipped.zig` registry, frontend (unless `session_created` registration is missing — verify only), migrations (no new columns).

---

## Task 1 — Failing test: sessions row is created even with no flag/profile

- [ ] Read `src/modules/agent/tools/create_kanban_task.zig:1020-1070` (existing happy-path + row-exists tests) to copy the in-memory DB fixture pattern.
- [ ] Write a failing test `executeCreateKanbanTaskToString always inserts sessions row without flag or profile` that calls `executeCreateKanbanTaskToString` with `is_auto_retry_until_stop=null, selected_profile_model=null`, then `SELECT id, name, status, cwd, selected_profile_model, is_auto_retry_until_stop FROM sessions WHERE id = ?` and asserts the row exists with `name == trimmed input name`, `status == 'active'`.
- [ ] Run it to confirm it FAILS (documents the bug: no row on the current conditional path).
- [ ] Commit: `test: create_kanban_task always inserts sessions (failing)`

## Task 2 — Make sessions INSERT unconditional with HTTP-parity columns

- [ ] In `executeCreateKanbanTaskToString` step 11, delete the `if (input.is_auto_retry_until_stop != null or ...)` guard so the block always runs.
- [ ] Replace the dynamic minimal-column builder with the fixed HTTP-verbatim SQL: `INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)` binding `(task_id, trimmed_name, validated_cwd, profile_or_empty, normalized_flag)`.
- [ ] Normalize: `flag = "1"` iff `input.is_auto_retry_until_stop == "1"` else `"0"`; `profile = input.selected_profile_model orelse ""` (empty string when null/empty — matches HTTP `orelse ""`).
- [ ] Keep failure non-fatal (`catch |err| log.warn + continue`, same as today) so a sessions failure never fails card creation.
- [ ] Re-run Task 1 test → passes.
- [ ] Run `zig build test --summary all` (no regressions).
- [ ] Commit: `fix: create_kanban_task always inserts sessions row`

## Task 3 — Failing test: initial user llm_history row mirrors description

- [ ] Read `kanban_tasks_create.zig:300-352` (the `if (is_create_session)` llm_history block) for the exact SQL + bind order.
- [ ] Write a failing test `executeCreateKanbanTaskToString inserts initial user llm_history row` asserting after a plain create: one `llm_history` row with `session_id == task_id`, `role == 'user'`, `response_content == "{name}\n\n{description}"`, `is_input == 1`, `is_feed_to_llm == 1`, `image_url == passed image_urls or ""`.
- [ ] Run it to confirm it FAILS (no llm_history write exists in the tool today).
- [ ] Commit: `test: create_kanban_task seeds initial llm_history (failing)`

## Task 4 — Insert the initial user llm_history row (HTTP-verbatim)

- [ ] After the sessions INSERT, add the HTTP-verbatim `INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, agent, parent_id, parent_session_id, is_input, image_url, is_feed_to_llm, created_at_nano, created_iso) VALUES (?, ?, '', ?, 'null', 'user', 'Agent', ?, ?, 1, ?, 1, ?, '')` binding `(nanos_id_str, task_id, "{trimmed_name}\n\n{trimmed_description}", task_id, task_id, image_urls_wire, nanos_created_str)`.
- [ ] Generate both nano strings from the same timestamp source the file already uses (`helpers.unixTimestampNanos()` at line 573 — reuse one call for task_id + llm row, or take a second reading; document which).
- [ ] `image_urls_wire` = `validated_image_urls` (already validated at step 5; `""` when none).
- [ ] Failure is non-fatal (`catch |err| log.warn`, same pattern as the HTTP handler's `llm_history insert failed (non-fatal)`).
- [ ] Re-run Task 3 test → passes.
- [ ] Run `zig build test --summary all`.
- [ ] Commit: `fix: create_kanban_task seeds initial llm_history user message`

## Task 5 — Emit session_created SSE + update docs/tests

- [ ] After the existing `onEventSendKanbanTask(action="created")` (step 12), add `onEventSendSessions(action="created", id=task_id, name=trimmed_name, status="active", cwd=validated_cwd, profile, normalized_flag)` mirroring `kanban_tasks_create.zig:362-376`; non-fatal on error.
- [ ] Grep `session_created` / `action="created"` across `on_event_sent*.zig` + `src/apps/desktop/src/api/index.ts` (`additionalEventTypes` + dispatch chain) to confirm the SSE pair contract is intact; add the frontend registration only if missing.
- [ ] Update the tool file header doc comment (lines 1-25) flow steps: step 11 → "always INSERT sessions (HTTP create_session parity)", new step for llm_history seed + session_created SSE; update the `is_auto_retry_until_stop` / `selected_profile_model` field docs that currently say "When set, a sessions row is created" → "sessions row is always created; this flag/profile only sets its columns".
- [ ] Add a static-contract test asserting the source contains `INSERT OR IGNORE INTO sessions (id, name, status, cwd,` + `INSERT INTO llm_history` + `onEventSendSessions` (same `readSource` + `contains` pattern as the existing tool-definition tests at line 758+).
- [ ] Run `zig build test --summary all`.
- [ ] Commit: `feat: create_kanban_task emits session_created SSE`

## Task 6 — Functional verification (wire-level, harness only)

- [ ] Create `tests/functional/agent_create_kanban_task_session_test.py` following `tests/functional/kanban_task_get_test.py` harness pattern: boot isolated HOME + free port (never 8081), create workspace → kanban item → task via the agent-tool-equivalent HTTP `create_session` path, then assert: (a) `GET sessions` row exists with `name == card title`, (b) `GET llm_history` contains the user row `{name}\n\n{description}`, (c) plain create with no flag/profile still yields both rows (the regression this plan fixes).
- [ ] Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/agent_create_kanban_task_session_test.py -v` → all pass.
- [ ] Run `zig build test --summary all` one final time.
- [ ] Commit: `test: functional coverage for agent create_kanban_task session seeding`

## Verification (plan author checklist)

- [ ] Plan saved to `docs/superpowers/plans/2026-09-09-fix-agent-create-kanban-task-session.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins

## Pitfalls

- **Don't copy `task_create.zig`'s conditional sessions INSERT** — that older path only fires on the unattended flag. The reference is `kanban_tasks_create.zig` `create_session` (unconditional).
- **Don't use bare `INSERT INTO sessions`** — concurrent chat-spawn races on `task.id == session.id`; `OR IGNORE` is load-bearing.
- **Don't bind `""` where HTTP binds `CURRENT_TIMESTAMP`** — `created_at/updated_at` must be SQL timestamps, not empty strings (empty-slice-binds-as-NULL quirk breaks NOT NULL columns).
- **Don't forget `model=''` literal in the llm_history INSERT** — omitting it violates NOT NULL; binding `""` collapses to NULL in `SqliteBackend.exec`.
- **Don't emit the SSE before both INSERTs succeed-or-warn** — order is sessions → llm_history → `session_created` SSE → existing `kanban_task created` SSE, matching HTTP.
