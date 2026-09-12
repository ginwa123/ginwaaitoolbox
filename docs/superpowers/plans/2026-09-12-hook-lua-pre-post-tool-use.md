# SIMPLE Lua Hooks — Implementation Plan (v3: single file)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one Lua file — `<config_dir>/hooks/register_hook.lua` — around each tool call, calling its `init(event, data)` with `event` = `"pre_tool_use"` or `"post_tool_use"`.

**Architecture:** Rewrite the `src/agentic_loop/hooks.zig` stub into a tiny runner: if `<config_dir>/hooks/register_hook.lua` exists, open a fresh Lua 5.4 state per hook call (hand-declared `extern`, no `@cImport`), load the file, call `init(event, data)` where `data` is one Lua table. Two call sites in `src/agentic_loop/handle_tool.zig` (`dispatchTool` top = pre, `exec`-return wrap = post). Fail-open everywhere: missing file/fn, Lua error, bad return → log and continue as if the hook wasn't there.

**Tech Stack:** Zig 0.16, Lua 5.4 system lib (`/usr/include/lua.h` + `/usr/lib/liblua5.4.so`, confirmed present), `linkSystemLibrary("lua5.4")` in `build.zig` with `hooks_enabled=false` fallback when Lua is absent, Lua table (not JSON strings) as the `data` bridge.

## Global Constraints

- Zig 0.16 only. No `@cImport` — hand-declare Lua C fns as `extern`, verify constants against `/usr/include/lua.h`.
- Cross-platform: Linux primary; macOS/Windows must still compile (`build.zig` probe + no-op fallback when Lua headers/libs missing).
- Do NOT use port 8081 for tests. Functional tests use `tests/functional/harness.py` (isolated tmpdir HOME).
- No live-server `curl` verification; Zig-only behavior via `zig test`, wire behavior via harness.
- No `// NEW (plan: ...)` comment tags.
- TDD: failing test first. Commit per task.
- YAGNI: ONLY this single-file contract. No hook settings in config.json, no timeout config, no reload cache (load fresh every call).

## The Contract (frozen)

**Discovery:** exactly one file: `<config_dir>/hooks/register_hook.lua`. No directory scan, no other filenames, subdirs irrelevant. Missing file = hooks disabled (one debug log line, no spam).

**Lua side — the whole API is this one file:**

```lua
-- ~/.config/nalar/hooks/register_hook.lua
function init(event, data)
  if event == "pre_tool_use" then
    -- data = { tool_name = "bash", arguments = "{...raw json...}",
    --           session_id = "...", cwd = "...", model = "..." }
    -- return nil to do nothing, or return a table to act:
    --   return { deny = "reason shown to agent as tool error" }
    --   return { arguments = "{...new json...}" }  -- modify args, re-validated by tool
    --   return { output = "..." }                  -- mock: skip real exec, use this output
  end
  if event == "post_tool_use" then
    -- data = { tool_name = "...", arguments = "{...}",
    --          output = "...tool result text...",
    --          session_id = "...", cwd = "...", model = "..." }
    -- return nil to keep output, or:
    --   return { output = "...new output..." }  -- replace/redact
    --   return { deny = "reason" }              -- replace output with error envelope
  end
  return nil
end
```

**Rules:**
- `init` missing → hook disabled for that call (not an error).
- `init` returns `nil`/`false`/nothing → no-op.
- `init` returns a table → honored as above. Unknown keys ignored. Wrong types (e.g. `deny = 42`) → ignore + log, continue as no-op.
- **Errors:** Lua syntax/runtime error → log (file name + Lua message) and continue as no-op. Never crashes the tool call.
- **No sandboxing in v1:** runs with `luaL_openlibs` (full stdlib) as the user's own trusted script, like a shell rc file.

**Zig side — event strings:** exactly `"pre_tool_use"` and `"post_tool_use"`.

## Context (implementer doesn't re-derive)

- Seam: `src/agentic_loop/handle_tool.zig:182 dispatchTool` (registry lookup + `mcp_*` fallback + `error.UnknownTool`) and `:201 dispatchFromRegistry` (builds `tools.ToolExecContext`, calls `entry.exec`). Pre = top of `dispatchTool`; post = wrap around `exec` return (lift to `dispatchTool` wrapper so one site covers builtins + MCP).
- Loop caller `handle_tool(...):335` pre-inserts placeholder `role=tool` rows then UPDATEs them — hooks run inside per-tool dispatch so placeholder/SSE order is untouched. Deny/mock/post-replace outputs go through existing `wrapToolOutput` envelope (same path as unknown-tool error, `:452-459`).
- `src/agentic_loop/hooks.zig` = 18-line comment stub, imported by nothing. Replace wholesale.
- No Lua in repo today. `build.zig` has a pure-Zig `fileExists` probe pattern + `linkSystemLibrary` usage to copy for the Lua probe.
- Hooks dir follows the *config* dir: `<config_dir>/hooks` where config dir = `~/.config/nalar` (Linux), `~/Library/Application Support/nalar` (macOS), `%APPDATA%/nalar` (Windows) — mirror `Config.zig:2478 getDefaultConfigPath` branches + `mkdir -p` like `helpers/db_path.zig`.
- System: `zig 0.16.0`, `lua5.4` + headers + `.so` present.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/agentic_loop/lua_bindings.zig` | CREATE | Hand-declared Lua 5.4 `extern` fns only (newstate, openlibs, close, loadfilex, pcallk, getglobal, getfield, pushstring, tostring, type, createtable, setfield, settop). No logic. |
| `src/agentic_loop/hooks.zig` | REWRITE | `runPreHooks(...) → PreResult` + `runPostHooks(... output) → PostResult`. Internals: `hookFilePath` (join dir + `register_hook.lua`), `callInit` (fresh state, push `event` string + `data` table, pcall, parse return table). Fail-open + logging. |
| `src/agentic_loop/hooks_test.zig` (or inline tests) | CREATE | Unit tests with real Lua: missing file, missing `init`, nil return, deny/modify/mock/replace, broken syntax fail-open, bad return-type ignored. |
| `src/agentic_loop/handle_tool.zig` | EDIT (2 seams) | Pre at top of `dispatchTool`, post wrapping exec result. Deny/mock short-circuit without calling `exec`; modify rewrites `tool_call.function.arguments`; post-replace swaps output. All fail-open. |
| `build.zig` | EDIT | Lua probe + `linkSystemLibrary("lua5.4")` or `hooks_enabled=false` no-op fallback. Compile-only check macOS/Windows. |
| `src/modules/config/Config.zig` or new `hooks_dir` helper | EDIT/CREATE | `getHooksDir` → `<config_dir>/hooks` + `mkdir -p`. Mirror platform branches. |
| `examples/hooks/register_hook.lua` | CREATE | 20-line copy-paste example of `init(event, data)` (deny `rm -rf` demo + redact demo). |
| `docs/hooks.md` | CREATE | User docs: file location per OS, the contract above verbatim, 1 example, fail-open semantics. |
| `tests/functional/hooks_lua_test.py` | CREATE | Harness tests (isolated HOME): pre-deny blocks `bash`, modify rewrites args, post replaces output, broken lua fail-open, missing file = normal run. |

## Tasks

### Phase 0 — Spike (timeboxed 30 min, proves the risky bit)

- [ ] **0.1 Failing spike: Zig calls Lua `init(event, data)`.** Throwaway `spike_lua.zig` (NOT committed): open state, load string defining `function init(event, data) return { output = "hi " .. data.tool_name } end`, push event + table, pcall, read back. Run → fails to build (no bindings yet).
- [ ] **0.2 Make spike pass.** Hand-write the minimal `extern` set until the spike prints the expected string. Record working signatures + link flags. If it fails in 30 min → stop, report, fallback = shell-out to `lua5.4` binary (documented, slower).
- [ ] **0.3 Delete spike file.** Keep only the notes (2-3 lines appended to this plan's Context).

### Phase 1 — Bindings + hooks dir (no behavior change)

- [ ] **1.1 Failing test: bindings eval `return 1+1`.** Add test asserting round-trip through real `liblua5.4`. Run `zig test` → fails (no file).
- [ ] **1.2 Implement `lua_bindings.zig`.** Only the `extern` set proven by the spike. Test → passes.
- [ ] **1.3 Commit** (`feat(hooks): lua 5.4 bindings`).
- [ ] **1.4 Failing test: `getHooksDir` with tmpdir HOME.** Assert path ends in `hooks` + dir created. Run → fails.
- [ ] **1.5 Implement `getHooksDir` + `mkdir -p`.** Mirror `getDefaultConfigPath` branches. Test → passes.
- [ ] **1.6 `build.zig` probe + link/fallback.** `zig build` green here; compile-only check macOS + Windows targets.
- [ ] **1.7 Commit** (`build: optional lua5.4 linkage, hooks dir`).

### Phase 2 — Runner core (`hooks.zig`, single file)

- [ ] **2.1 Failing test: missing `register_hook.lua` → allow/keep.** `runPreHooks`/`runPostHooks` with empty dir return no-op. Run → fails.
- [ ] **2.2 Implement skeleton** (resolve path; missing = no-op + debug log). Test → passes.
- [ ] **2.3 Failing test: file without `init` → no-op.** Run → fails.
- [ ] **2.4 Implement `callInit`:** load file, `getglobal("init")`, if nil → no-op; else push event + data table, pcall, parse return (nil = no-op, table = deny/arguments/output). Test → passes.
- [ ] **2.5 Failing test: deny / modify / mock / replace each honored.** One test per action against real Lua file fixtures. Run → fails.
- [ ] **2.6 Implement action parsing** (deny/arguments/output keys, type-checked). Test → passes.
- [ ] **2.7 Failing test: broken syntax → fail-open.** Corrupt lua file asserts allow/keep. Run → fails.
- [ ] **2.8 Implement error capture** (log file + Lua message, continue as no-op). Test → passes.
- [ ] **2.9 Commit** (`feat(hooks): single-file init(event,data) runner`).

### Phase 3 — Wire into `handle_tool.zig`

- [ ] **3.1 Failing test: pre-deny skips exec.** `dispatchTool` with hook stub denying; assert `exec` counter == 0 and output holds deny reason envelope. Run → fails.
- [ ] **3.2 Implement pre seam** (top of `dispatchTool`, rewrite args on `arguments`, return mock `output` without exec). Test → passes.
- [ ] **3.3 Failing test: post-replace swaps output.** Exec returns `"secret=abc"`, hook returns `{ output = "redacted" }`; assert final output redacted. Run → fails.
- [ ] **3.4 Implement post seam** (wrap exec incl. MCP path). Test → passes.
- [ ] **3.5 Commit** (`feat(hooks): wire pre/post seams`).

### Phase 4 — Docs, example, functional proof

- [ ] **4.1 `examples/hooks/register_hook.lua` + `docs/hooks.md`.** Contract pasted verbatim from this plan + 1 example.
- [ ] **4.2 Functional: pre-deny blocks real `bash`.** Harness + isolated HOME + `register_hook.lua` returning `{ deny = ... }` for `bash`; assert envelope has reason + marker file absent. Run → fails before Phase 3, passes after.
- [ ] **4.3 Functional: modify + post-replace + broken-lua fail-open.** Same harness: modify rewrites args (assert exec saw new args), post replaces output, then corrupt the lua file and assert normal run. Missing file asserts normal run.
- [ ] **4.4 Full verify:** `zig build`, `zig test` (agentic_loop), cross-compile macOS/Windows, functional file green. Commit (`feat(hooks): docs, example, functional tests`).

## Verification (done = all true)

- [ ] `zig build` green Linux; macOS/Windows compile-only green (or no-op fallback documented).
- [ ] `zig test` for `hooks` + `lua_bindings` green, no hangs.
- [ ] `tests/functional/hooks_lua_test.py` green via harness (never 8081, never live curl).
- [ ] Existing `handle_tool` / `tools_exec_*` tests green (no placeholder/SSE regression).
- [ ] `docs/hooks.md` contract matches implementation byte-for-byte.
- [ ] Card stays in `in_review_planning` until human approves; implementation on follow-up card/PR from `worktree/hook2312maspodmp2131`.

## Risks

| Risk | Mitigation |
|---|---|
| Lua absent on mac/Windows | Probe + no-op fallback; binary still builds. |
| Header drift | `extern` verified against `/usr/include/lua.h`; spike proves first. |
| Hook error breaks tools | Fail-open; covered by 2.7 test. |
| Bad `arguments` JSON from hook | Re-validate; invalid → keep original args + log (test it). |
| Scope creep | This plan IS the scope cut: one file, one fn, two events, one table. Say no to the rest. |
