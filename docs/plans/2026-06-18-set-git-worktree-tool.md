# `set_git_worktree` Tool + `sessions.git_worktree_cwd` Column

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new agent tool `set_git_worktree` that creates a `git worktree` at an **absolute path** the LLM provides (e.g. `/home/me/projects/myapp/.worktrees/auth-fix` or `/tmp/experiments/rpc-rewrite` — any folder the LLM wants). The path is the primary input; the worktree doesn't have to live under `.worktrees/`. The branch is derived from the path's basename (`worktree/<basename>`) and can be overridden. The worktree's path is then bound to the current session as `sessions.git_worktree_cwd` and the workflow's `ctx.cwd` is overridden to the worktree path so every subsequent bash/read_file/text_replace/etc. operates on the isolated checkout. Calling the tool again with a different `path` switches the binding to that worktree. Passing `clear=true` removes the worktree directory and the binding.

**Architecture:** Add the column via Migration 046, mirror the existing `add_skill` tool shape (input struct + `AgentTool` definition + `executeXToString` returning standardized `<tool>` XML, plus a thin `execX` wrapper in `tool_registry.zig`). Wire the new column through `SessionTableInfo`, `SessionBroadcastInfo`, `OnEventInputSessions`, `updateSessionGitWorktreeCwd`, every `getSession*` SELECT, and every `onEventSendSessions(...)` call site. The ChatsList sidebar grows a 🌳 badge on sessions that have a non-empty `git_worktree_cwd`. Frontend types and the SSE `SessionEvent` interface are extended in lockstep.

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. Zig 0.16 + `std.Io.Threaded`. No new dependencies.

---

## Design decisions locked during brainstorming

1. **Tool name = `set_git_worktree`** (verb-form, matches `set_agent_properties`). NOT `use_worktree` or `create_worktree` — the user wants to "set" the session's working copy, with the side effect of creating the worktree.
2. **Worktree path = absolute path the LLM provides.** Any folder, anywhere on the filesystem. The `using-git-worktrees` skill's preference for `.worktrees/` (project-local, hidden) is a *default convention* the LLM may follow, but it's NOT enforced — the LLM can use `/tmp/foo`, `~/experiments/x`, or any other absolute path it wants. The path's **parent directory must already exist** (git won't auto-create it); if it doesn't, the tool returns `<error>parent directory does not exist: <path></error>`.
3. **Branch name = `worktree/<basename(path)>`** (e.g. `path = /abs/.worktrees/auth-fix` → `branch = worktree/auth-fix`). Derived from the path's basename so the branch and folder are linked by convention. Optional `branch` parameter overrides the default when the LLM wants a different branch.
4. **One ACTIVE worktree per session at a time** (1:1 over time, NOT over calls). Calling the tool again with a DIFFERENT `path` switches the binding to the new worktree (the old one is left on disk; the user can `clear` it explicitly). Calling with the SAME `path` is a no-op (idempotent re-bind). This allows the LLM to hop between worktrees mid-session without explicit cleanup.
5. **`path` validation rules:** MUST be absolute (`/foo/bar`); MUST NOT contain `..` (no path traversal); MUST be ≤ 4096 chars; MUST NOT contain null bytes; the parent directory must exist on disk. Invalid paths return `<error>invalid path: <reason></error>`. The **basename** is also checked: only `[A-Za-z0-9._-]{1,100}` (no spaces, no path separators) — this keeps the auto-derived branch name legal. Invalid basenames return `<error>invalid basename: <reason></error>`.
6. **CWD override applies to bash/read/write/text_replace/glob/search** for the rest of the session — but NOT to `bash` background-process tracking, NOT to `spawn_sub_agent` (the child session gets the parent's `cwd`, matching the existing semantics), and NOT to the frontend's HTTP request handling. The override is in-memory on `ctx.cwd`; the `sessions.git_worktree_cwd` column is the source of truth.
7. **Clearing = `clear=true` only** (no empty-string form — `path` is always required when setting). `clear=true` removes the worktree directory AND clears the binding. The old plan's "empty path = clear" convenience form is dropped because the new design has a single, explicit `path` parameter.
8. **Failure modes return XML `<error>`** in the existing `<tool>` envelope (per `wrapToolOutput` in `tool_registry.zig`). No new error-handling infrastructure. The `using-git-worktrees` skill's "Smart directory selection" is the source of truth for what counts as a "valid" worktree path.
9. **Tool is auto-added to MAIN agent only** (not sub-agents). Sub-agents inherit the parent's `cwd` and work on the same checkout. This avoids the complexity of nested worktrees.
10. **Migration is 046** (last is 045). Single `ALTER TABLE sessions ADD COLUMN git_worktree_cwd TEXT` (nullable, default NULL → empty string in app code via `COALESCE`).
11. **SSE event is the existing `sessions/stream` topic.** A `session.updated` event with the new `git_worktree_cwd` field fires on every set/clear. The frontend `ChatsList.vue` already updates its `selected_profile_model` from these events — copy that pattern for `git_worktree_cwd`.

## Data model

### Migration 046 (add to `src/ai_workflow/tui/migration.zig`)

```zig
pub const Migration046AddGitWorktreeCwdToSessions = struct {
    pub const version: u32 = 46;
    pub const name = "add_git_worktree_cwd_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Nullable: NULL means "no worktree bound". The application code
        // maps NULL → "" via COALESCE for the API surface, matching the
        // convention used for `cwd`, `created_at`, `updated_at`, and
        // `selected_profile_model` (see llm_history.zig:1802).
        try db.exec(allocator,
            "ALTER TABLE sessions ADD COLUMN git_worktree_cwd TEXT",
            &[_][]const u8{});
    }
};
```

Register in `allMigrations` after Migration045 (line 911):
```zig
.{ .version = Migration046AddGitWorktreeCwdToSessions.version, .name = Migration046AddGitWorktreeCwdToSessions.name, .up = Migration046AddGitWorktreeCwdToSessions.up },
```

### Backwards compatibility

- Existing rows get `git_worktree_cwd = NULL`. The app code treats NULL as "" everywhere (via `COALESCE(git_worktree_cwd, '')`).
- The `getSession` SELECT (line 1802) gains a new `COALESCE(git_worktree_cwd, '')` column; `SessionTableInfo` gets a new `git_worktree_cwd: []u8` field; `deinit` frees it.
- The `getSessionsForBroadcast` SELECT (line 2651) gains the same column; `SessionBroadcastInfo` gets the same field.
- The `onEventSendSessions(...)` input struct (in `on_event_sent.zig:103`) gains a `git_worktree_cwd: []const u8 = ""` field. All 5 existing call sites are updated to pass `s.git_worktree_cwd`.

### File structure

#### New files

```
src/modules/agent/tools/
├── set_git_worktree.zig                (input struct + tool_def + execute function)
└── set_git_worktree_test.zig           (static + behavioral tests for the tool)

src/ai_workflow/tui/
└── migration_git_worktree_test.zig     (behavioral test for Migration 046)
```

#### Modified files

```
src/ai_workflow/tui/
├── migration.zig                       (add Migration046AddGitWorktreeCwdToSessions + register)
├── llm_history.zig                     (SessionTableInfo.git_worktree_cwd + SessionBroadcastInfo + getSession SELECT + getSessionsForBroadcast SELECT + new updateSessionGitWorktreeCwd function)
├── on_event_sent.zig                   (OnEventInputSessions.git_worktree_cwd field)
├── handle_tool.zig                     (no change — execX lives in tool_registry.zig)
├── tool_registry.zig                   (add set_git_worktree_mod import, execSetGitWorktree function, register in UNIFIED_TOOL_REGISTRY + allAgentTools)
├── test_runner.zig                     (register set_git_worktree_test.zig + migration_git_worktree_test.zig)
└── workflow.zig                        (apply ctx.cwd override when session.git_worktree_cwd is set; restore on clear)

src/modules/agent/tools/
└── tools.zig                           (re-export set_git_worktree + set_git_worktree_tool)

src/root.zig                            (re-export set_git_worktree under a new nalarcore.set_git_worktree alias — mirrors add_skill pattern at line 354)

src/apps/desktop/src/
├── api/index.ts                        (extend Session + SessionEvent interfaces with git_worktree_cwd)
├── components/ChatsList.vue            (render 🌳 badge when git_worktree_cwd is non-empty; update on SSE event)
└── stores/workspaces.ts                (no change — sessions stay where they are; this is a cosmetic field)

docs/plans/2026-06-18-set-git-worktree-tool.md   (this file)
```

---

## Verification commands (run throughout)

```bash
# Backend (Zig)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 40

# Frontend type-check + bundle (per project NALAR.md memory — bun run build
# is the authoritative type check, NOT vitest)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20

# Frontend unit tests
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 20

# Manual smoke test (after starting nalar in a separate terminal on port 8080)
# 1) Create a session, get its id from /api/sessions
# 2) Ask the agent in chat: "call set_git_worktree for this session"
# 3) Verify the worktree directory exists and `git worktree list` shows it
# 4) curl /api/sessions and confirm git_worktree_cwd is populated
# 5) Ask the agent to "clear the worktree binding" — verify the directory is removed
#    and git_worktree_cwd is empty in the response
```

Per the project's `desktop-typescript-bun-build-as-typecheck` memory: **Always run `bun run build` (NOT just `bunx vitest run`)** — vitest uses esbuild which strips types, so TS2532 errors only surface during `vue-tsc --build`.

---

## Chunk 1: Migration 046 + DB column plumbing

Add the new column and thread it through every read/write of the `sessions` table.

- [ ] **Step 1.1: Add `Migration046AddGitWorktreeCwdToSessions` to `src/ai_workflow/tui/migration.zig`**

Place it after `Migration045AddPositionToWorkspaceItems` (line ~700). Pattern matches `Migration040AddSelectedProfileModelToSessions` (line 619). Use `ADD COLUMN` (no `IF NOT EXISTS` — SQLite <3.35 doesn't support it, and the project doesn't use it elsewhere).

- [ ] **Step 1.2: Register in `allMigrations` slice (line ~911)**

Add the entry:
```zig
.{ .version = Migration046AddGitWorktreeCwdToSessions.version, .name = Migration046AddGitWorktreeCwdToSessions.name, .up = Migration046AddGitWorktreeCwdToSessions.up },
```

- [ ] **Step 1.3: Add behavioral test `src/ai_workflow/tui/migration_git_worktree_test.zig`**

Mirror `migration_routines_test.zig` exactly:
- `setupDb()` opens `:memory:` via `std.Io.Threaded + db.init(io, ":memory:")`, creates the `sessions` table with the SAME shape Migration 017 leaves it (id, name, status) plus the columns Migration 022/025/029/040 add (cwd, workspace_id, created_at, updated_at, selected_profile_model). Just running the migration against a fresh in-memory DB is the test target — we don't need every preceding migration.
- Test 1: `Migration046AddGitWorktreeCwdToSessions adds git_worktree_cwd column` — after the migration, insert a row, assert `SELECT git_worktree_cwd` returns empty (NULL → empty via the test harness's `scalarText` helper).
- Test 2: `Migration046AddGitWorktreeCwdToSessions accepts explicit value` — after the migration, `UPDATE sessions SET git_worktree_cwd = '/tmp/x'` and assert the value round-trips.

Register in `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("migration_git_worktree_test.zig");
```

- [ ] **Step 1.4: Extend `SessionTableInfo` in `src/ai_workflow/tui/llm_history.zig` (line ~1746)**

Add `git_worktree_cwd: []u8` to the struct. Update `deinit` to free it:
```zig
pub fn deinit(self: SessionTableInfo, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.name);
    allocator.free(self.status);
    allocator.free(self.cwd);
    allocator.free(self.created_at);
    allocator.free(self.updated_at);
    allocator.free(self.selected_profile_model);
    allocator.free(self.git_worktree_cwd);  // NEW
}
```

- [ ] **Step 1.5: Extend `getSession` SELECT (line 1802)**

Add the column. The current SQL is:
```sql
SELECT id, name, status, COALESCE(cwd, ''), COALESCE(created_at, ''), COALESCE(updated_at, ''), COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?
```

Becomes:
```sql
SELECT id, name, status, COALESCE(cwd, ''), COALESCE(created_at, ''), COALESCE(updated_at, ''), COALESCE(selected_profile_model, ''), COALESCE(git_worktree_cwd, '') FROM sessions WHERE id = ?
```

Update the row mapping (line 1807) to read `row.values[7]` and `dupe` it into the new field.

- [ ] **Step 1.6: Extend `create_session` (line 1765)**

The returned `SessionTableInfo` literal at line 1786 must include `git_worktree_cwd = try allocator.dupe(u8, "")`. The `onEventSendSessions` call at line 1775 must pass `git_worktree_cwd = ""` (the `OnEventInputSessions` field is added in Step 1.8).

- [ ] **Step 1.7: Extend `getSessionsForBroadcast` (line 2647)**

Add `COALESCE(git_worktree_cwd, '')` to the SELECT, set the new field on `SessionBroadcastInfo`, free it in `freeSessionsForBroadcast`.

Also extend `SessionBroadcastInfo` (line 91) with `git_worktree_cwd: []const u8`.

- [ ] **Step 1.8: Extend `OnEventInputSessions` in `src/ai_workflow/tui/on_event_sent.zig` (line 103)**

```zig
pub const OnEventInputSessions = struct {
    action: []const u8,
    id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    selected_profile_model: []const u8 = "",
    git_worktree_cwd: []const u8 = "",  // NEW
};
```

- [ ] **Step 1.9: Update every `onEventSendSessions` call site (5 sites)**

Locations (grep `onEventSendSessions`):
- `llm_history.zig:1775` (create_session) — add `.git_worktree_cwd = ""`
- `llm_history.zig:1838` (update_session_status) — add `.git_worktree_cwd = s.git_worktree_cwd`
- `llm_history.zig:1865` (updateSessionName) — add `.git_worktree_cwd = s.git_worktree_cwd`
- `llm_history.zig:1932` (updateSessionSelectedProfileModel) — add `.git_worktree_cwd = s.git_worktree_cwd`
- `llm_history.zig:1955` (delete_session) — add `.git_worktree_cwd = ""`

- [ ] **Step 1.10: Add `updateSessionGitWorktreeCwd` to `llm_history.zig` (after line 1943, next to `updateSessionSelectedProfileModel`)**

```zig
/// Update session git_worktree_cwd. Pass empty string or null to clear.
/// When the value changes, broadcast a session.updated SSE event so the
/// ChatsList sidebar updates its 🌳 badge in real time.
pub fn updateSessionGitWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    git_worktree_cwd: ?[]const u8,
) !void {
    const effective: []const u8 = git_worktree_cwd orelse "";
    const sql = "UPDATE sessions SET git_worktree_cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, &.{ effective, id });

    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
            .git_worktree_cwd = s.git_worktree_cwd,
        }) catch {};
    }
}
```

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must show `test success` and the new test count (baseline + 2 from migration_git_worktree_test.zig).

---

## Chunk 2: `set_git_worktree` tool module

Create the tool's input struct, `AgentTool` definition, and `executeSetGitWorktreeToString` function in `src/modules/agent/tools/set_git_worktree.zig`. Mirror the structure of `add_skill.zig` exactly (per the project memory "Tool implementations are co-located with the tool registry" — the tool file is self-contained and registered by the tool_registry).

- [ ] **Step 2.1: Create `src/modules/agent/tools/set_git_worktree.zig`**

The file structure follows `add_skill.zig` line-for-line:

```zig
const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig"); // for get_global_skills_path_from_env reuse pattern, OR a new helper

/// Input structure for set_git_worktree tool
pub const SetGitWorktreeInput = struct {
    /// Absolute path to the worktree directory. The directory must NOT
    /// already exist (git worktree add will create it). The parent
    /// directory MUST exist. Examples:
    ///   "/home/me/projects/myapp/.worktrees/auth-fix"
    ///   "/tmp/experiments/rpc-rewrite"
    ///   "/Users/me/code/myapp.worktrees/fix-bug-123"
    /// Required unless `clear=true`. Must be absolute, ≤ 4096 chars,
    /// contain no `..` segments, no null bytes. The basename must
    /// match `[A-Za-z0-9._-]{1,100}` (so the auto-derived branch name
    /// `worktree/<basename>` is legal).
    path: []const u8 = "",
    /// Optional branch name override. Defaults to `worktree/<basename(path)>`.
    /// Rarely needed — the default is consistent and predictable.
    branch: []const u8 = "",
    /// When true, remove the existing worktree binding for this session
    /// AND delete the worktree directory. `path` is ignored when true.
    clear: bool = false,
    /// The session_id this worktree is bound to. The LLM does NOT
    /// supply this — the tool_registry execX wrapper injects
    /// `ctx.session_id` at call time.
    session_id: []const u8 = "",
};

/// Tool definition for set_git_worktree
pub const set_git_worktree_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_git_worktree",
        .description = "Create a git worktree at an absolute path you provide and bind it as the session's working directory. The worktree can be in any folder (e.g. '/home/me/project/.worktrees/auth-fix', '/tmp/experiments/x', or anywhere else). While bound, bash/read_file/write_file/text_replace/glob/search operate on the worktree instead of the session's original cwd. The branch defaults to 'worktree/<basename(path)>'. Call again with a different path to switch the binding to that worktree. Pass clear=true to remove the worktree directory and clear the binding.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the worktree directory. Must be absolute, contain no '..' segments, no null bytes, be ≤ 4096 chars, and the parent directory must already exist. The basename must match [A-Za-z0-9._-]{1,100} (so the auto-derived branch name is legal). Examples: '/home/me/proj/.worktrees/auth-fix', '/tmp/experiments/rpc-rewrite'.",
                },
                .{
                    .name = "branch",
                    .type = "string",
                    .description = "Optional branch name override. Defaults to 'worktree/<basename(path)>'. Rarely needed.",
                },
                .{
                    .name = "clear",
                    .type = "boolean",
                    .description = "If true, remove the worktree directory and clear the binding. 'path' is ignored when clear=true. Default: false.",
                },
            },
            .required = &.{},
        },
    },
};

/// Validate an absolute worktree path. Returns null on success, or an
/// error message on failure. Pure function — no IO. Also validates
/// the basename (which becomes the auto-derived branch name).
pub fn validatePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 4096) return "path exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return "path contains null byte";
    if (!std.fs.path.isAbsolute(path)) return "path must be absolute (start with /)";
    if (std.mem.indexOf(u8, path, "..") != null) return "path must not contain '..' segments";

    // Basename must be a legal branch name fragment.
    const basename = std.fs.path.basename(path);
    if (validateBasename(basename)) |err_msg| return err_msg;
    return null;
}

/// Validate a basename (used both by `validatePath` and as a stand-alone
/// check for the auto-derived branch name). Returns null on success.
pub fn validateBasename(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "basename cannot be empty";
    if (name.len > 100) return "basename exceeds 100 characters";
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return "basename contains invalid character (allowed: A-Za-z0-9._-)";
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return "basename cannot be '.' or '..'";
    }
    return null;
}

/// Pure helper: derive the default branch name from an absolute worktree
/// path. Returns `worktree/<basename>`. Caller frees the result.
pub fn deriveBranchFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const basename = std.fs.path.basename(path);
    return try std.fmt.allocPrint(allocator, "worktree/{s}", .{basename});
}

/// Run the actual `git worktree add` shell-out. Returns the worktree
/// path on success, or an error with the stderr message.
fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "add", "-b", branch, worktree_path,
        },
        .cwd = .{ .path = repo_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;
    // ... wait + check exit code
}

/// Read the session's current `git_worktree_cwd` from the DB.
/// Returns empty string when not set. Used by `clear` to know which
/// directory to remove.
fn readExistingWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    const sql = "SELECT COALESCE(git_worktree_cwd, '') FROM sessions WHERE id = ?";
    var q = try db.query(allocator, sql, &.{session_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Execute the set_git_worktree tool.
/// Mirrors add_skill.executeAddSkillToString — returns an XML string
/// inside the standardized <tool> envelope via the tool_registry's
/// wrapToolOutput wrapper (called by execSetGitWorktree).
/// Caller owns the returned memory and must free it with allocator.free().
pub fn executeSetGitWorktreeToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    input: SetGitWorktreeInput,
) ![]const u8 {
    if (session_id.len == 0) return xmlErrorEmpty(allocator, "session_id is required");

    // CLEAR PATH — remove the currently-bound worktree, if any.
    if (input.clear) {
        const existing = try readExistingWorktreeCwd(allocator, db, session_id);
        defer allocator.free(existing);
        if (existing.len > 0) {
            try runGitWorktreeRemove(allocator, io, existing);
        }
        return successClearToXml(allocator, session_id);
    }

    // SET PATH — validate the absolute path, check parent exists, create.
    if (input.path.len == 0) {
        return xmlError(allocator, session_id, "path is required (or pass clear=true)");
    }
    if (validatePath(input.path)) |err_msg| {
        return xmlError(allocator, session_id, err_msg);
    }
    // Parent directory must exist (git won't auto-create it).
    const parent_path = std.fs.path.dirname(input.path) orelse "/";
    std.Io.Dir.cwd().access(io, parent_path, .{}) catch {
        return xmlError(allocator, session_id, "parent directory does not exist");
    };
    const worktree_path = try allocator.dupe(u8, input.path);
    defer allocator.free(worktree_path);
    const branch = if (input.branch.len > 0) input.branch else blk: {
        const default = try deriveBranchFromPath(allocator, worktree_path);
        break :blk default;
    };
    defer if (input.branch.len == 0) allocator.free(branch);
    try runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch);
    return successSetToXml(allocator, session_id, worktree_path, branch);
}

// XML helpers: successSetToXml, successClearToXml, xmlError, xmlErrorEmpty
// — copy from add_skill.zig lines 192-248, adapted for <worktree> root tag
// (successSetToXml emits <path>, <branch>).
```

**Important Zig 0.16 details (from the project's stored memories):**
- `std.process.spawn(io, options)` — `io` is the FIRST arg (not the allocator). The plan's `runGitWorktreeAdd` shows the correct signature.
- `child.kill(io)` returns `void` in 0.16 and asserts `child.id == null` after — DO NOT call `child.wait(io)` after a successful `kill(io)`. Use a synthetic Term if you need the exit signal.
- Use `std.fs.path.basename(path)` to extract the worktree folder name (used in `deriveBranchFromPath` and the basename check in `validatePath`). Per the project's `zig-path-join-treats-suffix-as-component` memory, `std.fs.path.basename` is the right primitive for "last path component" (NOT `path.join` with a suffix).
- `std.fs.path.isAbsolute(path)` to validate that the LLM's `path` starts with `/`. Available in 0.16.
- `std.Io.Dir.cwd().access(io, path, .{})` for "does the parent directory exist?" checks (NOT `std.fs.accessAbsolute`, which is gone in 0.16).
- `std.fs.path.dirname(path)` to extract the parent for the existence check. Note: returns `null` when `path` is a bare filename (e.g. `/foo` → `"/"`, `foo` → `null`). The `orelse "/"` fallback in the plan handles the bare-filename case.

- [ ] **Step 2.2: Re-export from `src/modules/agent/tools/tools.zig`**

Add after line 32 (matching the `add_skill` lines 13 and 28):
```zig
pub const set_git_worktree = @import("set_git_worktree.zig");
// ...
pub const set_git_worktree_tool = set_git_worktree.set_git_worktree_tool;
```

- [ ] **Step 2.3: Re-export from `src/root.zig`**

Add after line 354 (the existing `add_skill` line):
```zig
pub const set_git_worktree = @import("modules/agent/tools/set_git_worktree.zig");
```

- [ ] **Step 2.4: Create `src/modules/agent/tools/set_git_worktree_test.zig`**

Static source-check tests + behavioral tests for the validation/derivation helpers. Pattern mirrors `add_skill_test.zig` and the migration tests:
- `set_git_worktree tool definition has correct name` — read the file as text, assert `set_git_worktree_tool` const exists and has `.function.name = "set_git_worktree"`.
- `set_git_worktree tool description mentions absolute path` — assert the description string includes "absolute path".
- `set_git_worktree input struct has path + clear + branch fields` — assert all 3 fields exist (the `path` field is the new absolute path, replacing the old `name`).
- `validatePath accepts valid absolute paths` — `"/home/me/proj/.worktrees/auth-fix"`, `"/tmp/experiments/rpc-rewrite"`, `"/a/b/c"`, `"/x"` all return null. (parent dir existence is a separate check at runtime.)
- `validatePath rejects empty path` — returns an error message.
- `validatePath rejects relative path` — `"foo/bar"` returns "must be absolute" error.
- `validatePath rejects path with ".."` — `"/home/me/../etc/passwd"` returns "no '..' segments" error.
- `validatePath rejects null byte` — `"/foo\x00bar"` returns null-byte error.
- `validatePath rejects too-long path` — `"/" + "a".repeat(5000)` returns length error.
- `validatePath rejects illegal basename` — `"/foo/hello world"`, `"/foo/bar/baz"`, `"/foo/."`, `"/foo/.."` all return basename error.
- `validateBasename accepts legal names` — `"auth-fix"`, `"v2"`, `"x"`, `"a".repeat(100)` all return null.
- `validateBasename rejects illegal names` — `"hello world"`, `"a/b"`, `"."`, `".."`, `"a".repeat(101)` all return errors.
- `deriveBranchFromPath returns "worktree/<basename>"` — behavioral, no IO. `deriveBranchFromPath(allocator, "/abs/.worktrees/auth-fix")` returns `"worktree/auth-fix"`. `deriveBranchFromPath(allocator, "/tmp/foo")` returns `"worktree/foo"`.

Register in `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("../modules/agent/tools/set_git_worktree_test.zig"); // adjust path if test_runner is in modules/
```

(Verify the correct import path — `add_skill_test.zig` lives in `src/modules/agent/tools/`, and the test runner is in `src/modules/test_runner.zig`. Check `src/modules/test_runner.zig` for the precedent.)

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must show the new test count (baseline + 4 from migration test + ~7 from set_git_worktree test).

---

## Chunk 3: Tool registry wiring + CWD override

Wire `set_git_worktree` into the unified tool registry, add the `execSetGitWorktree` wrapper, and apply the `git_worktree_cwd` override in the workflow's `ctx.cwd` resolution.

- [ ] **Step 3.1: Add `execSetGitWorktree` to `src/ai_workflow/tui/tool_registry.zig`**

Place it after `execAddSkill` (line 462). Pattern:

```zig
pub fn execSetGitWorktree(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_git_worktree_mod.SetGitWorktreeInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = set_git_worktree_mod.executeSetGitWorktreeToString(
        ctx.allocator,
        ctx.io,
        ctx.db,           // NEW: tool reads existing git_worktree_cwd on clear
        ctx.cwd,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_git_worktree failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the new git_worktree_cwd to the DB and refresh the
    // cached ctx.cwd so subsequent tool calls in this session see the
    // worktree. Both writes happen via llm_history — the tool_registry
    // does NOT own the DB schema for git_worktree_cwd (it just consumes
    // the helper from llm_history.zig).
    //
    // The new value is derived from the tool's output: the inner XML
    // contains <worktree_path>...</worktree_path> on success. We parse
    // it back out and call updateSessionGitWorktreeCwd.
    const path_start = (std.mem.indexOf(u8, inner, "<worktree_path>") orelse 0) + "<worktree_path>".len;
    const path_end = std.mem.indexOf(u8, inner[path_start..], "</worktree_path>") orelse inner.len;
    const worktree_path = inner[path_start .. path_start + path_end];
    const effective: ?[]const u8 = if (parsed.value.clear or worktree_path.len == 0) null else worktree_path;

    llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, effective) catch |err| {
        ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
    };

    const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

- [ ] **Step 3.2: Add the import to `src/ai_workflow/tui/tool_registry.zig` (line ~26, after `add_skill_mod`)**

```zig
const set_git_worktree_mod = nalar_mod.set_git_worktree;
```

- [ ] **Step 3.3: Register in `UNIFIED_TOOL_REGISTRY` (line ~1409) and `allAgentTools` (line ~1463)**

Add:
```zig
// In UNIFIED_TOOL_REGISTRY (the FILE OPERATIONS section is the natural neighbor):
.{ .name = "set_git_worktree", .exec = execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },

// In allAgentTools (the comptime tools_list):
set_git_worktree_mod.set_git_worktree_tool,
```

- [ ] **Step 3.4: Apply the CWD override in `src/ai_workflow/tui/workflow.zig`**

This is the trickiest part. The `ctx.cwd` is set ONCE at the start of the workflow run (in `RunParamsNew.cwd` → `tool_exec_context.cwd` in `handle_tool.zig`). For the override to take effect on the SECOND tool call in the same session (after `set_git_worktree` succeeds), the workflow must either:
- (a) re-read `sessions.git_worktree_cwd` on every tool dispatch, OR
- (b) mutate `ctx.cwd` in place when `set_git_worktree` succeeds.

The project memory `custom-http-server-per-request-arena` does not apply here (the workflow is a long-lived process, not a per-request arena), but the same "ownership" principle does: the `ctx` is owned by the workflow, and the `cwd` field is a `[]const u8` slice borrowed from the `RunParamsNew.cwd` allocator. Mutating it in place is the cleanest fix.

**Recommended approach (b):** In `execSetGitWorktree` (Step 3.1), after the DB write succeeds, ALSO mutate the `ctx.cwd` field to point at the new worktree path. The `ctx` is passed by pointer (`ToolExecContext` is a `const` in the signature today — change to mutable, OR add a separate "cwd override" field that subsequent calls read from).

The least invasive path: add a `cwd_override: ?[]const u8 = null` field to `ToolExecContext` (line 54). Every tool exec checks it FIRST; if non-null, use that as `cwd` for the rest of the call. Initialize from `ctx.db` + `ctx.session_id` on workflow startup:

```zig
// In handle_tool.zig's runAgenticMultiStepnew, AFTER tool_exec_context is built:
const session = llm_history.getSession(allocator, sqlite_db, session_id) catch null;
defer if (session) |s| s.deinit(allocator);
if (session) |s| {
    if (s.git_worktree_cwd.len > 0) {
        tool_exec_context.cwd_override = s.git_worktree_cwd;
    }
}
```

Then in `execSetGitWorktree`'s success path, do:
```zig
// (In addition to the DB write above)
if (parsed.value.clear) {
    ctx.cwd_override = null;
} else if (worktree_path.len > 0) {
    ctx.cwd_override = try ctx.allocator.dupe(u8, worktree_path);
    // freed on workflow exit by handle_tool.zig's existing cleanup
}
```

**This is the highest-risk change in the plan.** A less-risky alternative is to make the override optional: do it for v1, but flag in a follow-up plan that the next LLM turn after `set_git_worktree` succeeds may need its own `RunParamsNew` re-derivation. Test the override thoroughly with a behavioral test that calls `execBash` after `execSetGitWorktree` and asserts the bash `cwd` parameter resolved to the worktree.

- [ ] **Step 3.5: Add a behavioral test in `set_git_worktree_test.zig` (extend Chunk 2's file)**

Test: `execSetGitWorktree persists git_worktree_cwd to DB`. This needs the `nalarcore` singleton + a real (in-memory) DB. If the project has a precedent for this, follow it. Otherwise, write a static source check that asserts `execSetGitWorktree` calls `llm_history.updateSessionGitWorktreeCwd` and `db.exec` — both of which are checkable via `std.mem.indexOf` on the file source.

**Verification:** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — must show `test success` and the new test count (baseline + 4 from migration + ~8 from set_git_worktree = ~12 new tests).

---

## Chunk 4: Frontend types + sidebar badge

Extend the TypeScript types and add the 🌳 badge in `ChatsList.vue`.

- [ ] **Step 4.1: Extend `Session` interface in `src/apps/desktop/src/api/index.ts` (line 828)**

```ts
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedProfile?: string
  git_worktree_cwd?: string   // NEW: empty string when no worktree bound
}
```

- [ ] **Step 4.2: Extend `SessionEvent` interface (line 1152)**

```ts
export interface SessionEvent {
  action: 'created' | 'updated' | 'deleted'
  id: string
  name: string
  status: string
  cwd: string
  created_at: string
  updated_at: string
  selected_profile_model?: string
  git_worktree_cwd?: string   // NEW
}
```

- [ ] **Step 4.3: Extend `navItems` ref type in `ChatsList.vue` (line 34)**

```ts
const navItems = ref<{
  id: string
  name: string
  active?: boolean
  processing?: boolean
  relativeTime?: string
  selected_profile_model?: string
  git_worktree_cwd?: string   // NEW
}[]>([])
```

- [ ] **Step 4.4: Map `git_worktree_cwd` in `loadChats` (line 131) and the SSE `updated` handler (line 312)**

`loadChats` (line 131-138) — add the field to the mapped item:
```ts
navItems.value = sessions.map((session: any) => ({
  id: session.session_id,
  name: session.session_name || 'New Chat',
  active: savedSessionId === session.session_id,
  processing: !!processingState.value[session.session_id],
  relativeTime: formatRelativeTime(session.updated_at),
  selected_profile_model: session.selected_profile_model || '',
  git_worktree_cwd: session.git_worktree_cwd || '',  // NEW
}))
```

SSE `updated` handler (line 318-322) — add the field:
```ts
navItems.value[existingIndex] = {
  ...existing,
  name: event.name || existing.name,
  selected_profile_model: event.selected_profile_model ?? existing.selected_profile_model,
  git_worktree_cwd: event.git_worktree_cwd ?? existing.git_worktree_cwd,  // NEW
}
```

- [ ] **Step 4.5: Render the 🌳 badge in the chat list item (next to the existing 🤖 `selected_profile_model` badge at line 501)**

```vue
<span
  v-if="item.git_worktree_cwd"
  class="text-xs text-emerald-600 dark:text-emerald-400 font-mono"
  :title="item.git_worktree_cwd"
>🌳 worktree</span>
```

(Matches the project's `frontend-jsdom-hex-color-to-rgb` memory: the green-500 `rgb(34, 197, 94)` is correct via `text-emerald-600` — but `text-emerald-600` is a Tailwind utility, NOT an inline style, so jsdom won't normalize it. The badge is safe.)

- [ ] **Step 4.6: Add a test for the badge**

Create `src/apps/desktop/src/__tests__/chatsListGitWorktree.spec.ts` (or extend an existing ChatsList spec). Mock `api.getChats` to return a session with `git_worktree_cwd: '/abs/.worktrees/worktree/session_abc'`, mount the component, assert the 🌳 badge appears. The test must run via `bunx vitest run` AND `bun run build` per the project memory.

**Verification:**
- `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` — must show a clean vue-tsc pass.
- `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` — must show all tests green.

---

## Chunk 5: Manual end-to-end smoke test

The plan's confidence is gated on the manual smoke test working. **Do not mark the plan "done" until this passes.**

- [ ] **Step 5.1: Start nalar on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build install:linux:system 2>&1 | tail -n 5
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-smoke.log 2>&1 &
echo "PID: $!"
```

(Per the project MANDATORY rule: NEVER kill the `nalar` on port 8081. Use 8080 for smoke tests. The `install:linux:system` step writes to `/usr/local/bin/nalar` (will fail on permission) but the binary lands at `zig-out/bin/nalar` first.)

- [ ] **Step 5.2: Create a session and capture its id**

```bash
curl -sS -X POST http://127.0.0.1:8080/api/session \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"smoke_test_001","session_name":"worktree smoke test"}'
```

- [ ] **Step 5.3: Set a worktree at an absolute path under `.worktrees/`**

In the desktop app, open the new chat and ask:
> "Set up a worktree at `/home/<you>/.../ginwaaitoolbox/.worktrees/auth-refactor` and tell me the branch."

Verify:
1. The LLM calls the tool with `{"path": "/home/<you>/.../ginwaaitoolbox/.worktrees/auth-refactor"}` (visible in the tool call UI).
2. The tool returns `<success>true</success><path>/abs/path/.worktrees/auth-refactor</path><branch>worktree/auth-refactor</branch>`.
3. `.worktrees/auth-refactor/` exists in the project.
4. `git worktree list` shows a new entry with branch `worktree/auth-refactor`.
5. The ChatsList sidebar shows the 🌳 badge (the `git_worktree_cwd` is now populated).

- [ ] **Step 5.4: Verify the CWD override**

Ask:
> "Run `pwd` in the chat — what directory does it report?"

Verify the bash `cwd` is the worktree path (`/abs/path/.worktrees/auth-refactor`), NOT the original `cwd` of the chat. This is the CWD override test from Chunk 3, Step 3.4.

- [ ] **Step 5.5: Switch to a worktree in a DIFFERENT folder (e.g. `/tmp`)**

Ask:
> "Now switch to a worktree at `/tmp/experiments/fix-bug-123` (create `/tmp/experiments` first if it doesn't exist)."

Verify:
1. The LLM first runs `mkdir -p /tmp/experiments` (or similar) to ensure the parent exists.
2. Then calls `set_git_worktree` with `{"path": "/tmp/experiments/fix-bug-123"}`.
3. `/tmp/experiments/fix-bug-123/` is created.
4. `git worktree list` shows BOTH `.worktrees/auth-refactor` and `/tmp/experiments/fix-bug-123` (the old one is NOT removed — the LLM chose to switch, not clear).
5. The session's `git_worktree_cwd` is now `/tmp/experiments/fix-bug-123` (verify via `curl /api/sessions` or the ChatsList badge tooltip).
6. A `pwd` reports `/tmp/experiments/fix-bug-123`.

- [ ] **Step 5.6: Clear the worktree**

Ask:
> "Clear the worktree binding for this session."

Verify:
1. The tool call includes `{"clear": true}`.
2. The tool returns `<success>true</success><cleared>true</cleared>`.
3. `/tmp/experiments/fix-bug-123/` is GONE (but `.worktrees/auth-refactor/` still exists — the LLM only cleared the active one).
4. `git worktree list` no longer shows `/tmp/experiments/fix-bug-123` (but still shows `.worktrees/auth-refactor`).
5. The ChatsList sidebar 🌳 badge disappears.
6. A subsequent `pwd` reports the original session cwd.

- [ ] **Step 5.7: Stop nalar**

```bash
kill <PID from step 5.1>
```

**Verification:** All 6 steps must pass. If any step fails, the chunk(s) that touched that surface need a fix-and-retest cycle.

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| The CWD override in Chunk 3.4 mutates `ctx.cwd` in a way that breaks the `tool_exec_context` lifetime | High | The override is a NEW optional field `cwd_override: ?[]const u8`. Existing `ctx.cwd` stays untouched. All exec functions opt in by reading `cwd_override ?? ctx.cwd` in the wrapper. |
| The `git worktree add` shell-out hangs in a way the tool_registry doesn't recover from | Low | Use `std.process.spawn` with `stdout = .pipe, stderr = .pipe`, read both with a 30s timeout (the same pattern bash.zig uses for `timeout`). If the timeout fires, return `<error>git worktree add timed out</error>`. |
| Two concurrent sessions race to create the same `<path>` worktree | Low | The first `git worktree add` succeeds and creates the directory; the second fails with `fatal: '<branch>' is already checked out at '<path>'` (when the branch is the same) or `fatal: destination path '<path>' already exists` (when only the path is the same but a different branch was used). Return that stderr as `<error>` so the LLM sees the collision and picks a different path. |
| LLM passes a `path` whose parent directory doesn't exist | Medium | The `executeSetGitWorktreeToString` checks `std.Io.Dir.cwd().access(io, parent_path, .{})` BEFORE calling `git worktree add`, and returns `<error>parent directory does not exist</error>` if the access fails. The LLM is expected to `mkdir -p` the parent first (mirrors the manual smoke test Step 5.5). |
| Frontend `bun run build` fails on the new `git_worktree_cwd?` field in `Session` and `SessionEvent` | Medium | Make the field **optional** with `?` suffix, matching the project's `nalar-frontend-task-literal-typing-rule` memory. 8+ existing test files construct session literals without this field, so making it required would break the build. |
| The `onEventSendSessions` migration in Chunk 1 leaves a call site I missed | Low | The `zig build` compile is the canonical check — every callsite that fails to pass the new field will be a compile error. No runtime-only fallout possible. |
| Migration 046 fails on a real (non-`:memory:`) DB because the column already exists from a manual `ALTER TABLE` | Low | The `schema_migrations` table tracks which migrations have run, so re-running Migration 046 on a DB that already has the column is gated on the version. If the column is somehow present without the schema_migrations row, the `ADD COLUMN` will fail with `duplicate column` — but that scenario only happens if a user manually altered the schema. Document in the migration's doc comment. |

---

## Files modified summary

| File | Change | LoC estimate |
|---|---|---|
| `src/ai_workflow/tui/migration.zig` | +1 migration struct + 1 line in `allMigrations` | +15 |
| `src/ai_workflow/tui/llm_history.zig` | +1 field on `SessionTableInfo` + 1 field on `SessionBroadcastInfo` + 2 SELECT changes + 1 new function `updateSessionGitWorktreeCwd` + 5 `onEventSendSessions` call site updates | +60 |
| `src/ai_workflow/tui/on_event_sent.zig` | +1 field on `OnEventInputSessions` | +1 |
| `src/ai_workflow/tui/tool_registry.zig` | +1 import + 1 `execX` function + 2 lines in registry tables | +60 |
| `src/ai_workflow/tui/handle_tool.zig` | +1 line in runAgenticMultiStepnew to read `git_worktree_cwd` on startup | +5 |
| `src/ai_workflow/tui/workflow.zig` | +1 line in `ctx` init to wire `cwd_override` (via handle_tool — workflow.zig unchanged) | 0 |
| `src/ai_workflow/tui/test_runner.zig` | +2 lines for new test files | +2 |
| `src/modules/agent/tools/set_git_worktree.zig` | NEW file (with `validatePath` + `validateBasename` + `deriveBranchFromPath` helpers + DB-backed `readExistingWorktreeCwd`) | +240 |
| `src/modules/agent/tools/set_git_worktree_test.zig` | NEW file (more validation cases for `validatePath` + `validateBasename` + `deriveBranchFromPath`) | +170 |
| `src/modules/agent/tools/tools.zig` | +2 lines for re-export | +2 |
| `src/root.zig` | +1 line for re-export | +1 |
| `src/ai_workflow/tui/migration_git_worktree_test.zig` | NEW file | +60 |
| `src/apps/desktop/src/api/index.ts` | +2 lines for the new optional field on `Session` + `SessionEvent` | +2 |
| `src/apps/desktop/src/components/ChatsList.vue` | +1 type field + 2 mappings + 1 badge template line + 1 test | +10 |
| `src/apps/desktop/src/__tests__/chatsListGitWorktree.spec.ts` | NEW file | +60 |

**Total estimate:** ~600 LoC, ~17 new test cases, 1 new agent tool, 1 new DB column.

---

## Definition of done

- [ ] All chunks 1-5 are complete.
- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` shows `test success` and the test count increased by ~17.
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` is clean.
- [ ] `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` is clean.
- [ ] The manual smoke test (Chunk 5) passes for both the set and clear paths.
- [ ] The plan file is moved from "active" to "done" in `.nalar/tasks.md` with the timestamp.
- [ ] A PR is opened (per the `finishing-a-development-branch` skill).
