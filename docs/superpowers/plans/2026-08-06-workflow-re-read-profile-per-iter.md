# Plan — workflow loop re-reads `selected_profile_model` per iteration

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-06
**Branch:** `worktree/workflow-re-read-profile`
**Bug report:** task `task_1786031708725` (kanban: "profile select")
**User quote (verbatim):** *"Profile change should pick up the NEW profile on the running loop's NEXT iteration, that mean if i select profile no need queue message to workflow agentick just re read selected_profile_model"*

## TL;DR

The workflow's `while (true)` loop in `workflow.zig::runAgenticMultiStepnew` uses a **snapshot** of `selected_profile_model` taken at the top of the run (`workflow.zig:419` — `copy_selected_profile_model = parent_allocator.dupe(u8, params.selected_profile_model)`). It does NOT re-read from the DB on each iteration.

So when the user picks a different profile in the chatview dropdown mid-run:

1. The PUT to `/api/llm/session/:id` succeeds
2. The DB row `sessions.selected_profile_model` is updated
3. **The running workflow loop continues to use the snapshot** — the new profile is silently ignored
4. Only the NEXT message sent after the change picks up the new profile (because `POST /api/llm/session` reads `selected_profile_model` from the request body)

The fix: mirror the existing `is_auto_retry_until_stop` re-read pattern (`workflow.zig:543-552`) for `selected_profile_model`. Re-read it from the DB at the top of every loop iteration, so the next LLM call (and any sub-agents spawned via `handle_tool`) picks up the new profile without queueing a new message.

The frontend (`ChatView.vue::selectProfile`) is **NOT touched** — the existing PUT + chip update + SSE broadcast path stays (that path is correct; the problem is purely on the read side).

## Investigation findings

### Current snapshot pattern (the bug)

`workflow.zig:419` (one-time, top of run):

```zig
const copy_selected_profile_model = try parent_allocator.dupe(u8, params.selected_profile_model);
```

`workflow.zig:569-577` (every iteration, but uses the snapshot):

```zig
if (params.selected_profile_model.len > 0 and
    config.getProfile(params.selected_profile_model) == null)
{
    logger.warnFmt("WORKFLOW: selected_profile_model '{s}' not found in LlmConfig.profiles_models, using top-level config", .{params.selected_profile_model});
}
effective_api_key = resolveProfileField("api_key", config, params.selected_profile_model, config.active_profile, config.api_key);
effective_model = resolveProfileField("model", config, params.selected_profile_model, config.active_profile, config.model);
effective_base_url = resolveProfileField("base_url", config, params.selected_profile_model, config.active_profile, config.base_url);
effective_url_style = resolveProfileField("url_style", config, params.selected_profile_model, config.active_profile, config.url_style);
```

`workflow.zig:1076` (passes the snapshot to `handle_tool` — sub-agents spawned mid-run use the snapshot, not the live value):

```zig
try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, effective_model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, active_loops, copy_selected_profile_model);
```

### Existing live-re-read pattern we mirror

`workflow.zig:543-552` already re-reads `is_auto_retry_until_stop` per iteration (so the user can toggle unattended mode mid-run and have it take effect on the next iteration):

```zig
const is_auto_retry_until_stop: bool = blk: {
    var flag_rows = db.query(allocator, "SELECT COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?", &.{copy_session_id}) catch break :blk false;
    defer flag_rows.deinit();
    const flag_row = flag_rows.next() catch break :blk false;
    if (flag_row) |row| {
        defer row.deinit(allocator);
        break :blk std.mem.eql(u8, row.values[0], "1");
    }
    break :blk false;
};
```

We do the same for `selected_profile_model`: a `blk: { ... }` that re-reads from the DB and falls back to `params.selected_profile_model` on read failure.

### Where the live value flows

1. **The next LLM call** (`workflow.zig:574-577` → `effective_*` vars used at line 917 for `callDynamicAgentNew`). Picking a new profile → next LLM call uses the new profile's `api_key`, `model`, `base_url`, `url_style`.
2. **Sub-agents spawned via `handle_tool`** (`workflow.zig:1076` → `handle_tool` → `tools_exec_*.zig` → `spawn_sub_agent.zig` → `RunParamsNew.selected_profile_model`). Picking a new profile → sub-agents spawned in the next iteration use the new profile.
3. **The warning log** at `workflow.zig:572`: prints the (now-live) profile name; if the user deletes a profile while the loop is running, the warning fires on the next iteration.

### Cycle of re-read

The re-read happens once per iteration, just before the `resolveProfileField` calls. The DB query is cheap (single-row indexed PK lookup on `sessions.id`). Already the pattern exists for `is_auto_retry_until_stop` — proven-cheap.

### What the user wants (verbatim)

> "Profile change should pick up the NEW profile on the running loop's NEXT iteration, that mean if i select profile no need queue message to workflow agentick just re read selected_profile_model"

So the user wants:
- Pick profile → next iteration of the while-loop uses the new profile
- No need to queue a new message just to apply the profile change
- The workflow agent should detect the DB change without a message

This is exactly what re-reading from the DB per iteration achieves.

## Architecture

### Single change in `workflow.zig`

1. **Add a new variable** `live_selected_profile_model: []const u8` scoped to the loop body, computed at the top of each iteration alongside the existing `is_auto_retry_until_stop` re-read.
2. **Replace `params.selected_profile_model`** with `live_selected_profile_model` in:
   - Line 569-572 (the "not found" warning check)
   - Line 574-577 (the `resolveProfileField(...)` calls)
3. **Pass the live value to `handle_tool`** at line 1076 (so sub-agents spawned mid-run use the new profile).
4. **Keep `copy_selected_profile_model`** (the snapshot) for backwards-compatibility / as a fallback when the DB read fails.

### Lifecycle of `live_selected_profile_model`

| Iteration | Action | Value |
|---|---|---|
| 1 | Re-read from DB | What the user picked before sending the first message (`params.selected_profile_model` usually) |
| 2 | Re-read from DB | What the user picked AFTER message 1 (if any) |
| N | Re-read from DB | Current value of `sessions.selected_profile_model` |

If the DB read fails (query throws, no row), fall back to `params.selected_profile_model` (the snapshot). This preserves the existing behavior on read failure.

### What stays unchanged

- `ChatView.vue::selectProfile` — the PUT / chip update / SSE broadcast path is correct (the user wants the DB to update so the workflow can pick it up).
- `session_update.zig::sessionUpdateHandler` — the PUT endpoint stays (used by NalarSettings "Set active" + KanbanTaskDetailDialog edit).
- `llm_history.zig::updateSessionSelectedProfileModel` — the backend update + SSE broadcast stays.
- `RequestSession.selected_profile_model` field in `POST /api/llm/session` — the new-message-send path stays.
- `workflow.zig::resolveProfileField` — the cascade logic stays; we just feed it a live value instead of a snapshot.

### Behavioural matrix

| Scenario | Result |
|---|---|
| User picks profile "X" before any message | DB has "X". Worker starts. Loop re-reads "X" each iteration. Pulls profile "X" from LlmConfig. ✅ |
| User picks "Y" mid-run (running with "X") | DB updates to "Y". Next iteration re-reads "Y". Next LLM call uses "Y" profile's api_key/model/base_url. ✅ |
| User picks "Y" mid-run, then picks "Z" before the next iteration | DB updates to "Z". Next iteration re-reads "Z". Next LLM call uses "Z". ✅ (rapid picks collapse to the latest value) |
| User clears selected_profile_model to "" (back to "Default") | DB has "". Next iteration re-reads "". Loop falls through to `config.active_profile` → top-level. ✅ |
| DB read fails (transient SQLite error) | Fall back to `params.selected_profile_model` (snapshot). Loop continues with the old profile. Next iteration retries. **Documented graceful-degrade.** |
| User picks a profile name that doesn't exist in `LlmConfig.profiles_models` | The warning at line 569-572 fires on the next iteration (`WORKFLOW: selected_profile_model 'Y' not found ...`). Loop falls through to `config.active_profile` → top-level. Same behaviour as today for missing profiles. |
| SPA workflow: spawn sub-agent mid-run after picking "Y" | `handle_tool` receives `live_selected_profile_model = "Y"`. Sub-agent's `RunParamsNew.selected_profile_model = "Y"`. Sub-agent uses "Y"'s profile from its first LLM call. ✅ |

## Global Constraints

- **Frontend untouched.** No Vue/TS changes. The existing `selectProfile` path is correct.
- **No backend HTTP changes.** PUT endpoint + SSE broadcast stay.
- **No migration.** No DB schema change.
- **No wire shape change.** The `selected_profile_model` field on `RequestSession`, `RunParamsNew`, `sessions` table all stay as-is.
- **Cross-platform parity.** Pure Zig change — Linux/macOS/Windows compile + test must all pass.

## Task 1: Write the failing test

**File:** `src/ai_workflow/tui/agentic_loop/workflow_re_read_profile_test.zig` (NEW)

**Steps:**

- [ ] Create the new test file. Test setup follows the pattern used in `workflow.zig:289-...` (the inline `resolveProfileField` tests) — a fresh `:memory:` DB, a `LlmConfig` with a `profiles_models` map, no worker/loop needed for the field-cascade test.
- [ ] Write test 1: **`live_selected_profile_model` falls back to `params.selected_profile_model` when DB read fails.** Mock the DB to throw on `SELECT ... FROM sessions WHERE id = ?`. Assert the resolver sees `params.selected_profile_model`.
- [ ] Write test 2: **`live_selected_profile_model` matches the DB value when DB read succeeds.** Insert a session with `selected_profile_model = 'beta'`. Run the resolver. Assert the resolved `model` is `beta-model` (from profile `beta` in `LlmConfig.profiles_models`).
- [ ] Write test 3: **rapid UPDATE on the session row is picked up by the next iteration.** Mock TWO sequential DB reads returning two different values. Assert the resolver sees the second value on the second read.
- [ ] Register the test in `src/ai_workflow/tui/test_runner.zig` with `_ = @import("workflow_re_read_profile_test.zig");`.
- [ ] Run `timeout 180 zig build test --summary all` — expect the 3 new tests to FAIL (because the feature doesn't exist yet).

## Task 2: Implement the re-read in `workflow.zig`

**File:** `src/ai_workflow/tui/agentic_loop/workflow.zig`

**Steps:**

- [ ] After the `is_auto_retry_until_stop` re-read block at line 543-552, add a new `live_selected_profile_model: []const u8` block that re-reads `COALESCE(selected_profile_model, '')` from `sessions` for `copy_session_id`. On any failure (query throws, no row), fall back to `params.selected_profile_model`. The returned slice is borrowed from the `arenaAllocatorWhileLoop` (the per-iteration arena) — safe for the rest of the iteration because the arena is re-initialized every iteration.
- [ ] Replace `params.selected_profile_model` with `live_selected_profile_model` on lines 569-572 (the warning check) and 574-577 (the `resolveProfileField(...)` calls).
- [ ] At line 1076, replace `copy_selected_profile_model` with `live_selected_profile_model` (the per-iteration live value). Keep `copy_selected_profile_model` allocated for the lifetime of the run (still used as a fallback).
- [ ] Run `timeout 180 zig build test --summary all` — expect the 3 new tests to PASS. Existing tests should still pass (no regressions).

## Task 3: Add a regression test for the handle_tool propagation

**File:** `src/ai_workflow/tui/agentic_loop/workflow_re_read_profile_test.zig` (extend)

**Steps:**

- [ ] Write test 4: **`handle_tool` receives the live `selected_profile_model` on each iteration.** Mock the DB to return 'beta' on iteration 1's re-read and 'gamma' on iteration 2's re-read. Assert that the second call to `handle_tool` passes 'gamma' as the `selected_profile_model` param (use a mock that captures the latest call's args).
- [ ] Run `timeout 180 zig build test --summary all` — expect all 4 tests to pass.

## Task 4: Verify cross-compile + build

**Steps:**

- [ ] `timeout 180 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` — expect clean.
- [ ] `timeout 180 zig build-obj -fno-emit-bin -target aarch64-macos -lc --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig` — expect clean.
- [ ] `timeout 240 rm -rf zig-out/bin && zig build` — expect all 3 binaries produced (`nalar`, `nalarcore-linux-x86_64`, `nalar-desktop`, `nalarcli`).

## Task 5: Live smoke (manual)

**Steps:**

- [ ] Restart the user's `nalar` on port 8082 (don't kill 8081 — that's the user's running instance).
- [ ] Open a chat with the agent running on profile "Default".
- [ ] Open the profile dropdown, pick "300 ribu" while the agent is mid-run.
- [ ] Tail `/tmp/agentic_coding.log`. **Confirm**: the next `[CHECKPOINT] loop iter start ... effective_model=...` log line shows the new profile's `model` (not the old one).
- [ ] Open DevTools → Network tab. **Confirm**: the `PUT /api/llm/session/...` returns 200 (existing behaviour); no chat message was sent.
- [ ] Verify the chip in the chatview shows "300 ribu" (existing behaviour).
- [ ] Repeat with a profile that has a different `base_url` (e.g. "900ribu"). Confirm the next LLM call hits the new `base_url` by checking the response.

## Task 6: Documentation

**Files:**
- `docs/SPEC.md` — append a changelog entry
- `AGENTS.md` — append a changelog entry
- `docs/superpowers/plans/2026-08-06-workflow-re-read-profile-per-iter.md` — this plan (already exists)

**Steps:**

- [ ] Append a brief changelog entry to `docs/SPEC.md` under the most recent 2026-08-06 section.
- [ ] Append a brief changelog entry to `AGENTS.md` under "## Recent changes" titled "Workflow loop re-reads selected_profile_model per iteration".

## Verification (per AGENTS.md pre-commit checklist)

```bash
# 1. Static unit tests
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: 3 + 4 new tests pass, 0 new failures, 0 new leaks

# 2. Build the Linux binary
timeout 180 zig build install:linux:system
# Expect: compile succeeds

# 3. Fresh rebuild
rm -rf zig-out/bin
timeout 360 zig build
# Expect: all 3 binaries produced

# 4. Cross-compile smoke (mandatory for SQL helpers)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expect: both clean (no errors)

# 5. Frontend tests (sanity — no Vue changes, but the chip-loading test must still pass)
cd src/apps/desktop
timeout 240 bunx vitest run
# Expect: same 19 pre-existing failures, no new failures

# 6. Frontend build
timeout 180 bun run build 2>&1 | tail -n 20
# Expect: vue-tsc clean, vite build OK

# 7. Live smoke (per Task 5)
# All 4 confirmations pass
```

## Pitfalls (record for future agents)

- **The DB read is per-row, not per-table.** Use `SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?` — single-row PK lookup, cheap. No full-table scan.
- **The re-read slice is borrowed from the per-iteration arena.** `arenaAllocatorWhileLoop` is re-initialized every iteration (line 523-524: `var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(parent_allocator); defer arenaAllocatorWhileLoop.deinit();`). The slice is safe for the iteration. Do NOT cache it across iterations.
- **The `COALESCE` is defensive.** The migration declared `selected_profile_model TEXT NOT NULL DEFAULT ''` (per `migration_071_test.zig` and earlier), but older sessions may have NULL (pre-migration). `COALESCE(..., '')` normalizes both to a non-null empty string.
- **Fallback to `params.selected_profile_model` on read failure.** If the DB query throws, the loop should NOT crash — it should continue with the snapshot. This matches the existing `is_auto_retry_until_stop` pattern (line 543-552: `catch break :blk false`).
- **The `resolveProfileField` warning at line 569-572 fires on EVERY iteration with a non-empty live profile that's not in `LlmConfig.profiles_models`.** If the user picks a profile mid-run and the backend hasn't loaded it yet (e.g. config swap just happened), the warning fires on the next iteration. That's fine — it's a useful signal.
- **`copy_selected_profile_model` is still allocated at line 419.** Removing it would cascade through `handle_tool` callers (line 1076) and require a separate change. We keep it as the fallback; per-iteration live value goes to `handle_tool`.
- **`handle_tool`'s `selected_profile_model` parameter** is propagated to `spawn_sub_agent` via `RunParamsNew.selected_profile_model`. The sub-agent's `runAgenticMultiStepnew` reads `params.selected_profile_model` (its own snapshot) — but since the sub-agent's workflow is fresh, its snapshot IS the live value from the parent. So the live value propagates correctly.
- **The live-config-re-read at line 564 (`config = nalarcore.getLlmConfig(di.di);`) already picks up `LlmConfigHolder` swaps.** That's the pattern for `active_profile` changes from NalarSettings. The new `selected_profile_model` re-read is the analogous pattern for per-session changes via `PUT /api/llm/session/:id`.
- **No new SSE event needed.** The PUT endpoint already broadcasts `session.updated`. The workflow doesn't need to subscribe to it — the in-loop re-read is simpler and atomic with the LLM call.
- **No migration needed.** The `sessions.selected_profile_model` column already exists.

## Out of scope

- **Frontend cascade re-read** (the chip in the chatview already wires via the existing `selectedProfile` ref + `loadChatHistory` watcher). No frontend change needed.
- **Re-reading `is_auto_retry_until_stop` is already done** (line 543-552). No change needed.
- **Re-reading `cwd` / `git_worktree_cwd` per iteration.** Out of scope — the user only asked about profile. If the user wants cwd re-read, that's a separate plan.
- **Persisting the profile immediately on selection** (the PUT endpoint already does this). Frontend is unchanged.
- **Cancelling the running workflow pre-emptively on profile change** (the opposite UX — the user wants the new profile to take effect, not to cancel the run).
- **Showing a "profile change applied" toast** in the chatview. Out of scope — the chip already updates.

## Plan revision history

- 2026-08-06 — Initial plan (wrong interpretation: local-only fix). Superseded by this revision.
- 2026-08-06 — Revision 1: re-read `selected_profile_model` from DB per iteration in `workflow.zig::runAgenticMultiStepnew`. Matches user's clarification: *"Profile change should pick up the NEW profile on the running loop's NEXT iteration, that mean if i select profile no need queue message to workflow agentick just re read selected_profile_model"*.
