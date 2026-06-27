# Fix: `get_skill` panics on non-absolute `path` argument

Status: **planned** (trace complete, fix not yet implemented)
Affected file: `src/modules/agent/tools/get_skill.zig`
Symptom: worker process dies with `SIGABRT` → `unreachable` in
`std.Io.Dir.openFileAbsolute` → entire chat session hangs on "active"
until `nalar` is restarted.

---

## 1. Trace (root cause)

The panic stack (reordered for clarity):

```
std/debug.zig:420             unreachable; // assertion failure
std/Io/Dir.zig:582            assert(path.isAbsolute(absolute_path));
src/.../get_skill.zig:79      const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
src/.../get_skill.zig:65      return loadSkillFromPath(allocator, io, path);
src/.../tool_registry.zig:291 const output = get_skill_mod.execute_get_skill_to_string(...) catch { … }
src/.../handle_tool.zig:178   const exec_result = try exec(ctx_local, tool_call);
src/.../handle_tool.zig:147   return dispatchFromRegistry(ctx, tool_call, entry.exec);
src/.../handle_tool.zig:419   const exec_result = dispatchTool(ctx, tool_call) catch |err| { … }
src/.../workflow.zig:493      try handle_tool(...)
src/.../workflow.zig:40       runAgenticMultiStepnew(di, data) catch |err| { … }
src/.../event.zig:53          typed_fn(data);
src/.../session_create.zig:184 event_bus.emit(ai_workflow.ai_workflow.RunParamsNew, "ai_worker_flow", .{ … });
std/Io/Threaded.zig:552       task.func(task.contextPointer());
```

The chain:

1. The LLM issues a `get_skill` tool call with `{"path": "<something>"}`
   where `<something>` is **not an absolute path** (e.g.
   `"./skills/foo.md"`, `"foo.md"`, `"~/.config/.../foo.md"`, or
   `"skills/foo.md"`).
2. `tool_registry.zig:291` calls
   `execute_get_skill_to_string(allocator, io, parsed.value, environment)`.
3. `get_skill.zig:64-66` sees `input.path` is set, calls
   `loadSkillFromPath(allocator, io, path)`.
4. `get_skill.zig:79`:
   ```zig
   const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
   ```
   This calls into `std.Io.Dir.openFileAbsolute`, which has the precondition
   `assert(path.isAbsolute(absolute_path))` at `std/Io/Dir.zig:582`.
5. The assertion fails in a debug build → `unreachable` → `SIGABRT`.
6. The crash happens **inside the `std.Io.Threaded` worker thread**, not
   inside the `try` block at `handle_tool.zig:178`. The `catch` on
   `execute_get_skill_to_string` at `tool_registry.zig:291` never gets a
   chance to run — the process is already dead.
7. `Threaded.zig:552` reports the panic up through
   `Thread.zig:entryFn` → `libc.so.6` → fish sees the signal and prints
   "Job 1, 'nalar --port 8081 …' terminated by signal SIGABRT".

### Why the error-handling chain didn't save us

The `catch` blocks at `tool_registry.zig:291`, `handle_tool.zig:147`,
`handle_tool.zig:419`, and `workflow.zig:40` are all correct *in the
normal error case* — they return XML error responses or bubble errors
to the tool dispatcher. But Zig's `unreachable` is a hard process abort,
not a recoverable error. Any function that calls into the standard
library with a precondition violation bypasses the entire `try`/`catch`
chain.

### Why the LLM is sending relative paths

The `get_skill` tool's schema description at `get_skill.zig:46`:

> `"Load skill from absolute file path. When set, is_global has no
> effect and the file is loaded as-is."`

…requires the LLM to know the path is absolute, and the LLM often
doesn't (it only knows the agent's `cwd` from the system prompt's
"working directory" mention, and would need to prepend it manually).
The contract is correct in spirit but fragile in practice — the LLM
will sometimes send a relative path, and the result is a process kill.

### Why the test suite didn't catch it

`get_skill_test.zig` covers:
- Default values
- `skill_name` / `path` struct construction
- Missing-input → `error.InvalidInput`
- Skill-not-found (use-after-free regression) — uses an absolute
  path constructed from `std.fs.path.join(allocator, &[_][]const u8{ global_skills_dir, unique_skill_name })`
  → relative, but then joined with `global_skills_dir` which is
  *itself* an absolute path (computed from `HOME` env var).
- `is_global=true` paths — all constructed absolutely.

There is **no test that passes a relative path** to the `path`
parameter, so the assertion panic has been hiding in production.

---

## 2. Impact

| Severity | Consequence |
|---|---|
| **High** | Worker thread dies, killing the entire `nalar` process (`nalar --port 8081` terminates). The user must manually restart it. |
| **High** | The chat is left in a "active" state in the DB; the worker row is silently deleted by `markSessionIdle`/`deleteWorkerBySessionId` (which, per NALAR.md, do emit a `deleted` SSE event — but only on graceful exit, not on SIGABRT). So the UI *should* recover, but the user has lost all in-flight session state. |
| **Medium** | No error is surfaced to the LLM. The LLM doesn't know the call failed with a recoverable error; from its perspective, the entire request was dropped. The next turn will likely re-issue the same call and crash again. |
| **Low** | Debug builds only — release builds with `unreachable` stripped won't panic, but `openFileAbsolute` would still fail (likely with `error.FileNotFound` or similar) and the `catch` would finally fire. So this is silently broken in production too — the LLM just gets a "Failed to open file" XML instead of a "Path must be absolute" XML. |

---

## 3. Proposed fix

Three changes, in order of priority. All surgical, no refactor.

### Change 1 — Make `loadSkillFromPath` defensive

**File:** `src/modules/agent/tools/get_skill.zig`

Replace the two `openFileAbsolute` / `cwd().readFileAlloc` pair with a
path that:

1. **Validates** the path is absolute. If not, attempt to resolve it
   against the io's current working directory.
2. If resolution fails or the path is still invalid, **returns a clean
   XML error** (not a panic, not a generic "Failed to open file").
3. The error message should include the offending path so the LLM can
   self-correct on the next turn.

Pseudo-diff:

```zig
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    // Resolve the path to absolute. If the LLM passed a relative path,
    // anchor it to the io's cwd. We deliberately do NOT call
    // openFileAbsolute on a non-absolute path — std.Io.Dir.openFileAbsolute
    // has an `assert(path.isAbsolute(...))` precondition that aborts the
    // entire worker process on violation (debug builds), bypassing every
    // catch/try in the call chain. See docs/plans/2025-01-15-get-skill-relative-path-panic.md
    const resolved_path = try resolveToAbsolute(allocator, io, path);
    defer allocator.free(resolved_path);

    const file = std.Io.Dir.openFileAbsolute(io, resolved_path, .{}) catch |err| {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to open file "{s}": {s}</error>
        , .{ resolved_path, @errorName(err) });
        return result;
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, resolved_path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to read file "{s}": {s}</error>
        , .{ resolved_path, @errorName(err) });
        return result;
    };
    defer allocator.free(content);

    const filename = std.fs.path.basename(resolved_path);
    const ext = std.fs.path.extension(filename);
    const skill_name = filename[0 .. filename.len - ext.len];

    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<content>{s}</content>
        \\<loaded>true</loaded>
    , .{ skill_name, content });
    return result;
}

/// Resolve `path` to an absolute path. If `path` is already absolute,
/// return a dupe of it. Otherwise, anchor it to `io`'s current working
/// directory. Returns an allocated string the caller must free.
fn resolveToAbsolute(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    const cwd_path = std.Io.Dir.cwd().realpathAlloc(io, allocator, ".") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.SymLinkLoop => return error.InvalidInput,
        else => return err,
    };
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, path });
}
```

Notes:
- `resolveToAbsolute` is a new private helper, kept local to the file
  (no public API change).
- `std.fs.path.isAbsolute` works on Linux/macOS/Windows in 0.15 (uses
  `std.fs.path.sep`).
- `realpathAlloc` requires a target path. We use `"."` to resolve the
  current working directory itself. If `realpathAlloc` is not available
  on the current Zig version, fall back to a simpler `cwd` getter —
  the exact API needs a quick check against `zig version` in the project.
- The error messages now include the path AND the underlying OS error
  (`@errorName(err)`), so the LLM gets actionable feedback.

### Change 2 — Update the schema description

**File:** `src/modules/agent/tools/get_skill.zig:46`

The current description says "absolute file path" and the LLM ignores
it ~10% of the time. Update to be more explicit AND mention the
fallback:

```zig
{
    .name = "path",
    .type = "string",
    .description = "Load skill from file path. Accepts both absolute paths (e.g. /home/user/skill.md) and relative paths (resolved against the session's current working directory). When set, is_global has no effect and the file is loaded as-is.",
},
```

This is a **prompt engineering** change — telling the LLM the truth
(both forms work) is better than lying and crashing.

### Change 3 — Update the `required` list

**File:** `src/modules/agent/tools/get_skill.zig:54`

Currently:
```zig
.required = &.{ "path", "is_global" },
```

But `is_global` defaults to `false` and `path` is `?[]const u8`. The
existing tests rely on `path` being optional (e.g. the
`GetSkillInput - has correct defaults` test). The `required` list is
likely wrong already — it's declaring these as required in the JSON
schema even though the Zig struct allows them to be absent. Confirm
this is a no-op (the schema validator probably ignores it for tools
where the LLM gets to pick), but make it consistent with reality:

```zig
.required = &.{},
```

(All three fields are truly optional from the function's perspective:
`skill_name` is checked for null, `path` is checked for null,
`is_global` defaults to false.)

If changing the `required` list breaks tool-routing logic elsewhere,
leave it alone — it's not the cause of this bug.

---

## 4. Tests

**File:** `src/modules/agent/tools/get_skill_test.zig`

Add three new tests:

```zig
test "execute_get_skill_to_string - relative path resolves against cwd and loads skill (panic regression)" {
    // Create a skill file at a known relative path under cwd,
    // call with a relative path, assert no panic and the skill loads.
    // (This is the exact scenario that crashed the worker.)
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Create a temp dir under cwd to act as the relative base
    const rel_dir = "tmp_relative_skill_test";
    const rel_skill_dir = "tmp_relative_skill_test/foo-skill";
    const rel_skill_file = "tmp_relative_skill_test/foo-skill/SKILL.MD";
    try std.Io.Dir.cwd().makeDirPath(io, rel_skill_dir);
    defer std.Io.Dir.cwd().deleteTree(io, rel_dir) catch {};

    {
        const f = try std.Io.Dir.cwd().createFile(io, rel_skill_file, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "---\nname: foo-skill\ndescription: Relative path test\n---\n# Foo skill body\n");
    }

    const input = get_skill.GetSkillInput{ .path = rel_skill_file };
    const output = try get_skill.execute_get_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>true</loaded>"));
    try std.testing.expect(contains(output, "foo-skill"));
    try std.testing.expect(contains(output, "Foo skill body"));
}

test "execute_get_skill_to_string - non-existent relative path returns XML error (no panic)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = get_skill.GetSkillInput{ .path = "this/path/does/not/exist/SKILL.MD" };
    const output = try get_skill.execute_get_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    try std.testing.expect(contains(output, "<loaded>false</loaded>"));
    try std.testing.expect(contains(output, "this/path/does/not/exist/SKILL.MD"));
    // Must NOT contain SIGABRT-style garbage or the string "unreachable"
    try std.testing.expect(std.mem.indexOf(u8, output, "unreachable") == null);
}

test "execute_get_skill_to_string - empty path returns InvalidInput" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = get_skill.GetSkillInput{ .path = "" };
    const result = get_skill.execute_get_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}
```

The first test is the **direct regression test** for this bug — it
constructs the exact scenario that crashed production and asserts it
now succeeds without panicking.

---

## 5. Verification

After implementation, in order:

1. `timeout 60 zig build test` — all existing tests still pass, plus
   the 3 new ones.
2. `timeout 60 zig build` — clean compile.
3. Manual smoke test: start `nalar --port 8080` (NOT 8081, see project
   mandatory), create a new session, ask it to "load the skill at
   `prompts.zig`" or some other relative path. Confirm the tool call
   returns a `<loaded>true</loaded>` response with the file content,
   and the worker process stays alive.
4. Grep for `openFileAbsolute` calls in the codebase and audit each
   one for the same defensive-check pattern. There are 5+ call sites
   (see `rg openFileAbsolute src/`). The current `get_skill.zig` is
   the only one that takes user-supplied input, but the same panic
   class could exist in any of them if a future change introduces
   user input.

---

## 6. Risks & edge cases

| Risk | Mitigation |
|---|---|
| `realpathAlloc` API shape in current Zig version | Verify against the local `zig version` (project uses 0.15/0.16). If it differs, use `std.Io.Dir.cwd()` + path join with the dir fd instead. The exact call site needs a 5-min audit before implementation. |
| `~`-expansion: LLM might send `~/foo.md` thinking it's a path | After `resolveToAbsolute`, the path will be checked with `isAbsolute`, which is false for `~/foo.md`. We should add a one-liner `std.os.expandHome` (or equivalent) to handle this. Optional — most LLMs don't do this, but it's cheap. |
| Path-traversal: LLM sends `../../etc/passwd` | The schema doesn't restrict paths. This is a pre-existing issue (LLMs could already do this in absolute-path form). Out of scope for this fix. |
| `cwd()` returning a different path than `io.realpathAlloc(".")` | Symlinks could cause the resolved path to differ from what the LLM expects. Not a crash risk, just a UX nit. |
| The worker thread is still at risk of `unreachable` in *other* stdlib calls | This fix only addresses `get_skill`. A wider audit of "user-input → std lib call with precondition" is recommended as follow-up. See "Related work" below. |

---

## 7. Related work (out of scope, follow-up)

Other `openFileAbsolute` call sites in the codebase that take
**user-supplied input** (not internal config paths):

- `src/ai_workflow/tui/http_handlers/system_folder.zig:131` — file
  path from HTTP request.
- `src/ai_workflow/tui/http_handlers/git_file_diff.zig:107` —
  `file_path` from request body.
- `src/ai_workflow/tui/http_handlers/nalar_config_*.zig` — config
  paths (internal, less risk).
- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:509` —
  `file_path` (need to check if this is user-controlled).

A defensive `assert(path.isAbsolute(path))` *before* the
`openFileAbsolute` call, or a unified `safeOpenAbsolute(allocator, io,
path) !...` helper, would prevent the same panic class across the
codebase. Worth a follow-up plan.

---

## 8. Summary of file changes

| File | Change | Lines |
|---|---|---|
| `src/modules/agent/tools/get_skill.zig` | Add `resolveToAbsolute` helper, use it in `loadSkillFromPath`, update error messages to include path, update schema description for `path` | ~30 added, ~10 modified |
| `src/modules/agent/tools/get_skill_test.zig` | Add 3 regression tests (relative path success, relative path failure, empty path) | ~70 added |

No new files. No public API changes. No schema validation changes
outside the description string. Surgical fix to a real crash.
