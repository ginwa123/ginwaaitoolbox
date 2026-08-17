# Ban absolute paths in agent tool inputs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject absolute paths in any LLM-facing agent tool input that takes a path, with a clear error message; relative paths resolve against the session's bound cwd (or worktree override). Two admin-tier tools (`set_git_worktree`, `create_kanban_task.cwd`) keep accepting absolute paths.

**Architecture:** Single shared validator (`path_security.zig`) that returns either the path unchanged (relative) or a pre-formatted XML `<error>` block (absolute). Each tool's exec wrapper calls the validator on every path-like field, then (for `cwd`-style params) calls `resolveCwd` to convert relative → absolute against `ctx.cwd_override ?? ctx.cwd` before passing to the underlying tool function. Validation lives in the **exec wrapper**, not the tool function, so existing direct-call tests stay green. New `list_directory` tool built on top of `SystemFolder.listDirectory` plus the validator.

**Tech Stack:** Zig 0.16, std.Io, std.fs.path, existing `wrapToolOutput` + `ToolExecContext` plumbing, SystemFolder module, nalarcore module exports.

**Spec:** `docs/superpowers/specs/2026-08-14-ban-absolute-paths-design.md`

## Global Constraints

- Validation is in the **exec wrapper** (`tools_exec_<name>.zig`), NEVER in the tool function (`<name>.zig`). Existing tests call tool functions directly with absolute paths and must keep passing.
- Error envelope uses the standard `wrapToolOutput` shape (`success=false`, `<error>` body). The `<error>` body names the rejected path AND the active cwd so the LLM can compute the relative path on retry.
- Resolution rule for `cwd`-style params: `ctx.cwd_override ?? ctx.cwd`. The worktree override is the trust anchor when set.
- Two exceptions stay absolute-only: `set_git_worktree.path` and `create_kanban_task.cwd`. Annotate only — do not change their validation behavior.
- Bash/pwsh `command` strings are NOT validated for embedded `/` (would break legitimate use cases; the `cwd` is the trust boundary).
- YAGNI: do not add path-traversal protection (`..`), symlink canonicalization, or chroot-style sandboxing in this PR.
- `zig build test --summary all` must remain 0-fail.

## File structure (created / modified)

```
src/modules/agent/tools/
├── path_security.zig            NEW — rejectAbsolutePath + resolveCwd
├── path_security_test.zig       NEW — tests
├── list_directory.zig           NEW — AgentTool + execute_list_directory
├── list_directory_test.zig      NEW — tests
├── bash.zig                     MOD — cwd description, remove from required
├── pwsh.zig                     MOD — same
├── list_skills.zig              MOD — cwd description
├── get_skill.zig                MOD — tighten path description
└── set_git_worktree.zig         MOD — annotate "this is the exception"

src/ai_workflow/tui/agentic_loop/
├── tools_exec_bash.zig          MOD — validate + resolve cwd
├── tools_exec_pwsh.zig          MOD — same
├── tools_exec_list_skills.zig   MOD — same
├── tools_exec_read_file.zig     MOD — validate path
├── tools_exec_write_file.zig    MOD — validate path
├── tools_exec_text_replace.zig  MOD — validate path
├── tools_exec_remove_file.zig   MOD — validate path
├── tools_exec_glob.zig          MOD — validate path
├── tools_exec_search.zig        MOD — validate path
├── tools_exec_get_skill.zig     MOD — validate path
├── tools_exec_list_directory.zig NEW
├── tools.zig                    MOD — re-export execListDirectory
└── tools_equipped.zig           MOD — register list_directory

src/root.zig                     MOD — export path_security + list_directory
src/modules/agent/test_runner.zig MOD — register new test modules
src/modules/agent/prompts.zig    MOD — append relative-path note
```

---

## Task 1: Shared `path_security` module + tests

**Files:** `src/modules/agent/tools/path_security.zig` (new), `src/modules/agent/tools/path_security_test.zig` (new)

- [ ] Write failing test `path_security_test.zig`:
  - `rejectAbsolutePath: returns path unchanged when relative` — `assertEqualStrings("subdir/foo.txt", result)`
  - `rejectAbsolutePath: returns error envelope when absolute` — `assert(std.mem.indexOf(u8, result, "absolute paths are not allowed") != null)`
  - `rejectAbsolutePath: handles edge values "./", "../", ""` — all return path unchanged (relative)
  - `rejectAbsolutePath: Windows backslash absolute paths are also rejected` — pass `"C:\\foo"`, assert error
  - `resolveCwd: null/empty raw returns base cwd` — base `"proj"`, raw `null` → `"proj"`; raw `""` → `"proj"`
  - `resolveCwd: relative raw joins against base` — base `"proj"`, raw `"sub/file"` → `"proj/sub/file"`
  - `resolveCwd: ctx_cwd_override wins over ctx_cwd` — base `"main"`, override `Some("wt")`, raw `"src"` → `"wt/src"`
- [ ] Run `zig build test --summary all` — confirm 7 new tests FAIL (function doesn't exist yet)
- [ ] Implement `src/modules/agent/tools/path_security.zig`:
  - `pub fn rejectAbsolutePath(allocator, tool_name, param_name, path, active_cwd) ![]const u8`
  - `pub fn resolveCwd(allocator, ctx_cwd, ctx_cwd_override, raw) ![]u8`
  - Both allocate with `allocator.dupe` / `allocator.allocPrint`; caller frees
  - `rejectAbsolutePath` uses `std.fs.path.isAbsolute` which handles `/` (POSIX) and `C:\` (Windows)
- [ ] Run `zig build test --summary all` — confirm 7 new tests PASS; baseline unchanged
- [ ] Commit: `git add -A && git commit -m "feat(agent/tools): add path_security shared validator"`

---

## Task 2: Wire `path_security` into exec wrappers (cwd-style tools)

**Files:** `tools_exec_bash.zig`, `tools_exec_pwsh.zig`, `tools_exec_list_skills.zig`

### Task 2a: bash exec wrapper

- [ ] Write failing test `bash_exec_rejects_absolute_cwd_test.zig` in `tools_exec_bash_test.zig`:
  - Build a `ToolExecContext` with `cwd = "/tmp/proj"`, `cwd_override = null`
  - Construct a `ToolCall` with arguments `{"command":"echo hi","cwd":"/etc","mandatory_timeout":5}`
  - Call `execBash(ctx, tc)`
  - Assert the result contains `<error>` and `"/etc"` and `"/tmp/proj"` (the active cwd)
- [ ] Run `zig build test` — confirm 1 new test FAILS (no validation yet)
- [ ] Modify `src/ai_workflow/tui/agentic_loop/tools_exec_bash.zig`:
  - After parsing JSON, call `rejectAbsolutePath(ctx.allocator, "bash", "cwd", parsed.value.cwd, ctx.cwd)`
  - If the return is an error envelope → wrap with `wrapToolOutput(..., success=false, ...)` and return early
  - Otherwise call `resolveCwd(ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.cwd)` and pass the resolved absolute to `execute_bash` (via a new field on `BashInput` or by passing through `runWithContext` with the resolved value)
- [ ] Run `zig build test` — confirm 1 new test PASSES; baseline unchanged
- [ ] Commit: `git add -A && git commit -m "feat(agent/bash): reject absolute cwd; resolve relative against ctx.cwd"`

### Task 2b: pwsh exec wrapper

- [ ] Same as 2a but for `tools_exec_pwsh.zig` and `execPwsh`
- [ ] Commit: `git add -A && git commit -m "feat(agent/pwsh): reject absolute cwd; resolve relative against ctx.cwd"`

### Task 2c: list_skills exec wrapper

- [ ] Same as 2a but for `tools_exec_list_skills.zig`. `list_skills` already takes `cwd_param` (not `cwd`) — match the existing field name
- [ ] Commit: `git add -A && git commit -m "feat(agent/list_skills): reject absolute cwd; resolve relative against ctx.cwd"`

---

## Task 3: Wire `path_security` into exec wrappers (path-style tools)

For each of the 7 tools below: write a "rejects absolute path" test, run it (FAIL), add validation, run it (PASS), commit.

### Task 3a–3g: read_file, write_file, text_replace, remove_file, glob, search, get_skill

- [ ] Per tool:
  - Write `tools_exec_<name>_test.zig` test that calls `exec<Name>(ctx, tc)` with absolute path, asserts `<error>` in result
  - Modify `tools_exec_<name>.zig`: after JSON parse, validate path field; on error → wrap + return early
  - Verify `zig build test --summary all` is 0-fail with the new test passing
  - Commit: `git add -A && git commit -m "feat(agent/<name>): reject absolute path"`

Pattern (for `read_file`; same shape for the others — adjust field name + test data):

```zig
// In tools_exec_read_file.zig, after parsed.deinit() but before the file op:
if (try nalarcore.tools.path_security.rejectAbsolutePath(
    ctx.allocator, "read_file", "path", parsed.value.path, ctx.cwd
)) |err_msg| {
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

(The `if (try ...) |err_msg|` shape needs the function to be tagged-union-returning; if signature is simpler, just early-return with a manual check. Adjust per tool's existing patterns.)

---

## Task 4: Update tool descriptions (the Banned tools + the exception)

**Files:** `bash.zig`, `pwsh.zig`, `list_skills.zig`, `get_skill.zig`, `set_git_worktree.zig`

- [ ] Update `bash.zig:147` — `cwd` description → "Working directory. Relative paths only (absolute paths are rejected — security policy). Resolved against the session's cwd (or the active git-worktree binding if set). Omit to default to the session's cwd."
- [ ] Update `bash.zig:208` — remove `"cwd"` from `required = &.{...}` array
- [ ] Update `pwsh.zig:135` + `pwsh.zig:195` — same
- [ ] Update `list_skills.zig:28` — `cwd` description → same wording as above (note: `list_skills` already has `required = &.{}`)
- [ ] Update `get_skill.zig:41` — `path` description → tighten to "File path. Relative to the session's cwd (or absolute, but absolute paths are rejected — security policy). Use a relative path."
- [ ] Update `set_git_worktree.zig:41` — append: "This is the only tool that accepts absolute paths — admin-tier escape hatch for navigating outside the session's cwd."
- [ ] Run `zig build test --summary all` — confirm baseline 0-fail (description changes are not test-covered, but the schema validations in tasks 2/3 must stay green)
- [ ] Commit: `git add -A && git commit -m "docs(agent/tools): update cwd/path descriptions to reflect absolute-path ban"`

---

## Task 5: Build the new `list_directory` tool

**Files:** `src/modules/agent/tools/list_directory.zig`, `list_directory_test.zig`, `src/ai_workflow/tui/agentic_loop/tools_exec_list_directory.zig`, `src/root.zig`, `src/ai_workflow/tui/agentic_loop/tools.zig`, `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`, `src/modules/agent/test_runner.zig`

- [ ] Write failing test `list_directory_test.zig`:
  - `execute_list_directory: rejects absolute path` — pass `"/etc"`, assert error
  - `execute_list_directory: lists entries in "."` (relative cwd) — temp dir with 2 files + 1 subdir; assert all 3 entries present, sorted dirs-first
  - `execute_list_directory: lists entries in "subdir"` (relative) — same shape
  - `execute_list_directory: hidden=false skips dotfiles` — file `.hidden` absent
  - `execute_list_directory: hidden=true includes dotfiles` — file `.hidden` present
  - `execute_list_directory: respect_ignore_files=true respects .gitignore` — write `.gitignore` with `*.log`, create `foo.log` + `foo.txt`, assert `foo.log` absent
- [ ] Run `zig build test --summary all` — confirm 6 new tests FAIL
- [ ] Implement `src/modules/agent/tools/list_directory.zig`:
  - `pub const ListDirectoryInput = struct { path: []const u8 = ".", hidden: bool = false, respect_ignore_files: bool = true }`
  - `pub fn execute_list_directory(allocator, io, resolved_path, input) ![]const u8` — wraps `SystemFolder.listDirectory` + an XML serializer
  - `pub const list_directory_tool = AgentTool{ ... }` with the schema
- [ ] Implement `src/ai_workflow/tui/agentic_loop/tools_exec_list_directory.zig`:
  - Parse JSON
  - Validate path with `rejectAbsolutePath`
  - Resolve with `resolveCwd`
  - Pass to `execute_list_directory`
  - Wrap output with `wrapToolOutput`
- [ ] Wire into `src/root.zig`: add `pub const path_security = @import("..."); pub const list_directory = @import("...");`
- [ ] Wire into `src/ai_workflow/tui/agentic_loop/tools.zig`: add `pub const execListDirectory = @import("...").execListDirectory;`
- [ ] Wire into `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`:
  - Add to `equips()` const list
  - Add to `UNIFIED_TOOL_REGISTRY()` as `.{ .name = "list_directory", .exec = tools.execListDirectory, .tool_def = list_directory_mod.list_directory_tool }`
- [ ] Register `path_security_test.zig` and `list_directory_test.zig` in `src/modules/agent/test_runner.zig`
- [ ] Run `zig build test --summary all` — confirm 6 new tests PASS; baseline + all earlier-task tests still pass
- [ ] Commit: `git add -A && git commit -m "feat(agent/list_directory): new tool for first-level directory listing"`

---

## Task 6: Update agent system prompt

**Files:** `src/modules/agent/prompts.zig`

- [ ] Search the file for `"absolute"` and `"working directory"` — find every instruction that tells the agent to use absolute paths
- [ ] Most tool descriptions propagate automatically because the prompt's tool listing is data-driven from `AgentTool.function.description`. After Tasks 2 + 4, the descriptions already say "Relative paths only".
- [ ] Add one line to the "Memory file paths shown in this prompt are absolute" guidance — find the section that emits memory paths for `read_file` / `get_skill` and append a note:
  > "Note: memory file paths shown above are absolute (e.g. for copy-paste). Strip the `<active cwd>` prefix before passing them to read_file/write_file/text_replace/remove_file/get_skill — these tools now require relative paths."
- [ ] Run `zig build test --summary all` — confirm 0-fail; specifically check `prompts_test.zig` for any assertion that depends on the absolute-path phrasing
- [ ] Commit: `git add -A && git commit -m "docs(agent/prompts): add note about relative-path policy"`

---

## Task 7: Final verification + branch + PR

- [ ] `zig build test --summary all` → 0 fail, total pass count ≥ baseline (~2264 + ~25 new = ~2289)
- [ ] `zig build` → 0 errors
- [ ] `git diff --stat` shows changes only in the files listed above
- [ ] `git status` clean (no stray `.zig-cache` files; remove any emitted by vue-tsc if you ran it)
- [ ] Create worktree branch: `git checkout -b worktree/ban-absolute-paths`
- [ ] Push and open PR with the spec + plan linked in the description
- [ ] Move kanban task `task_1786981446877_0` from `in_review_planning` → `in_review_task`

---

## Out-of-scope follow-ups (kanban candidates)

After this PR lands, suggest two follow-up tasks:

1. **Path traversal protection** — reject relative paths containing `..` segments that escape the session's cwd. Same `path_security.zig` module, new `rejectPathTraversal` helper.
2. **Symlink canonicalization** — call `std.fs.cwd().realpath` on every path before resolving, so the LLM cannot bypass the cwd check via a symlink chain.

Add these as new kanban tasks (do NOT include in this PR per the YAGNI rule).

---

## Verification (for this plan)

- [x] Plan saved at `docs/superpowers/plans/2026-08-14-ban-absolute-paths.md`
- [x] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [x] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins