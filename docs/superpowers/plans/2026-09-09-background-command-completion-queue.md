# Background Command Completion → Queue Message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a `command` tool background process finishes, its log output is auto-queued as a user-role message so the agent + chat see it without manual `cat`.

**Architecture:** Hook the existing per-minute `cleanup_stale_background_process` cron (the live path — `src/main.zig:615`): before DELETE-ing a dead PID row, read its log file, build the `"""""` envelope, `insertQueueMessage`, emit SSE, then DELETE (once-only). If no worker is running on that session, wake one via `emit_run_agent(skip_initial_queue_message=true)` so the queue drains.

**Tech Stack:** Zig 0.16, SQLite (`session_background_process`, `session_queue_messages`), `insertQueueMessage` (`src/ai_workflow/tui/agentic_loop/insert_queue_message.zig`), `helpers.process_status.isProcessRunning`, existing cron `src/schedulers/cleanup_stale_background_process.zig`.

## Global Constraints

- No new migration / schema change (reuse `session_background_process(session_id,pid,command,log_path,started_at,status)` + `session_queue_messages`). If a `notified` flag is needed, do it in code (DELETE-after-notify), not a new column.
- Per-request arena rule: handler/cron code allocates via passed allocator, no `defer free` for arena memory; `rows.deinit()` still required.
- SSE contract: any new `event_type` name must be added in 3 places (backend emitter + `additionalEventTypes` + dispatch chain in `src/apps/desktop/src/api/index.ts`) — but v1 should reuse existing `queue_queued` event, no new event name.
- Windows: `spawn_background` is `nohup` idiom (POSIX). Keep behavior unchanged on Windows; completion path is platform-agnostic (reads log file only).
- Functional verification via isolated harness (`tests/functional/harness.py`, never live 8081 server + curl). Zig unit via `zig build test --summary all`.
- DONT KILL PORT 8081 server; functional tests use free port 8080..8199.

## File Map

| File | Change |
|---|---|
| `src/schedulers/cleanup_stale_background_process.zig` | Core: extend SELECT to include `command,log_path`; add `notifyCompletedBackgroundProcesses` step (read log → build envelope → `insertQueueMessage` with SSE → wake worker → DELETE). |
| `src/ai_workflow/tui/agentic_loop/background_process.zig` | Optional helper: `buildCompletionMessage(command,pid,log_content)` pure fn + `readLogTruncated(path, cap)` helper so logic is unit-testable without DB. |
| `src/ai_workflow/tui/agentic_loop/insert_queue_message.zig` | No change (reuse). Verify `is_emit_sse=true` + `event_bus` path works from cron context (di.event_bus). |
| `src/root.zig` (`emit_run_agent`) | No change (reuse `skip_initial_queue_message=true` wake-up, same as kanban Start-agent button). |
| `src/apps/desktop/src/api/index.ts` | No change if reusing `queue_queued` event (verify frontend already listens — it does for normal queue). |
| `tests/functional/background_command_completion_test.py` | NEW: end-to-end (seed row + dead PID + fake log → run tick → assert queue row + SSE-able + envelope shape). |
| `docs/superpowers/plans/2026-09-09-background-command-completion-queue.md` | This plan. |

## Message Envelope (v1 contract)

```
This is an output from background command (pid 12345, command `timeout 10 make test`):
"""""
<log file content, truncated to 20 KiB + "... [truncated N bytes]" suffix>
"""""
```

- `session_queue_messages` has no role column — drained rows are treated as user role by `llm_history.zig:3043` (`SELECT message, image_url ... ORDER BY created_at ASC`). So "as role user" = plain `insertQueueMessage` with this body, `image_url=""`, `is_emit_sse=true`.
- Empty log → body still queued with `(empty output)` marker so agent knows it finished.
- Missing log file → queue with `(log file not found: /tmp/bg_xxx.log)` marker, still DELETE row (don't retry forever).

## Wake-up Semantics (critical — queue alone is not enough)

- If a worker IS running on the session, the workflow loop already drains queue (`workflow.zig:1255-1262` `hasQueuedMessages → continue`). Queue + SSE is sufficient.
- If NO worker is running (common: background job outlives the agent run), queue rows sit idle until the next user message. So after a successful `insertQueueMessage`, check `isWorkerRunning(db, session_id)` (+ `ActiveLoops.contains` where available); if idle, call `di.emit_run_agent({session_id, queue_message="", skip_initial_queue_message=true, ...})` — the Start-agent pattern — so the run starts and drains the just-queued output without injecting a duplicate user message.
- Failure to wake = silent feature (row queued but chat never reacts). This is the #1 acceptance criterion.

## Edge Cases

1. Long output: cap at 20 KiB (match `command.max_output` default), append `\n... [truncated N bytes, full log at /tmp/bg_xxx.log]`.
2. Binary log content: reuse `result_to_xml` escaping path or base64-guard — at minimum strip NULs so `session_queue_messages.message` INSERT never breaks SSE JSON.
3. Rapid multi-completion: one queue row per (session_id,pid); batch loop, per-row isolation (one bad log read must not abort the tick).
4. Log file deleted before tick: notify with not-found marker, DELETE row.
5. `insertQueueMessage` fails: do NOT DELETE that row (retry next minute tick); log via `logger.errFmt`, continue to next pair.
6. Cron runs every minute — completion latency ≤60s is accepted v1 (document in chat message? No — keep envelope clean).

## Tasks

### Task 1 — Pure helper + failing tests (no DB, no cron)

- [ ] Write failing test in `background_process.zig` (or new `background_completion.zig` if cleaner): `buildCompletionMessage("timeout 10 make test", 12345, "ok\n")` returns exact envelope with `"""""` fences.
- [ ] Run it, confirm it fails (no fn yet).
- [ ] Implement `buildCompletionMessage(allocator, command, pid, log_content_truncated)` minimal (allocPrint envelope).
- [ ] Write failing test for `readLogTruncated`: missing file → error/not-found marker; 100KB file → 20KiB + truncation suffix; NUL bytes stripped.
- [ ] Implement `readLogTruncated` minimal (`std.fs.cwd().readFileAlloc` capped, or streaming read).
- [ ] Run `zig build test --summary all`, confirm new tests pass.
- [ ] Commit.

### Task 2 — Cron notify-then-delete (the core)

- [ ] Extend `cleanupStaleBackgroundProcesses` SELECT from `SELECT session_id, pid` to `SELECT session_id, pid, command, log_path` (keep `status` ignored per existing spec).
- [ ] Write failing test (use `setupCtx` + `seedRow` pattern already in file): seed dead-PID row with real temp log file, run helper, assert (a) `session_queue_messages` has 1 row with `"""""` envelope, (b) `session_background_process` row deleted.
- [ ] Implement: in pass-1 dead-collection keep `command,log_path` copies; new pass-1.5 `notifyDead()` before pass-2 DELETE: for each dead pair → `readLogTruncated` → `buildCompletionMessage` → `insertQueueMessage({db, session_id, message, image_url="", event_bus=di.event_bus (nullable in helper — pass through input), is_emit_sse=true})`. On insert error: log + skip DELETE for that pair (remove from dead list).
- [ ] Wire `handle()` to pass `di.event_bus` (check `ContextIPCTui` fields — `insertQueueMessage` takes `?*EventBus`; null is safe no-op for SSE branch per existing test).
- [ ] Run `zig build test --summary all`.
- [ ] Commit.

### Task 3 — Wake idle worker

- [ ] Write failing test (static-contract or integration): after notify, idle session gets `emit_run_agent(skip_initial_queue_message=true)` call. Simplest testable seam: helper returns `notified_session_ids[]` and a separate `wakeIfIdle()` fn that checks `isWorkerRunning`; test `wakeIfIdle` with mocked/no-worker DB asserts it attempts emit (or at minimum assert helper exposes the list so `handle()` can loop).
- [ ] Implement in `handle()`: for each notified session_id, `if (!isWorkerRunning(db, sid)) di.emit_run_agent({session_id=sid, queue_message="", skip_initial_queue_message=true, ...minimal required fields...})` catch + log (never crash tick).
- [ ] Verify against `root.zig:EmitRunAgentInput` required fields (session_id, queue_message, cwd?, etc.) — follow kanban Start-agent call site as reference.
- [ ] Run `zig build test --summary all`.
- [ ] Commit.

### Task 4 — Functional end-to-end (wire proof)

- [ ] Write `tests/functional/background_command_completion_test.py` (harness pattern): create session, INSERT `session_background_process` row with dead PID (e.g. 999999999) + real log file content, trigger tick (call the cron tick via API or wait ≤70s? Prefer direct: invoke the same code path the cron runs — if no HTTP trigger exists, seed + sleep 70s + assert `GET /api/llm/session/:id/queue_messages` contains envelope; keep timeout generous).
- [ ] Run `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/background_command_completion_test.py -v`, confirm green.
- [ ] Run full `zig build test --summary all` once more.
- [ ] Commit.

### Task 5 — Docs + SSE verification

- [ ] Grep new strings: envelope marker + `queue_queued` appear in backend emitter + `additionalEventTypes` + dispatch chain (no new event name needed — verify reuse).
- [ ] Update `PABRIK.md` changelog (one entry, same style as prior entries).
- [ ] Verify plan checklist from writing-plans skill (header, bite-sized, commits per task).
- [ ] Final `zig build test --summary all` + `zig build pabrik-desktop --summary all` (21/21 steps).

## Out of Scope (v2)

- Streaming progress (tail log while running) — v1 is completion-only.
- Exit-code capture (POSIX `nohup ... &` loses it; would need wrapper script writing `.exit` sidecar).
- Per-session background process UI panel (frontend `getSessionProcesses` exists in `Cronjob.zig:170` but no desktop component reads it).
- `notify_on_complete` OS notification reuse — keep to chat queue only in v1.
- Windows `Start-Process` background (TODO D8 in `shell.zig:724`) — untouched.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-09-background-command-completion-queue.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
