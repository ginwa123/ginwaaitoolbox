# Follow-up: Runtime CWD override for `set_git_worktree` tool

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan.

**Status:** Open. Tracked as a follow-up to `docs/plans/2026-06-18-set-git-worktree-tool.md` (commits `65b36e56`, `ba2cb938`, `2626c797`, `eead77b1`).

**Goal:** Make the `cwd_override: ?[]const u8 = null` field on `ToolExecContext` actually do something. After this plan ships, when an LLM calls `set_git_worktree` with a `path`, subsequent tool dispatches in the same session (bash, read_file, write_file, text_replace, glob, search) will operate on the worktree path, not the session's original `cwd`.

**Current state (v1.0 shipped):**
- `sessions.git_worktree_cwd` column exists (Migration 046)
- `set_git_worktree` tool persists the worktree path to the DB
- The `cwd_override` field on `ToolExecContext` is declared but **never read, never populated, never mutated** — it is dead-letter code
- Workaround for the LLM: re-invoke `set_git_worktree` to confirm the binding, or `cd <worktree_path>` in each bash call

**Architecture:** Switch the `ToolExecFunc` signature from `fn (ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult` to `fn (ctx: *ToolExecContext, tc: agent.ToolCall) !ToolExecResult` (pointer-pass). The `cwd_override` is then mutable across the call. The `execBash` (and friends) reads `ctx.cwd_override ?? ctx.cwd` for filesystem operations. The `handle_tool.zig` workflow teardown frees the override.

**Tech Stack:** Zig 0.16 + `std.Io.Threaded`. No new dependencies.

---

## Design decisions locked during brainstorming

1. **Pointer-pass for `ctx`**, not a separate "override ctx" type. Reason: the function-pointer signature `pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;` is used in TWO places (`UNIFIED_TOOL_REGISTRY` and `MAIN_AGENT_TOOL_REGISTRY`). Changing the type cascades to every `exec*` function. Pointing the field is the minimal cascade.

2. **Only the 5 filesystem tools opt in** to reading `cwd_override ?? ctx.cwd`:
   - `execBash` — bash tool (most important; the LLM uses this constantly)
   - `execReadFile`
   - `execWriteFile`
   - `execTextReplace`
   - `execGlob`
   - `execSearch`

   The other 20+ tools (`list_skills`, `get_skill`, `add_skill`, `edit_skill`, `remove_skill`, `view_skill`, `set_agent_properties`, `spawn_sub_agent`, `update_activity`, `set_git_worktree`, `remove_file`, `change_agent`, `list_agents`, `add_agent`, `remove_agent`, `lsp_*`, `nalar_browser`, `web_search`) do NOT touch the filesystem and don't need the override.

3. **Override lifetime = one tool dispatch.** Set on `set_git_worktree` success; read by the NEXT `exec*` call; freed on workflow exit by `handle_tool.zig`. No persistent cache, no per-session cache — the DB column is the source of truth (re-read on workflow startup if needed).

4. **`set_git_worktree` reads the DB at workflow startup**, not at the dispatch site. Implementation: `handle_tool.zig`'s `runAgenticMultiStepnew` reads `sessions.git_worktree_cwd` once and sets `ctx.cwd_override` before the first tool dispatch. Subsequent tool calls see the override. The `execSetGitWorktree` function mutates `ctx.cwd_override` directly for in-session switches (calling `set_git_worktree` with a different `path` updates the override without re-reading the DB).

5. **Memory ownership**: `cwd_override` is allocated with `ctx.allocator.dupe(u8, worktree_path)` on set. Freed by `handle_tool.zig`'s existing teardown loop. No leaks.

---

## File structure

### Modified files

```
src/ai_workflow/tui/
├── tool_registry.zig                 (1) change ToolExecFunc signature (ctx: *ToolExecContext)
│                                       (2) add cwd_override opt-in in 6 exec functions
│                                       (3) update execSetGitWorktree to mutate ctx.cwd_override
├── handle_tool.zig                   (4) read sessions.git_worktree_cwd at workflow startup
│                                       (5) free ctx.cwd_override on workflow teardown
│                                       (6) update 2 dispatch sites to pass &ctx instead of ctx
├── tool_registry_test.zig            (7) add behavioral test: cwd_override propagates to execBash
```

No new files.

### No frontend changes

The frontend is unaffected — the `git_worktree_cwd` field is already wired in Chunk 4 of the parent plan.

---

## Verification commands

```bash
# Backend
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 40

# Frontend (no changes, just confirm not broken)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20

# Manual smoke test
zig build install:linux:system 2>&1 | tail -n 5
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-smoke.log 2>&1 &
# 1) Create a session
curl -X POST http://127.0.0.1:8080/api/session -H 'Content-Type: application/json' -d '{"session_id":"override_smoke_001"}'
# 2) Ask the LLM to call set_git_worktree with a path
# 3) Verify `git worktree list` shows the new entry
# 4) Ask the LLM to run `pwd` — it should report the worktree path, NOT the original cwd
# 5) Ask the LLM to read a file INSIDE the worktree path — it should succeed
# 6) Ask the LLM to call set_git_worktree with a DIFFERENT path — it should switch
# 7) Run `pwd` again — it should report the new worktree path
# 8) Ask the LLM to call set_git_worktree with clear=true — the override is cleared
# 9) Run `pwd` — it should report the original cwd again
```

---

## Chunk 1: `ToolExecFunc` signature change

The minimal cascade. All `exec*` functions take `ctx: *ToolExecContext` instead of `ctx: ToolExecContext`. The 2 dispatch sites pass `&tool_exec_context` instead of `tool_exec_context`. Every internal read of `ctx.cwd` becomes `ctx.cwd` (no change — auto-deref on pointer access).

- [ ] **Step 1.1: Change `ToolExecFunc` signature in `src/ai_workflow/tui/tool_registry.zig` line 108**

Change from:
```zig
pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;
```
To:
```zig
pub const ToolExecFunc = *const fn (ctx: *ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;
```

- [ ] **Step 1.2: Update ALL `pub fn exec*` function signatures to take `*ToolExecContext`**

There are ~29 `exec*` functions in `tool_registry.zig`. Each one's signature changes from `fn (ctx: ToolExecContext, tc: agent.ToolCall)` to `fn (ctx: *ToolExecContext, tc: agent.ToolCall)`. Internal `ctx.field` reads are unchanged (auto-deref).

Pattern: `sed -i 's/fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult/fn (ctx: *ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult/g'` in the file. Verify the change compiles.

- [ ] **Step 1.3: Update the 2 dispatch sites**

In `src/ai_workflow/tui/handle_tool.zig`, the two places that construct and call a `ToolExecContext`:
- `dispatchFromRegistry` (around line 169) — change `tool_exec_context` (value) to `&tool_exec_context` (pointer) when calling the exec function
- `dispatchSetAgentProperties` (around line 253) — same change

Pattern:
```zig
// Before:
const result = try tool.exec(ctx, tc);
// After:
const result = try tool.exec(&ctx, tc);
```

Note: `tool.exec` is now `*const fn (ctx: *ToolExecContext, ...)`, so we pass `&ctx`.

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` must show `test success` with the same test count as before (no new tests, no new failures). If compile errors point at an `exec*` function I missed, fix the signature.

---

## Chunk 2: Populate `cwd_override` at workflow startup

`handle_tool.zig` reads `sessions.git_worktree_cwd` once at workflow startup and sets `ctx.cwd_override` accordingly.

- [ ] **Step 2.1: In `handle_tool.zig`'s `runAgenticMultiStepnew`, after `tool_exec_context` is built**

Add (BEFORE the first tool dispatch loop):
```zig
// If the session has a bound worktree, set the cwd_override so the
// first tool dispatch operates on it (instead of the session's
// original cwd). The override is freed at workflow teardown.
if (llm_history.getSession(allocator, sqlite_db, session_id)) |maybe_session| {
    defer if (maybe_session) |s| s.deinit(allocator);
    if (maybe_session) |s| {
        if (s.git_worktree_cwd.len > 0) {
            tool_exec_context.cwd_override = try allocator.dupe(u8, s.git_worktree_cwd);
        }
    }
}
```

Note: the `?[]const u8` slice points into a `dupe`'d buffer, NOT the session struct. This is critical — the `s` is freed by `defer` before the tool dispatch, but the override must outlive the first dispatch.

- [ ] **Step 2.2: Free `cwd_override` at workflow teardown**

Find the existing teardown loop in `runAgenticMultiStepnew` (the function frees per-call resources, then returns). Add:
```zig
if (tool_exec_context.cwd_override) |p| allocator.free(p);
```

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — no test count change, no new failures.

---

## Chunk 3: Opt-in to `cwd_override` in 6 exec functions

The 5 filesystem tools read `ctx.cwd_override ?? ctx.cwd` for filesystem operations. The non-filesystem tools are unchanged.

- [ ] **Step 3.1: `execBash` (most important)**

Find the call site in `execBash` where the bash tool's `cwd` is set. It's the `.cwd` field of the `BashInput` struct that's passed to `bash_tool_mod.execute_bash(allocator, io, parsed.value)`. Change:
```zig
// Before:
const bash_output = try bash_tool_mod.execute_bash(allocator, io, parsed.value);
// After (line up the cwd override):
const effective_cwd = ctx.cwd_override orelse ctx.cwd;
var modified_input = parsed.value;
modified_input.cwd = effective_cwd;
const bash_output = try bash_tool_mod.execute_bash(allocator, io, modified_input);
```

Verify `BashInput.cwd` is a `?[]const u8` field that accepts a runtime value (not a comptime field). If it's a comptime field, you'll need a different approach (maybe a `cwd_override` on the bash tool itself — out of scope for this plan).

- [ ] **Step 3.2: `execReadFile`**

Find the call to `read_file_mod.readFile`. The tool takes a path string. The CWD doesn't directly apply (read_file is absolute-path-based), but if the LLM uses a relative path, the cwd override matters. Look at the `ReadFileOptions` or similar for a cwd field. If absent, skip this step — read_file with relative paths is not used in the worktree context.

- [ ] **Step 3.3: `execWriteFile`**

Same as execReadFile — look for a cwd field in the write tool's input. If absent, skip.

- [ ] **Step 3.4: `execTextReplace`**

Same pattern.

- [ ] **Step 3.5: `execGlob`**

`glob_tool_mod.executeGlob(allocator, io, parsed.value)` — the tool takes a pattern and a path. Set the path to the override if non-null:
```zig
const effective_path = ctx.cwd_override orelse ctx.cwd;
var modified_input = parsed.value;
modified_input.path = effective_path;
const result = try glob_tool_mod.executeGlob(allocator, io, modified_input);
```

- [ ] **Step 3.6: `execSearch`**

Same pattern as execGlob.

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — no test count change.

---

## Chunk 4: `execSetGitWorktree` mutates `cwd_override` directly

When the LLM calls `set_git_worktree` with a new `path`, the override is updated in-memory. When `clear=true`, the override is set to null.

- [ ] **Step 4.1: In `execSetGitWorktree`, after the DB persistence**

After the `llm_history.updateSessionGitWorktreeCwd(...)` call (around line 525 of tool_registry.zig), add:
```zig
// Update the in-memory cwd_override so subsequent tool dispatches
// in this same session see the new worktree path (no need to wait
// for a workflow restart).
if (parsed.value.clear) {
    // Free the previous override (if any) before nulling.
    if (ctx.cwd_override) |old| {
        ctx.allocator.free(old);
        ctx.cwd_override = null;
    }
} else if (worktree_path.len > 0) {
    // Free the previous override before replacing.
    if (ctx.cwd_override) |old| ctx.allocator.free(old);
    ctx.cwd_override = try ctx.allocator.dupe(u8, worktree_path);
}
```

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — no test count change.

---

## Chunk 5: Behavioral test for the cwd_override propagation

A new test that proves the end-to-end pipeline works: `set_git_worktree` → `execBash` reads a file in the worktree.

- [ ] **Step 5.1: Add behavioral test in `src/ai_workflow/tui/tool_registry_test.zig`**

The test (rough sketch):
```zig
test "set_git_worktree then execBash operates in the worktree" {
    // 1. Open in-memory DB
    // 2. Create a real temp directory `/tmp/test-worktree-xyz`
    // 3. Run `git worktree add` to register it (needs a real git repo)
    // 4. Call execSetGitWorktree with the temp path
    // 5. Verify ctx.cwd_override is set to the temp path
    // 6. Call execBash with `pwd` as the command
    // 7. Verify the output contains the temp path
}
```

The test setup is complex (needs real git, real filesystem). If the project doesn't have a precedent for behavioral tool tests, follow the static-test pattern instead:
- Verify the source code has the right `ctx.cwd_override ?? ctx.cwd` pattern
- Verify the source code has the free-old-then-replace pattern
- Trust that the runtime behavior is correct (the static structure is a proxy for it)

If neither approach is feasible, document the test as "manual-only" and add a `MANUAL_TEST.md` checklist.

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — should show +1 test if behavioral, 0 change if static.

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| The `ToolExecFunc` signature change breaks other callers | Medium | The function pointer type is used in 2 places only (`UNIFIED_TOOL_REGISTRY` and `MAIN_AGENT_TOOL_REGISTRY`). The `sed` change touches all 29 `exec*` functions at once. The `zig build test` will catch any missed function. |
| `BashInput.cwd` (or other tool inputs) is a `comptime` field, not runtime | Medium | If true, the "modify input then call" approach fails. Workaround: add a runtime `cwd_override` field to each affected tool's input struct. This is more invasive but unavoidable. |
| `cwd_override` memory leak in error paths | Low | The override is allocated in 2 places: workflow startup (Chunk 2) and `execSetGitWorktree` (Chunk 4). Both use `try allocator.dupe` and free on teardown. Error paths return before allocation completes, so no leak. |
| The pointer-pass breaks the project memory's "per-request arena" pattern | Low | The pointer is only used for mutation. All reads still go through the arena-owned `ToolExecContext` (the pointer points INTO the arena, not into separately-allocated memory). The override is the only thing allocated separately, and it's freed at workflow teardown. |
| `set_git_worktree(clear=true)` leaks the previous override | Low | The Chunk 4 code explicitly frees the old override before nulling. The free-old-then-replace pattern. |

---

## Files modified summary

| File | Change | LoC estimate |
|---|---|---|
| `src/ai_workflow/tui/tool_registry.zig` | `ToolExecFunc` signature change (29 functions updated) + 6 opt-ins to `cwd_override ?? ctx.cwd` + `execSetGitWorktree` mutation | +60 / -30 (net +30) |
| `src/ai_workflow/tui/handle_tool.zig` | read `sessions.git_worktree_cwd` at startup + free at teardown + 2 dispatch sites pass `&ctx` | +15 |
| `src/ai_workflow/tui/tool_registry_test.zig` | +1 behavioral or static test for cwd_override propagation | +30 |

**Total estimate:** ~75 LoC, ~1 new test case.

---

## Definition of done

- [ ] All 5 chunks complete.
- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` shows `test success` and the test count increased by ~1.
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` is clean (no frontend changes, but verify nothing broke).
- [ ] Manual smoke test (Section "Verification commands") passes all 9 steps: set worktree, run pwd (sees worktree), read file (sees worktree), switch worktree, pwd (sees new), clear, pwd (sees original cwd).
- [ ] No new test regressions.
- [ ] Memory leak check: `valgrind ./zig-out/bin/nalar` (optional, only if time permits) shows no leaks of `cwd_override`.
