# `spawn_sub_agent` — `inherited_context` Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional `inherited_context` mode-string parameter to `spawn_sub_agent` that injects the parent's recent user/assistant conversation history into the sub-agent's system prompt as a labelled read-only block.

**Architecture:** A new helper module `src/ai_workflow/tui/inherited_context.zig` owns the parse + format logic. The tool schema adds the field, the existing call chain (`SubAgentThreadArgs` → `RunParamsNew` → `buildMessages`) threads it through, and `buildMessages` appends the rendered block to `systemContent` only when the formatted output is non-empty. Mode-string parsing is validated at the tool layer so the LLM sees a clear error on bad input.

**Tech Stack:** Zig 0.16.0, std.Io.Threaded for sqlite tests, existing `SqliteBackend` (`src/modules/databases/sqlite/Sqlite.zig`), existing `llm_history` table schema (`src/ai_workflow/tui/migration.zig:18`).

**Reference design:** `docs/plans/2026-06-09-spawn-sub-agent-inherited-context-design.md`

**Reference skills:**
- `zig-0.16-inmemory-sqlite-test-setup` — required for the formatter test (uses `std.Io.Threaded.init` + `.io()`, NOT the broken `std.Io.init()` pattern)
- `zig-slice-headers-across-defer-lifetimes` — the formatter must not copy slice headers across defer-managed lifetimes; build the output directly while the source slices are alive

---

## File Structure

| File | Responsibility | Action |
|------|----------------|--------|
| `src/ai_workflow/tui/inherited_context.zig` | Mode parser + DB-driven history formatter (single source of truth for the feature's logic) | CREATE |
| `src/ai_workflow/tui/inherited_context_test.zig` | Unit tests for parser + formatter (in-memory sqlite for the formatter) | CREATE |
| `src/ai_workflow/tui/test_runner.zig` | Register the new test file | MODIFY |
| `src/modules/agent/tools/spawn_sub_agent.zig` | Add field to `SubAgentInput`, parse the new key, free it in `deinit`, document the parameter in the tool description | MODIFY |
| `src/modules/agent/tools/spawn_sub_agent_test.zig` | Parser tests for the new field (no DB) | CREATE |
| `src/modules/agent/test_runner.zig` | Register the new test file | MODIFY |
| `src/ai_workflow/tui/tool_registry.zig` | Add `inherited_context` to `SubAgentThreadArgs`; pass it into `runAgenticMultiStepnew` | MODIFY |
| `src/ai_workflow/tui/workflow.zig` | Add `inherited_context` to `RunParamsNew`; dupe it; pass to `buildMessages` | MODIFY |
| `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` | Accept `inherited_context_mode`, call the formatter, append to `systemContent` | MODIFY |

---

## Chunk 1: Helper module — parser

### Task 1.1: Create `inherited_context.zig` with `parseMode`

**Files:**
- Create: `src/ai_workflow/tui/inherited_context.zig`
- Create: `src/ai_workflow/tui/inherited_context_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (add import)

- [ ] **Step 1: Write the failing parser tests**

Create `src/ai_workflow/tui/inherited_context_test.zig`:

```zig
const std = @import("std");
const ic = @import("inherited_context.zig");

test "parseMode - null/empty string returns Mode.none" {
    const m = try ic.parseMode("");
    try std.testing.expect(m == .none);
}

test "parseMode - 'none' returns Mode.none" {
    const m = try ic.parseMode("none");
    try std.testing.expect(m == .none);
}

test "parseMode - 'last:5' returns Mode.last{5}" {
    const m = try ic.parseMode("last:5");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 5);
}

test "parseMode - 'last:' (no number) defaults to 10" {
    const m = try ic.parseMode("last:");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 10);
}

test "parseMode - 'last:0' clamps to 1" {
    const m = try ic.parseMode("last:0");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 1);
}

test "parseMode - 'last:999' clamps to 50" {
    const m = try ic.parseMode("last:999");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'last:50' stays 50" {
    const m = try ic.parseMode("last:50");
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'all' returns Mode.all" {
    const m = try ic.parseMode("all");
    try std.testing.expect(m == .all);
}

test "parseMode - 'since_last_user' returns Mode.since_last_user" {
    const m = try ic.parseMode("since_last_user");
    try std.testing.expect(m == .since_last_user);
}

test "parseMode - 'garbage' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("garbage"));
}

test "parseMode - 'last:abc' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:abc"));
}

test "parseMode - 'last:-3' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:-3"));
}
```

Register in `src/ai_workflow/tui/test_runner.zig` by adding `_ = @import("inherited_context_test.zig");` (alphabetical position is fine; do not put it inside a `// DISABLED` comment).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `timeout 120 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 30`
Expected: COMPILE ERROR — `inherited_context.zig` doesn't exist yet. If the test runner is silently dropping the import (it has done this for `update_activity_test.zig` before — see `zig-0.16-inmemory-sqlite-test-setup` skill), also run `rm -rf .zig-cache` first.

- [ ] **Step 3: Write the minimal `parseMode` implementation**

Create `src/ai_workflow/tui/inherited_context.zig`:

```zig
const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

pub const Mode = union(enum) {
    none,
    last: u8, // 1..=50, clamped
    all,
    since_last_user,
};

/// Cap for the `last:N` selector and for the 50-message ceiling used by `all`
/// and `since_last_user`. Lifting to a constant so tests and formatter agree.
pub const MAX_MESSAGES: u8 = 50;
pub const DEFAULT_LAST: u8 = 10;
pub const MAX_SECTION_BYTES: usize = 20 * 1024; // 20 KB

pub const ParseError = error{InvalidInheritedContextMode};

pub fn parseMode(raw: []const u8) ParseError!Mode {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "since_last_user")) return .since_last_user;

    if (std.ascii.startsWithIgnoreCase(trimmed, "last:")) {
        const n_str = trimmed["last:".len..];
        if (n_str.len == 0) return Mode{ .last = DEFAULT_LAST };
        const n = std.fmt.parseInt(u8, n_str, 10) catch return error.InvalidInheritedContextMode;
        if (n == 0) return Mode{ .last = 1 };
        if (n > MAX_MESSAGES) return Mode{ .last = MAX_MESSAGES };
        return Mode{ .last = n };
    }

    return error.InvalidInheritedContextMode;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `timeout 120 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 30`
Expected: 12 new tests pass; build summary `12/12 passed` for this file. The wider build summary should now report 12 more passing tests than before (or 12 fewer failures, depending on starting state).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/inherited_context.zig \
        src/ai_workflow/tui/inherited_context_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(spawn_sub_agent): add inherited_context mode parser"
```

---

## Chunk 2: Helper module — formatter

### Task 2.1: Add `formatHistory` to `inherited_context.zig`

**Files:**
- Modify: `src/ai_workflow/tui/inherited_context.zig` (add `formatHistory` + private helpers)
- Modify: `src/ai_workflow/tui/inherited_context_test.zig` (add formatter tests with in-memory sqlite)

- [ ] **Step 1: Write the failing formatter tests**

Append to `src/ai_workflow/tui/inherited_context_test.zig`. Use the in-memory sqlite pattern from the `zig-0.16-inmemory-sqlite-test-setup` skill (do NOT copy the broken `update_activity_test.zig` pattern):

```zig
// --- Formatter tests (need DB) --------------------------------------------

const nalarcore = @import("nalarcore");

fn setupDb() !struct {
    db: nalarcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: nalarcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal llm_history schema — only the columns the formatter reads.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    created_at TEXT,
        \\    response_content TEXT,
        \\    role TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedMessage(
    alloc: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    created_at: []const u8,
    role: []const u8,
    content: []const u8,
) !void {
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, created_at, response_content, role)
        \\VALUES (?, ?, ?, ?, ?)
    , &.{ id, session_id, created_at, content, role });
}

test "formatHistory - parent with no history returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "parent_sess", .none);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - last:5 filters out tool messages" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "Hello");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "Hi there");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "Please do X");
    try seedMessage(alloc, &ctx.db, "m4", "p", "2024-01-01 00:00:04", "assistant", "On it");
    try seedMessage(alloc, &ctx.db, "m5", "p", "2024-01-01 00:00:05", "tool", "{\"result\":\"ok\"}");
    try seedMessage(alloc, &ctx.db, "m6", "p", "2024-01-01 00:00:06", "user", "Thanks");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .{ .last = 5 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "## Conversation History From Parent Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: Hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Please do X") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: On it") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: Thanks") != null);
    // Tool message must be filtered out
    try std.testing.expect(std.mem.indexOf(u8, out, "**[tool]**") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "result") == null);
    // Order check: "Hello" must appear before "Please do X"
    const a = std.mem.indexOf(u8, out, "Hello").?;
    const b = std.mem.indexOf(u8, out, "Please do X").?;
    try std.testing.expect(a < b);
}

test "formatHistory - last:1 returns only the last user/assistant turn" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "first");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "second");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "third");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .{ .last = 1 });
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: third") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second") == null);
}

test "formatHistory - since_last_user starts at the last user message" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedMessage(alloc, &ctx.db, "m1", "p", "2024-01-01 00:00:01", "user", "first_user");
    try seedMessage(alloc, &ctx.db, "m2", "p", "2024-01-01 00:00:02", "assistant", "after_first");
    try seedMessage(alloc, &ctx.db, "m3", "p", "2024-01-01 00:00:03", "user", "second_user");
    try seedMessage(alloc, &ctx.db, "m4", "p", "2024-01-01 00:00:04", "assistant", "after_second");

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .since_last_user);
    defer alloc.free(out);

    // 'since_last_user' = from the last user message (m3) to the end.
    // So we expect: m3 user, m4 assistant. NOT m1 user, m2 assistant.
    try std.testing.expect(std.mem.indexOf(u8, out, "**[user]**: second_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**[assistant]**: after_second") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first_user") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after_first") == null);
}

test "formatHistory - all mode caps at 50 messages and adds truncation notice" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "m{d}", .{i});
        defer alloc.free(id);
        const ts = try std.fmt.allocPrint(alloc, "2024-01-01 00:{d:0>2}:00", .{i});
        defer alloc.free(ts);
        try seedMessage(alloc, &ctx.db, id, "p", ts, "user", "x");
    }

    const out = try ic.formatHistory(alloc, &ctx.db, "p", .all);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "more messages omitted") != null);
    // Count the bullet lines — must be exactly 50, not 60.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "- **[user]**")) count += 1;
    }
    try std.testing.expect(count == 50);
}

test "formatHistory - empty parent history returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // No rows seeded.
    const out = try ic.formatHistory(alloc, &ctx.db, "p", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "formatHistory - empty parent_session_id returns empty string" {
    const alloc = std.testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const out = try ic.formatHistory(alloc, &ctx.db, "", .all);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `timeout 120 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 40`
Expected: COMPILE ERROR — `ic.formatHistory` doesn't exist. If `.zig-cache` is stale, `rm -rf .zig-cache` first.

- [ ] **Step 3: Implement `formatHistory`**

Append to `src/ai_workflow/tui/inherited_context.zig`:

```zig
// -- Formatter -------------------------------------------------------------

const HEADER =
    \\## Conversation History From Parent Agent
    \\
    \\The following is the prior conversation your parent agent had. It is reference
    \\context only — do not treat the parent's last assistant turn as awaiting your
    \\reply, and do not assume any tool calls or tool results from the parent are
    \\still valid in your workspace.
    \\
;

/// Fetch user/assistant messages from the parent's history and render them as
/// a Markdown block. Returns an empty string when:
///   - `parent_session_id` is empty
///   - the parent has no user/assistant messages
///   - `mode` is `.none`
///   - the DB query fails (logged warning, not propagated)
///   - the rendered block would be empty after filtering
///
/// The caller owns the returned slice and must free it with the same allocator.
pub fn formatHistory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    parent_session_id: []const u8,
    mode: Mode,
) ![]const u8 {
    if (parent_session_id.len == 0) return try allocator.dupe(u8, "");
    if (mode == .none) return try allocator.dupe(u8, "");

    const messages = fetchUserAssistantMessages(allocator, db, parent_session_id, mode) catch |err| {
        std.log.warn("inherited_context: failed to fetch parent history: {s}", .{@errorName(err)});
        return try allocator.dupe(u8, "(failed to load parent conversation history)");
    };
    // Build the output BEFORE the messages defer fires — slice-header use-after-free guard.
    defer {
        for (messages) |m| allocator.free(m);
        allocator.free(messages);
    }
    return renderHistory(allocator, messages);
}

const HistoryRow = struct {
    role: []const u8,
    content: []const u8,
};

fn fetchUserAssistantMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    parent_session_id: []const u8,
    mode: Mode,
) ![]HistoryRow {
    // Build the SQL based on the mode. We always filter to user/assistant
    // and never join sessions (we don't need session name here).
    var sql: []const u8 = undefined;
    var args: []const []const u8 = undefined;
    var limit_buf: [16]u8 = undefined;
    var since_id_buf: [32]u8 = undefined;
    var rows_out: std.ArrayList(HistoryRow) = .empty;
    errdefer {
        for (rows_out.items) |r| {
            allocator.free(r.role);
            allocator.free(r.content);
        }
        rows_out.deinit(allocator);
    }

    switch (mode) {
        .none => return try rows_out.toOwnedSlice(allocator),
        .last => |n| {
            // LIMIT n
            const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{n});
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant')
                \\ORDER BY created_at DESC, id DESC
                \\LIMIT ?
            ;
            args = &.{ parent_session_id, limit_str };
        },
        .all => {
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant')
                \\ORDER BY created_at ASC
            ;
            args = &.{parent_session_id};
        },
        .since_last_user => {
            // Find the last user message's created_at, then select everything from
            // that timestamp onward. Subquery is portable SQLite.
            sql =
                \\SELECT role, response_content FROM llm_history
                \\WHERE session_id = ? AND role IN ('user', 'assistant')
                \\AND created_at >= (
                \\    SELECT created_at FROM llm_history
                \\    WHERE session_id = ? AND role = 'user'
                \\    ORDER BY created_at DESC, id DESC LIMIT 1
                \\)
                \\ORDER BY created_at ASC
            ;
            args = &.{ parent_session_id, parent_session_id };
            // silence the "since_id_buf unused" warning
            _ = since_id_buf;
        },
    }

    var q = try db.query(allocator, sql, args);
    defer q.deinit();

    while (try q.next()) |row| {
        const role = try allocator.dupe(u8, row.values[0]);
        const content = try allocator.dupe(u8, row.values[1]);
        try rows_out.append(allocator, .{ .role = role, .content = content });
        row.deinit(allocator);
    }

    var raw = try rows_out.toOwnedSlice(allocator);

    // For `last:N` we ordered DESC to apply LIMIT; reverse to ASC for display.
    if (mode == .last) std.mem.reverse(HistoryRow, raw);

    // Apply the hard cap (50 messages) uniformly.
    if (raw.len > MAX_MESSAGES) {
        for (raw[MAX_MESSAGES..]) |r| {
            allocator.free(r.role);
            allocator.free(r.content);
        }
        const trimmed = try allocator.realloc(raw, MAX_MESSAGES);
        raw = trimmed;
    }

    return raw;
}

fn renderHistory(allocator: std.mem.Allocator, messages: []HistoryRow) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Empty input → empty output (caller decides whether to render header).
    if (messages.len == 0) return try allocator.dupe(u8, "");

    try out.appendSlice(allocator, HEADER);

    var total: usize = HEADER.len;
    var rendered: usize = 0;
    for (messages) |m| {
        const line = try std.fmt.allocPrint(allocator, "- **[{s}]**: {s}\n", .{ m.role, m.content });
        defer allocator.free(line);

        // If adding this line would push us over the cap, stop and emit a
        // truncation notice (counting omitted messages).
        if (total + line.len > MAX_SECTION_BYTES and rendered > 0) {
            const omitted = messages.len - rendered;
            const notice = try std.fmt.allocPrint(allocator, "... ({d} more messages omitted)\n", .{omitted});
            try out.appendSlice(allocator, notice);
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, line);
        total += line.len;
        rendered += 1;
    }

    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `timeout 120 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 50`
Expected: 7 new formatter tests pass alongside the 12 parser tests. Total now 19 new tests in this file. Build summary clean.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/inherited_context.zig \
        src/ai_workflow/tui/inherited_context_test.zig
git commit -m "feat(spawn_sub_agent): add inherited_context history formatter"
```

---

## Chunk 3: Tool schema (data model + parser + description + parser tests)

### Task 3.1: Add `inherited_context` to `SubAgentInput` and parse it

**Files:**
- Modify: `src/modules/agent/tools/spawn_sub_agent.zig` (struct, deinit, parser, description)
- Create: `src/modules/agent/tools/spawn_sub_agent_test.zig` (parser tests)
- Modify: `src/modules/agent/test_runner.zig` (register the test file)

- [ ] **Step 1: Write the failing parser tests**

Create `src/modules/agent/tools/spawn_sub_agent_test.zig`:

```zig
const std = @import("std");
const spawn = @import("spawn_sub_agent.zig");

test "parse_sub_agents - inherited_context 'last:3' is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x","inherited_context":"last:3"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expect(parsed.sub_agents[0].inherited_context != null);
    try std.testing.expectEqualStrings("last:3", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - omitted inherited_context is null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].inherited_context == null);
}

test "parse_sub_agents - inherited_context 'none' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"none"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("none", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context 'all' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"all"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("all", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"last:5"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator will assert.
    // No explicit expect — if it leaks, testing.allocator fails the test on deinit.
}
```

Register in `src/modules/agent/test_runner.zig` by adding `_ = @import("tools/spawn_sub_agent_test.zig");` to the "Tool tests" group (alphabetical: between `remove_skill_test.zig` and `view_skill_test.zig`).

- [ ] **Step 2: Run the tests to verify they fail (compile error — field doesn't exist)**

Run: `timeout 120 zig build test:agent --summary all 2>&1 | tail -n 30`
Expected: COMPILE ERROR — `inherited_context` field doesn't exist on `SubAgentInput`. If `.zig-cache` is stale, `rm -rf .zig-cache` first.

- [ ] **Step 3: Add the field to `SubAgentInput` and parse it**

In `src/modules/agent/tools/spawn_sub_agent.zig`, make three edits:

**Edit 1** — add field to struct (line 8-13 area):
```zig
pub const SubAgentInput = struct {
    name: []const u8,
    instruction: []const u8,
    tools: ?[]const []const u8 = null,
    timeout_seconds: ?u32 = null,
    inherited_context: ?[]const u8 = null, // NEW
};
```

**Edit 2** — free it in `deinit` (line 18-31 area). Add one line inside the `for (self.sub_agents) |sa|` body, after the `timeout_seconds` comment:
```zig
            // Note: timeout_seconds doesn't need freeing (it's an optional primitive)
            if (sa.inherited_context) |ctx| allocator.free(ctx);
```

**Edit 3** — parse it in `parseSubAgentsFromValue` (after the timeout_seconds block, around line 213-220):
```zig
        // Parse optional "inherited_context" field
        var inherited_context: ?[]const u8 = null;
        if (agent_obj.get("inherited_context")) |ctx_val| {
            if (ctx_val == .string) {
                inherited_context = try allocator.dupe(u8, ctx_val.string);
            }
        }

        try sub_agents_list.append(allocator, .{
            .name = name,
            .instruction = instruction,
            .tools = tools,
            .timeout_seconds = timeout_seconds,
            .inherited_context = inherited_context,
        });
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `timeout 120 zig build test:agent --summary all 2>&1 | tail -n 30`
Expected: 5 new tests pass. No regressions in the other ~250+ tests in this target.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/spawn_sub_agent.zig \
        src/modules/agent/tools/spawn_sub_agent_test.zig \
        src/modules/agent/test_runner.zig
git commit -m "feat(spawn_sub_agent): parse inherited_context mode string"
```

### Task 3.2: Document the new parameter in the tool description

**Files:**
- Modify: `src/modules/agent/tools/spawn_sub_agent.zig` (tool description block)

- [ ] **Step 1: Update the tool description**

In `src/modules/agent/tools/spawn_sub_agent.zig`, in the `description` field of `spawn_sub_agent_tool` (currently ends with the `EXAMPLE USE CASES:` block around line 61-64), add a new section between `TIMEOUT OPTION:` and `EXAMPLE USE CASES:`. Match the formatting style of the existing sections (each line is `\\text`):

```
        \\INHERITED CONTEXT:
        \\- Each sub-agent can have an optional "inherited_context" mode string
        \\  that controls whether the parent's recent conversation history is
        \\  injected into the sub-agent's system prompt as a labelled read-only
        \\  block ("## Conversation History From Parent Agent").
        \\- Valid values:
        \\    - "none"        — no inheritance (default when omitted)
        \\    - "last:N"      — last N user/assistant turns from the parent (N: 1-50, default 10)
        \\    - "all"         — all user/assistant turns (capped at 50)
        \\    - "since_last_user" — from the parent's last user message onwards
        \\- Only user and assistant text turns are inherited. Tool calls and
        \\  tool results from the parent are NOT included — the sub-agent has
        \\  its own tool set and shouldn't assume the parent's tool state.
        \\
```

- [ ] **Step 2: Verify the build**

Run: `timeout 60 zig build 2>&1 | tail -n 20`
Expected: clean build. (The schema description is a const string used by the LLM; not exercised at runtime by existing tests.)

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/spawn_sub_agent.zig
git commit -m "docs(spawn_sub_agent): document inherited_context mode in tool description"
```

---

## Chunk 4: Thread the field through the call chain

### Task 4.1: Add `inherited_context` to `SubAgentThreadArgs` and pass it through

**Files:**
- Modify: `src/ai_workflow/tui/tool_registry.zig` (struct field, populate it, pass to `runAgenticMultiStepnew`)

- [ ] **Step 1: Locate and read the relevant lines**

Open `src/ai_workflow/tui/tool_registry.zig`. The struct `SubAgentThreadArgs` is around line 570-583. The population in `execSpawnSubAgent` is around line 645-662. The call to `runAgenticMultiStepnew` is around line 748-768.

- [ ] **Step 2: Add the field to `SubAgentThreadArgs`**

After the `instruction: []const u8` field, add:
```zig
    inherited_context: []const u8 = "", // empty = no inheritance
```

- [ ] **Step 3: Populate the field in `execSpawnSubAgent`**

In the `args.* = .{ ... }` block (line ~645), add:
```zig
            .inherited_context = sub_agent.inherited_context orelse "",
```

- [ ] **Step 4: Pass it to `runAgenticMultiStepnew`**

In the `runAgenticMultiStepnew(di, .{ ... })` call (line ~748), add `.inherited_context = args_ptr.inherited_context,` to the struct literal. Order alphabetically or group with the other new fields.

- [ ] **Step 5: Verify the build**

Run: `timeout 120 zig build 2>&1 | tail -n 20`
Expected: clean build, zero warnings about unused field on `SubAgentThreadArgs`.

### Task 4.2: Add `inherited_context` to `RunParamsNew` and `runAgenticMultiStepnew`

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig` (struct field, dupe, pass to `buildMessages`)

- [ ] **Step 1: Add the field to `RunParamsNew`**

After the `image_urls: []const u8 = "",` line (line ~1023), add:
```zig
    inherited_context: []const u8 = "", // NEW: mode string for parent history inheritance
```

- [ ] **Step 2: Dupe it inside `runAgenticMultiStepnew`**

After the `const copy_image_urls = try parent_allocator.dupe(u8, params.image_urls);` line (line ~176), add:
```zig
    const copy_inherited_context = try parent_allocator.dupe(u8, params.inherited_context);
```

- [ ] **Step 3: Pass it to `buildMessages`**

In the `buildMessages(allocator, io, db, copy_cwd, copy_session_id, db_messages, merged_tools)` call (line ~389), add `copy_inherited_context` as the last argument. The function signature is updated in Chunk 5 — for now the build will fail. That's expected.

- [ ] **Step 4: Don't commit yet — wait for Chunk 5 to land before the build passes**

Stash the changes mentally and move to Chunk 5. (The implementation order is: parser → formatter → tool schema → call chain → `buildMessages`. The `buildMessages` signature change is the keystone that makes the whole thing compile.)

### Task 4.3: Pass it through to `buildMessages` signature

**Files:**
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (function signature + thread the value)

- [ ] **Step 1: Read the function signature**

Open `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`. The signature is on line 22-30. The call site is `buildMessages(allocator, io, db, cwd, session_id, historyMessages, tools)` in `workflow.zig:389`.

- [ ] **Step 2: Add the new parameter**

Add to the end of the `buildMessages` parameter list:
```zig
    inherited_context_mode: []const u8 = "",
```

- [ ] **Step 3: Run the build to confirm Chunks 3-4 + this change compile cleanly**

Run: `timeout 120 zig build 2>&1 | tail -n 20`
Expected: clean build. (We added the param with a default value, so existing call sites compile, and the new field threads through.)

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/tool_registry.zig \
        src/ai_workflow/tui/workflow.zig \
        src/ai_workflow/tui/build_messages_for_agent_prompt.zig
git commit -m "feat(spawn_sub_agent): thread inherited_context through call chain"
```

---

## Chunk 5: Wire the formatter into `buildMessages`

### Task 5.1: Append the rendered history to `systemContent`

**Files:**
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (call the formatter, append to systemContent)

- [ ] **Step 1: Import the helper**

At the top of `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (after the existing imports), add:
```zig
const inherited_context = @import("inherited_context.zig");
```

- [ ] **Step 2: Compute the history block after `systemContent` is built**

After the line:
```zig
    const systemContent = try prompt.build_agent_prompt(allocator, io, cwd, skills, memoryMd, backgroundProcessmessage, agentUsed, tools, activity_info, environment);
```

Add:
```zig
    // Render inherited parent conversation history (if requested) and append
    // it to the system prompt as a labelled, read-only block.
    const inherited_md = inherited_context.formatHistory(
        allocator,
        db,
        parent_session_id, // the parent's session_id, NOT the sub-agent's
        inherited_context.parseMode(inherited_context_mode) catch .none,
    ) catch blk: {
        std.log.warn("buildMessages: failed to render inherited_context: mode={s}", .{inherited_context_mode});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(inherited_md);

    var final_system: std.ArrayList(u8) = .empty;
    defer final_system.deinit(allocator);
    try final_system.appendSlice(allocator, systemContent);
    if (inherited_md.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, inherited_md);
    }
    const final_system_content = try final_system.toOwnedSlice(allocator);
```

- [ ] **Step 3: Use the new `final_system_content` instead of `systemContent`**

Change:
```zig
    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = systemContent,
    };
```
to:
```zig
    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = final_system_content,
    };
```

Remove the now-unused `systemContent` variable (or keep both — `systemContent` is freed by the allocator when the function returns; `final_system_content` IS the new system message content).

- [ ] **Step 4: Add a `parent_session_id` parameter to `buildMessages`**

Wait — the function needs the parent session id, not the sub-agent's own session id. Update the function signature to add it as a new parameter:

```zig
pub fn buildMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,         // sub-agent's own session
    parent_session_id: []const u8,  // NEW: for inherited context lookup
    historyMessages: []TUIHistory,
    tools: []tool_models.AgentTool,
    inherited_context_mode: []const u8 = "",
) ![]agent.AgentMessage {
```

And in `workflow.zig:389` (the call site in `runAgenticMultiStepnew`), update the call to pass `copy_parent_session_id` (which is already declared at line 169):

```zig
        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id, db_messages, merged_tools, copy_inherited_context);
```

- [ ] **Step 5: Remove the now-unused `std.debug.print` lines if they reference `systemContent`**

The `std.debug.print("DEBUG_BUILD: systemContent size={d} bytes\n", .{systemContent.len});` line (around line 60) is a debug leftover. Either:
- Update it to print `final_system_content.len` (preferred — keeps the diagnostic), or
- Delete it.

- [ ] **Step 6: Build and verify**

Run: `timeout 120 zig build 2>&1 | tail -n 30`
Expected: clean build, no warnings.

Run: `timeout 240 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 30`
Expected: All previous tests still pass. The 19 tests from `inherited_context_test.zig` are still green.

Run: `timeout 240 zig build test:agent --summary all 2>&1 | tail -n 30`
Expected: All previous tests pass. The 5 tests from `spawn_sub_agent_test.zig` are still green.

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig \
        src/ai_workflow/tui/workflow.zig
git commit -m "feat(spawn_sub_agent): render inherited_context into sub-agent system prompt"
```

---

## Chunk 6: Verification

### Task 6.1: Full test sweep + manual smoke test

- [ ] **Step 1: Run the full test suite**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test:ai_workflow:tui --summary all 2>&1 | tail -n 30
timeout 240 zig build test:agent --summary all 2>&1 | tail -n 30
```

Expected: All tests pass. New test count:
- `inherited_context_test.zig`: 19 (12 parser + 7 formatter)
- `spawn_sub_agent_test.zig`: 5 (tool-level parser)
- Total: 24 new tests.

- [ ] **Step 2: Manual smoke test via the desktop app**

1. Start the desktop app (`bun run tauri:dev` or however this project runs).
2. Open a chat, send 2-3 user/assistant turns.
3. Send a message that triggers `spawn_sub_agent` with `inherited_context: "last:3"` on each sub-agent.
4. Inspect the sub-agent's first user/system message (dev tools → SSE inspector) and confirm:
   - The system prompt contains `## Conversation History From Parent Agent`
   - The bullets are user/assistant turns from the parent in order
   - Tool messages are NOT included
5. Send a follow-up that triggers `spawn_sub_agent` with `inherited_context: "none"` (or no parameter).
6. Confirm no `## Conversation History` block in the sub-agent's system prompt.

- [ ] **Step 3: Memory capture**

If anything non-obvious was learned during implementation (API quirks, build issues, mistakes the executor made), update `.nalar/memories/` with a one-paragraph memory file. Examples of when to add a memory:
- Had to do something zig-version-specific that wasn't documented
- A test pattern that didn't work and the fix
- A build error message that took a long time to diagnose

Skip this step if execution was clean.

- [ ] **Step 4: Final commit (if Step 3 added anything)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add .nalar/memories/
git commit -m "docs(memory): capture learnings from inherited_context implementation"
```

---

## Out of scope (follow-up work, not in this plan)

- Inheriting tool messages from the parent (filtered out in v1)
- Token-aware truncation (v1 uses a coarse 20 KB cap and 50-message cap)
- Re-using the parent's session skills/memory in the sub-agent
- A new top-level test for the end-to-end spawn workflow (manual smoke test only in v1)
