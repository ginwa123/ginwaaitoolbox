# Spawn sub-agent silent failure — investigation + fix plan (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `spawn_sub_agent` failures visible in the ChatView card instead of stranding rows at `running` / `starting…` forever (screenshot: `spawn_sub_agent 2 sub-agents / 2 running`, `audit-render … 0s running`, `audit-io … 0s running`, no error ever appears).

**Architecture:** Four small fixes, no new tables, no new routes.
1. Enforce the already-parsed `timeout_seconds` per sub-agent thread so a hung child cannot hold `group.await` forever.
2. Make the `failed` progress emit lossless-or-loud (retry + error log) so a lost emit cannot strand a row at `running`.
3. Surface pre-thread failures (parse / dispatch) as a failed card row instead of a bare `starting…` placeholder.
4. Stop the silent `random_fallback` for unknown `agent_name` (or at minimum badge it loudly in the envelope + log).

**Tech Stack:** Zig 0.16 (`ToolExecContext`, `std.Io.Group`, `wrapToolOutput`), Vue 3 (`SpawnSubAgent.vue`, `subagentProgress.ts`, `ChatView.vue`), SQLite (no migration needed), python functional harness.

## Global Constraints

- **Never touch the process on port 8081.** Functional tests use the harness's random port (8080..8199 minus 8081).
- For HTTP/wire verification use the python functional harness (`tests/functional/harness.py` + isolated tmpdir HOME), never `nohup ./zig-out/bin/nalar… + curl`.
- Empty-slice-binds-as-NULL: `SqliteBackend.exec` binds `""` as NULL — do not write `""` into NOT NULL columns on the fix path.
- No `// NEW (plan: …)` comments in source.
- Cross-platform check for Zig changes (`zig build` on Linux + compile-only cross-check per `zig-cross-platform-verification` skill).
- `vue-tsc --build` emits stray `.js` next to `.ts` — delete before committing.
- Verification gates: `zig build test --summary all`, `(cd src/apps/desktop && pnpm test:unit)`, `bun run build`, `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v` (rebuild with `zig build install:linux` first).

## Current State (verified 2026-09-13 via 3 parallel explorers + first-hand reads)

| # | Fact | Path:line |
|---|---|---|
| 1 | `timeout_seconds` is parsed (`?u32`, `0 = no timeout`) but **never referenced in exec** — zero hits in `src/agentic_loop`, only parse side mentions it | `src/modules/agent/tools/spawn_sub_agent.zig:12,27,72,144,302-306,345` |
| 2 | `runSubAgent` is `fn … void` by design ("must NOT return error union … handle internally"), per-agent failures go to `shared_results.results[idx].{success=false, error_message}` and aggregate into `<results><agent success="false"><error>…` with **top-level `success=true`** (`wrapToolOutput(..., true, ...)`) — parent LLM must parse XML to see failures | `src/agentic_loop/tools_exec_spawn_sub_agent.zig:102-106,576-604,616` |
| 3 | Every error branch sets `error_message` + emits `failed` progress + `logger.errFmt`, then `return`. Success emits `completed` only on non-empty response; empty/no-message emits `failed` via `failSubAgentAlreadySet` | `src/agentic_loop/tools_exec_spawn_sub_agent.zig:141-172,202-213,219-230,292-337,341-367,391-401,369-385` |
| 4 | Progress emitter is **fire-and-forget by design** ("never propagated"): arena/dupe/singleton failures warn-and-return, snapshot upsert swallows (`getOrPut/dupe/append catch return`, empty `tool_call_id` guard) | `src/agentic_loop/subagent_progress.zig:187-189,203-276,326-341,351,365-380` |
| 5 | Concurrency is `group.concurrent(ctx.io, runSubAgent, …)` + `try group.await(ctx.io)` with **no per-task deadline**; `await` failure propagates as dispatch-level error, success path clears snapshot | `src/agentic_loop/tools_exec_spawn_sub_agent.zig:563,568,417,623` |
| 6 | Parse failure returns `error.InvalidArguments` **before any thread/`launched` emit** (with `errdefer clearSnapshot`); card stays `isStarting` with zero live rows, error only in generic tool-result envelope | `src/agentic_loop/tools_exec_spawn_sub_agent.zig:418-421`, `src/agentic_loop/handle_tool.zig:623-634` |
| 7 | Unknown `agent_name` does **not error** — resolves to random name + orchestrator defaults with only a server-side `warnFmt`; frontend gets `random_fallback="true"` attr | `src/agentic_loop/tools_exec_spawn_sub_agent.zig:503-527`, `src/modules/agent/tools/spawn_sub_agent.zig` resolve path |
| 8 | Frontend card parses final envelope (`<agent>` regex, `<summary succeeded= failed= />`), live mode = `progress.length>0 && agents.length==0`, `liveSummary{running,done,failed}`; final envelope wins, `clearProgressFor` drops live rows on landing `tool/full` | `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue:50-92,148-161`, `src/apps/desktop/src/components/views/ChatView.vue:2334-2344,2463-2473,3256-3264` |
| 9 | Status mapping: backend `{launched,completed,failed}` → frontend `{running,done,failed}` (`completed→done, failed→failed, else running`); reducer never downgrades `done→running`, ignores events missing `role/tool_call_id/status/agent_index` | `src/agentic_loop/subagent_progress.zig:54-66`, `src/apps/desktop/src/helpers/subagentProgress.ts:37,40,159-170,131-137` |
| 10 | Lifecycle: placeholder `starting…` (Phase-1 empty `<data>`, no `<summary>`) → `launched→running` (sid `subagent_<ns>_<slug>`) → `completed→done` / `failed` → envelope wins; refresh rehydrates via `GET /subagent/progress/:id` snapshot, server restart wipes map → `starting…` | `src/agentic_loop/handle_tool.zig:537-550`, `src/agentic_loop/tools_exec_spawn_sub_agent.zig:196-245`, `src/apps/desktop/src/components/views/ChatView.vue:1335-1359`, `src/http_handlers/subagent_progress_get.zig` |
| 11 | No TUI renderer for sub-agent status — Vue path only (`src/ai_workflow/tui` has no subagent/progress matches) | `src/ai_workflow/tui/routines/*` (unrelated `last_status='running'`) |
| 12 | Screenshot decode: `starting… starting` = placeholder, no live rows yet; `2 sub-agents 2 running` = `liveSummary{running:2}`; `audit-render subagent_178930… 0s running` = `SubAgentProgress{name,sessionId,elapsedMs,status:'running'}` rows frozen at 0s (no `completed`/`failed` ever arrived) | screenshot + facts 9–10 |

### Root-cause ranking (most → least likely for the screenshot)

1. **Hung child + no timeout (fact 1+5).** `timeout_seconds` is advertised in the tool schema but unenforced; a child stuck in `runAgenticMultiStepnew` (LLM stall / retry loop `workflow.zig:870,935-939`) holds `group.await` forever. No final envelope, no `failed` emit, rows frozen at `running` with `0s` (elapsed only sent at emit time, no ticker). Matches the screenshot exactly.
2. **Lost `failed` emit (fact 4).** Even when the thread does fail, the emit is best-effort; a failed `failed` emit strands the row at `running` with only a server log. Same visible symptom, shorter hang.
3. **Silent random fallback (fact 7).** `audit-render` / `audit-io` look like LLM-invented names; if absent from `LlmConfig.sub_agents` they silently run with orchestrator defaults instead of erroring — user perceives "no error shown" when the real surprise is "no error raised".
4. **Pre-thread parse failure (fact 6).** Would strand at `starting…`, not `running` — less likely for this screenshot (rows already show `running`), but the same "no error in card" complaint for bad `tools` allowlists.

Note: the "truncated `SpawnSubAgent.vue`" alarm from one explorer is a **false positive** — `read_file` output breaks on the `<data></data>` literal inside a comment at line 166; `sed -n '160,220p'` and `git show HEAD:… | wc -l` (513 lines, clean `git status`) confirm the file is intact.

## Design Decisions (for reviewer)

1. **Enforce timeout at the spawn layer, not inside the child loop.** The child already has retry caps (`retry_count > 10`, `TooManyRetries`); the missing piece is a parent-side deadline that converts "hung" into a `failed` row + `<error>timeout after Ns</error>`. Rejected: adding a ticker SSE — churn without fixing the hang.
2. **Keep `runSubAgent void` + shared-results, add deadline as early-exit.** `group.await` semantics stay; each thread checks its own deadline (monotonic `thread_start_ns` already captured) and bails via the existing `failSubAgent` helper. Rejected: switching to cancellable `async` — deadlock risk noted in code comments (`:472-473`).
3. **Make `failed` emit loud, not infallible.** Keep fire-and-forget signature (dozens of call sites) but add retry-once + `errFmt` with `tool_call_id`/`agent_index` so a lost emit is greppable. Rejected: returning errors from emit — would force every branch to handle a second failure mode.
4. **Pre-thread failures become a failed envelope the card can render, not just a generic tool error.** Include a `<results><summary succeeded="0" failed="N"/>` shape (or keep `InvalidArguments` but attach the specific reason string instead of collapsing to the generic name). Rejected: emitting fake `launched` rows — lies about what ran.
5. **Unknown `agent_name` stays fallback-by-default (config-driven feature) but must be unmissable.** Keep `random_fallback="true"` + warn, and ensure the card renders the "random" badge + the envelope `<error>`-adjacent note. Rejected: hard error — breaks the documented fallback contract (`spawn_sub_agent.zig` schema + `5984ab32`).

## Wire Contract

No DDL change. No new route. Envelope stays:

```xml
<results>
<agent name="..." success="true|false" random_fallback="true|false">
<session_id>...</session_id>
<response>...</response> | <error>...</error>
</agent>
<summary succeeded="N" failed="M" />
</results>
```

New strings the implementer must emit verbatim:
- Timeout per-agent error: `timeout after {N}s (timeout_seconds={N})` inside `<error>`, plus `failed` progress with the same `elapsed_ms`.
- Parse failure envelope: preserve the specific reason (`MissingSubAgentTools` / `EmptySubAgentTools` / `AllToolsNotAllowed` / `AgentNameTooLong`) in the tool-result message instead of bare `InvalidArguments`.
- Progress events unchanged: `{role:"subagent_progress", tool_call_id, agent_index, total_agents, agent_name, status:"launched|completed|failed", subagent_session_id, elapsed_ms}`.

## File Map

| Action | File | Responsibility |
|---|---|---|
| Edit | `src/agentic_loop/tools_exec_spawn_sub_agent.zig` | Thread `timeout_seconds` into `SubAgentThreadArgs`, deadline check + bail via `failSubAgent`, timeout `<error>` text |
| Edit | `src/modules/agent/tools/spawn_sub_agent.zig` | Expose parsed `timeout_seconds` per agent to exec (already parsed; verify field reaches `SubAgentThreadArgs`) |
| Edit | `src/agentic_loop/subagent_progress.zig` | Retry-once + loud `errFmt` on emit/snapshot failure (keep `void` signature) |
| Edit | `src/agentic_loop/handle_tool.zig` | Preserve specific parse-failure reason in tool-result message; keep placeholder SSE |
| Edit | `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` | Render timeout `<error>` + `random_fallback` badge (verify existing paths cover new strings) |
| Add | `tests/functional/spawn_subagent_timeout_test.py` | Harness test: tiny `timeout_seconds`, hung child → `failed` row + envelope `<error>timeout` (never port 8081) |
| Add | `src/agentic_loop/tools_exec_spawn_sub_agent.zig` (inline tests) | Static-contract: timeout field threaded, `failed` emit present on timeout branch |

## Tasks

- [ ] 1. Thread `timeout_seconds` into exec + deadline bail with `failed` emit and `<error>timeout after Ns</error>`. Commit: `fix(spawn): enforce timeout_seconds per sub-agent`
- [ ] 2. Loud `failed` emit (retry-once + `errFmt` with ids) and snapshot-upsert error log. Commit: `fix(spawn): loud failed progress emit`
- [ ] 3. Preserve specific parse-failure reason in tool-result message (no bare `InvalidArguments`). Commit: `fix(spawn): specific parse error reason`
- [ ] 4. Verify `random_fallback` badge renders + warn is greppable; add envelope note if missing. Commit: `fix(spawn): visible random fallback`
- [ ] 5. Functional harness test (timeout → failed row + envelope) + inline static-contract tests. Commit: `test(spawn): timeout + failed-emit coverage`
- [ ] 6. Run gates: `zig build test --summary all`, `pnpm test:unit`, `bun run build`, functional test with fresh `NALAR_BIN`. Commit: `chore(spawn): gate results`

## Verification

- `zig build test --summary all` (backend, incl. new inline contract tests).
- `(cd src/apps/desktop && pnpm test:unit)` + `bun run build` (card still renders; no stray `.js` committed).
- `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/spawn_subagent_timeout_test.py -v` — asserts `failed` row + `<error>timeout` envelope on a hung child with tiny timeout.
- Manual: spawn 2 sub-agents with `timeout_seconds: 5` and a stalled child; card flips `running → failed` with the timeout message instead of freezing at `0s running`.
- No-regression: normal 2-agent success still shows `done` + `<summary succeeded="2" failed="0" />`; refresh mid-run still rehydrates via snapshot.

## Out of Scope

- Live elapsed ticker (would fix the frozen `0s` cosmetic but not the hang).
- Cancel/kill button for running sub-agents.
- Changing the `void` + shared-results concurrency model.
- TUI sub-agent status UI (does not exist; Vue only).
- Hard-erroring unknown `agent_name` (breaks fallback contract).

## Open Questions for the reviewer

1. Default timeout: keep `null/0 = no timeout` (schema promise) or set a sane default (e.g. 300s) so every spawn is bounded?
2. Should the timeout kill only the child thread's wait or also cancel its LLM request (deeper plumbing)?
3. Is the `random_fallback` silent-default acceptable, or should unknown names warn in the card header, not just a badge?

## Risks

- Deadline check placement: too coarse (only at loop top) still hangs inside one long LLM call; may need a check around `runAgenticMultiStepnew` with an allocator-safe bail.
- Loud-emit retry adds latency on the failure path; keep to retry-once to avoid cascading slowness.
- Changing the parse-error message text may break exact-match frontend regexes — keep `<summary>` shape stable and only enrich the human message.

## Plan saved checklist

- [x] Plan doc exists in the worktree at `docs/superpowers/plans/2026-09-13-spawn-sub-agent-error-silent.md`
- [x] Commit + push + PR opened (docs-only; pre-push hook does not run in worktree — say so in PR body)
- [x] Kanban card moved to `in_review_planning`
- [ ] User reviewed before execution
