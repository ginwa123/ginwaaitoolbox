# Ban absolute paths in agent tool inputs — Design

> Date: 2026-08-14
> Owner: session_1786981446877
> Status: **Draft — awaiting user approval before implementation**
> Source kanban task: `task_1786981446877_0` ("listing agent tool" → expanded after user pivot)

---

## Problem (user-reported)

The agent's tools currently accept — and in three cases (`bash`, `pwsh`, `list_skills`) **require** — **absolute paths** as input. Absolute paths let the agent escape the project sandbox: a tool call with `cwd=/etc` or `read_file("/root/.ssh/id_rsa")` reaches anywhere on disk, regardless of what session the agent was started in.

The user said it directly: *"absolute path is banned, why, cause absolute path can increase risk security"*.

**Concrete escape vectors today (with paths the LLM commonly generates):**

| Tool | Escape vector | Example |
|---|---|---|
| `bash.cwd` | Spawns shell in any directory | `bash { command: "cat /etc/shadow", cwd: "/etc" }` |
| `pwsh.cwd` | Same on Windows | `pwsh { command: "Get-Content C:\\Windows\\...\\SAM", cwd: "C:\\" }` |
| `list_skills.cwd` | Resolves global skills from any dir | `list_skills { cwd: "/root/.config/nalar/skills" }` |
| `read_file.path` | Reads any file | `read_file { path: "/etc/passwd" }` |
| `write_file.path` | Writes anywhere | `write_file { path: "/etc/cron.d/agent-cron", content: "..." }` |
| `text_replace.path` | Patches anywhere | `text_replace { path: "/usr/bin/sudo", ... }` |
| `remove_file.path` | Deletes anything | `remove_file { path: "/home/user/.bashrc" }` |
| `glob.path` | Walks any tree | `glob { path: "/etc", pattern: "**/*.conf" }` |
| `search.path` | Searches any tree | `search { path: "/var/log", query: "password" }` |
| `get_skill.path` | Reads any `.md` | `get_skill { path: "/root/.ssh/authorized_keys" }` |

The user wants all of these **rejected** when the input is an absolute path.

---

## Goal

**Reject absolute paths** in any LLM-facing tool input that takes a path. The error must be clear enough that the agent retries with a relative path on the first try. The session's bound cwd (or worktree binding) is the trust anchor — paths outside it are unreachable.

### Behavior contract

1. **Tool input is absolute** → return an XML `<error>` block quoting the path, naming the rule ("absolute paths are not allowed (security); use a path relative to the session's working directory"), and naming the active cwd so the LLM can compute the relative path itself.
2. **Tool input is relative** → resolve against `ctx.cwd_override ?? ctx.cwd`, proceed as normal.
3. **Tool input omitted (where the schema allows)** → default to `ctx.cwd_override ?? ctx.cwd`.
4. **Bash/pwsh `command` string contains `/`** → **not validated**. The command is bounded by what `cwd` does — banning `/` inside commands would break `grep /etc/passwd` style operations and is impractical to parse. The `cwd` is the trust boundary.

---

## Scope

### Banned (relative-only after this change)

| Tool | Parameter | Notes |
|---|---|---|
| `bash` | `cwd` | Was REQUIRED-absolute → now OPTIONAL/relative. Becomes optional in JSON schema. |
| `pwsh` | `cwd` | Same as bash. |
| `list_skills` | `cwd` | Was REQUIRED-absolute → now OPTIONAL/relative. JSON schema already marks optional; doc string fixes only. |
| `read_file` | `path` | Was already "accepts both" → now RELATIVE ONLY. |
| `write_file` | `path` | Same. |
| `text_replace` | `path` | Same. |
| `remove_file` | `path` | Same. |
| `glob` | `path` | Same. Default value was `"."` — already relative. |
| `search` | `path` | Same. |
| `get_skill` | `path` | Same. Description already documents relative-path support; tighten it. |
| `list_directory` (new tool, parallel deliverable) | `path` | New tool — born relative-only. |

### Exceptions (stay absolute-only — admin tier)

| Tool | Parameter | Why it can't change |
|---|---|---|
| `set_git_worktree.path` | The path IS the new cwd binding | The agent's only "navigation" escape hatch. Banning absolute here means the agent can never change directories, which breaks every multi-project workflow. |
| `create_kanban_task.cwd` | Stored in DB column `workspace_item_tasks.cwd` (migration 070/071) | Set by the user (task creation), validated as starting with `/`. Cross-session read. Not LLM-writable in normal operation. |

### Out of scope (NOT changing)

- **Path traversal via `..`** — orthogonal concern. A relative path like `../../../etc/passwd` is still valid relative-path syntax and the agent can resolve it via `cd ../../../etc` in bash. Mitigating this is a separate audit; the current change is narrowly about the absolute-path ban.
- **Symlink resolution** — outside scope.
- **Sandboxing via `chroot`/`namespaces`** — outside scope; the trust boundary is the LLM-facing tool layer.

---

## Approach

### 1. New shared validator

A single helper in `src/modules/agent/tools/path_security.zig` (new file) that all tools call:

```zig
/// Returns the input path unchanged when it is relative.
/// Returns a fully-formed `<error>` block (in the LLM-facing tool-output
/// envelope) when the path is absolute — caller wraps that in
/// `wrapToolOutput(..., success=false, ...)` and bails out.
pub fn rejectAbsolutePath(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    param_name: []const u8,
    path: []const u8,
    active_cwd: []const u8, // for the error message
) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return path; // relative → ok
    return std.fmt.allocPrint(allocator,
        \\absolute paths are not allowed in {s} (security policy);
        \\use a path relative to the session's working directory.
        \\param: {s}
        \\rejected: {s}
        \\active cwd: {s}
    , .{ tool_name, param_name, path, active_cwd });
}

/// Resolve a relative (or null) path against the active cwd.
/// Returns the absolute path the caller should use.
pub fn resolveCwd(
    allocator: std.mem.Allocator,
    ctx_cwd: []const u8,
    ctx_cwd_override: ?[]const u8,
    raw: ?[]const u8,
) ![]u8 {
    const base = ctx_cwd_override orelse ctx_cwd;
    const path = raw orelse return allocator.dupe(u8, base);
    if (std.fs.path.isAbsolute(path)) unreachable; // validator MUST run first
    if (path.len == 0) return allocator.dupe(u8, base);
    return std.fs.path.join(allocator, &.{ base, path });
}
```

The validator returns the `<error>` text so the wrapper can pass it straight to `wrapToolOutput`. The resolver assumes the validator already ran.

### 2. Per-tool wiring

For each tool in the **Banned** table above, the exec wrapper (`src/ai_workflow/tui/agentic_loop/tools_exec_<name>.zig`) gains three lines after JSON parsing:

```zig
// 1. Validate every path-like field.
if (try nalarcore.tools.path_security.rejectAbsolutePath(
    ctx.allocator, "<name>", "path", parsed.value.path, ctx.cwd
)) |err_msg| {
    const output = try wrapToolOutput(ctx.allocator, "<name>", tc.function.arguments, false, err_msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// 2. Resolve cwd-relative paths against the active cwd (bash/pwsh/list_skills).
const resolved_cwd = try nalarcore.tools.path_security.resolveCwd(
    ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.cwd
);
defer ctx.allocator.free(resolved_cwd);
parsed.value.cwd = resolved_cwd; // for bash/pwsh this is the field name
```

**Tools without a cwd parameter** (read_file, write_file, etc.) only need the validator — no resolver.

### 3. New `list_directory` tool (parallel deliverable)

The original kanban task ("listing agent tool") becomes the natural test-case for the relative-path rule. Implementation reuses `SystemFolder.listDirectory` and adds relative-path validation:

```
name: list_directory
input: {
  path: string              // REQUIRED — relative to session cwd (or "." for cwd itself)
  hidden?: bool = false
  respect_ignore_files?: bool = true
}
output: XML wrapped in <directory_listing>...</directory_listing>
```

The new tool's `path` is validated by the shared validator (rejects `/foo`), then resolved against `ctx.cwd_override ?? ctx.cwd` before being passed to `SystemFolder.listDirectory` (which calls `openDirAbsolute`).

### 4. Tool descriptions — update every Banned tool

Replace `"Absolute working directory. Always set explicitly."` etc. with a consistent shape:

> `"Working directory. Relative paths only (absolute paths are rejected — security policy). Paths resolve against the session's working directory (or the active git-worktree binding if set). Omit to default to the session's working directory."`

For `set_git_worktree` (the exception), add a note: *"This is the only tool that accepts absolute paths — it is the admin-tier escape hatch for navigating outside the session's cwd."*

### 5. Agent system prompt — `src/modules/agent/prompts.zig`

Find every site that instructs the LLM to use absolute paths and replace with relative-path instructions. Concretely:

- The tool listing section is data-driven from the `AgentTool` schemas, so the updated tool descriptions propagate automatically.
- The "Available Skills" / "Local Knowledge" / "Global Knowledge" sections currently emit absolute memory paths for the agent to copy into `read_file` etc. **These absolute-path code-spans must be converted to relative paths** OR the agent must be told to strip the leading `/<active-cwd>/` prefix before passing to `read_file`. The chosen approach (see below) is the latter — add one line to the agent prompt: *"memory file paths shown in this prompt are absolute; strip the `<active cwd>` prefix before passing to read_file/write_file/text_replace."*

### 6. Tests

For each Banned tool, add **two** regression tests:

1. `* exec rejects absolute path with explanatory error` — pass `path: "/etc/passwd"`, assert the result contains `<error>...absolute paths are not allowed...`.
2. `* exec accepts relative path and resolves against ctx.cwd` — set up a temp dir, pass `path: "subdir/foo.txt"`, assert the file was read/written.

For `list_directory`, add the full coverage matrix from `system_folder_test.zig::listDirectory` plus the absolute-path rejection case.

`zig build test --summary all` must continue to be 0 fail (existing `execute_bash(absolute_cwd)`-style tests keep working — validation is in the exec wrapper, not in the tool function).

---

## Wire shape (final)

### `bash` tool schema after this change

```json
{
  "name": "bash",
  "description": "Execute a bash command and return: stdout, stderr, exit_code, truncated, timeout flags. ...",
  "parameters": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "..." },
      "cwd": {
        "type": "string",
        "description": "Working directory. Relative paths only (absolute paths are rejected — security policy). Resolved against the session's cwd (or the active git-worktree binding if set). Omit to default to the session's cwd."
      },
      "mandatory_timeout": { "type": "number", "description": "..." },
      "max_output": { ... },
      "stdin_data": { ... },
      "background": { ... },
      "max_lines": { ... },
      "do_encoding": { ... }
    },
    "required": ["command", "mandatory_timeout"]
  }
}
```

(Note: `cwd` removed from `required`. `command` + `mandatory_timeout` stay required.)

### Error envelope (final)

When the LLM passes an absolute path:

```xml
<tool_use_error>
<error>absolute paths are not allowed in bash (security policy); use a path relative to the session's working directory.
param: cwd
rejected: /etc
active cwd: /home/user/project</error>
</tool_use_error>
```

(Standard `wrapToolOutput` envelope — `success=false`, the `<error>` body is the rejected path + the resolution rule + the active cwd.)

---

## Files to change

### New files
- `src/modules/agent/tools/path_security.zig` — validator + resolver
- `src/modules/agent/tools/list_directory.zig` — new tool
- `src/modules/agent/tools/list_directory_test.zig` — tests for the new tool
- `src/modules/agent/tools/path_security_test.zig` — tests for the shared validator
- `src/ai_workflow/tui/agentic_loop/tools_exec_list_directory.zig` — exec wrapper
- `docs/superpowers/specs/2026-08-14-ban-absolute-paths-design.md` — this file
- `docs/superpowers/plans/2026-08-14-ban-absolute-paths.md` — implementation plan

### Modified files
- `src/root.zig` — export `path_security` and `list_directory` modules
- `src/modules/agent/tools/bash.zig` — update `cwd` description, remove from `required`
- `src/modules/agent/tools/pwsh.zig` — same
- `src/modules/agent/tools/list_skills.zig` — update `cwd` description
- `src/modules/agent/tools/get_skill.zig` — tighten `path` description
- `src/modules/agent/tools/set_git_worktree.zig` — note the exception in the description
- `src/ai_workflow/tui/agentic_loop/tools_exec_bash.zig` — add validation + resolution
- `src/ai_workflow/tui/agentic_loop/tools_exec_pwsh.zig` — same
- `src/ai_workflow/tui/agentic_loop/tools_exec_list_skills.zig` — same
- `src/ai_workflow/tui/agentic_loop/tools_exec_read_file.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_write_file.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_text_replace.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_remove_file.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_glob.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_search.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools_exec_get_skill.zig` — add validation
- `src/ai_workflow/tui/agentic_loop/tools.zig` — re-export `execListDirectory`
- `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — register `list_directory` in `equips()` + `UNIFIED_TOOL_REGISTRY()`
- `src/modules/agent/test_runner.zig` — register new test modules
- `src/modules/agent/prompts.zig` — update tool-listing instructions (data-driven; mostly propagates automatically)

### NOT changing
- `src/modules/agent/tools/set_git_worktree.zig` — except the description annotation
- `src/modules/agent/tools/create_kanban_task.zig` — already validates absolute cwd; no schema change
- Underlying tool functions (`bash.execute_bash`, `read_file.read_file`, etc.) — validation is in the exec wrapper, not the tool function. Existing tests that call tool functions directly keep passing.

---

## Test plan

### New tests
1. `path_security_test.zig`
   - `rejectAbsolutePath: returns path unchanged when relative`
   - `rejectAbsolutePath: returns error envelope when absolute`
   - `rejectAbsolutePath: handles edge values "./", "../", ""`
   - `resolveCwd: null/empty raw → returns base cwd`
   - `resolveCwd: relative raw → joins against base`
   - `resolveCwd: ctx_cwd_override wins over ctx_cwd`
2. `bash_exec_test.zig` — `* rejects absolute cwd`, `* resolves relative cwd`
3. `pwsh_exec_test.zig` — same
4. `list_skills_exec_test.zig` — `* rejects absolute cwd`, `* resolves relative cwd`
5. `read_file_exec_test.zig`, `write_file_exec_test.zig`, `text_replace_exec_test.zig`, `remove_file_exec_test.zig`, `glob_exec_test.zig`, `search_exec_test.zig`, `get_skill_exec_test.zig` — `* rejects absolute path`
6. `list_directory_test.zig`
   - `* rejects absolute path`
   - `* lists entries in relative path`
   - `* respects gitignore`
   - `* hidden flag toggles dotfiles`

### Verification gate
- `zig build test --summary all` → 0 fail (same baseline as today, ~2264 pass)
- New tests above all pass

---

## Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Existing tests call `bash.execute_bash(absolute_cwd)` — would now be rejected if validation moved into the tool function | Low (we're validating in the exec wrapper, not the function) | Confirmed: validation is in `tools_exec_*.zig`. Existing `bash_test.zig` tests pass absolute cwd to `execute_bash` directly and keep working. |
| LLM takes N retries to learn the new rule | Medium | The error envelope names the rejected path AND the active cwd, so the LLM can compute the relative path on retry. Plus the prompt updates. |
| Agent prompt's "Available Skills" / "Local Knowledge" sections emit absolute memory paths the LLM used to copy into `read_file` — now those calls get rejected | Medium | Add a one-line instruction in the prompt: "memory file paths shown in this prompt are absolute; strip the `<active cwd>` prefix before passing to read_file/write_file/text_replace." |
| `set_git_worktree` accidentally becomes the "real" way to escape, defeating the sandbox | Low | The worktree path is bound to a specific git repo (worktrees cannot be created outside an existing repo). Even if the agent navigates, it's still inside one repo. Document this as the deliberate trust boundary. |
| `create_kanban_task.cwd` (absolute-only) lets a malicious user-set task trick the agent into trusting absolute paths later | Very low | The cwd is set at task-creation by a human, not the LLM. Out of scope. |

---

## Open questions for the user

None — the design is locked by the prior Q&A:
- Scope: **B** (all path-accepting tools)
- Behavior: **1** (hard error, no coercion)
- Exceptions: **both stay absolute** (`set_git_worktree`, `create_kanban_task.cwd`)

---

## Verification (for this design doc)

- [ ] Spec saved at `docs/superpowers/specs/2026-08-14-ban-absolute-paths-design.md`
- [ ] User has reviewed the spec
- [ ] No code has been touched yet
- [ ] Next step: `writing-plans` skill creates `docs/superpowers/plans/2026-08-14-ban-absolute-paths.md`