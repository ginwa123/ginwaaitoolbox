# Sessions Table Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a `sessions` table with columns: `id`, `name`, `status` using TDD approach

**Architecture:** Add a new migration (Migration017) to create the sessions table. Create a new Zig module in `ai_workflow/tui/session_table.zig` with CRUD operations and inline tests.

**Tech Stack:** Zig 0.15.2, SQLite (libsqlite3), std.testing

---

## File Structure

| File | Purpose |
|------|---------|
| `src/ai_workflow/tui/session_table.zig` | CRUD ops + inline tests |
| `src/modules/databases/sqlite/migrations.zig` | Add Migration017 |
| `src/root.zig` | Export session_table |

---

## Task 1: Create session_table.zig (CRUD + Tests)

**Files:**
- Create: `src/ai_workflow/tui/session_table.zig`

- [ ] **Step 1: Create session_table.zig with all code (tests + implementation)**

```zig
const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

// ============================================================
// DATA STRUCTURES
// ============================================================

pub const SessionInfo = struct {
    id: []u8,
    name: []u8,
    status: []u8,

    pub fn deinit(self: SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
    }
};

// ============================================================
// CRUD FUNCTIONS
// ============================================================

pub fn create_session(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, name: []const u8) !SessionInfo {
    try db.exec(allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ id, name, "active" });

    return get_session(allocator, db, id);
}

pub fn get_session(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !SessionInfo {
    const row = try db.queryRow(allocator,
        "SELECT id, name, status FROM sessions WHERE id = ?",
        &.{id});

    defer row.deinit(allocator);

    return SessionInfo{
        .id = try allocator.dupe(u8, row.values[0]),
        .name = try allocator.dupe(u8, row.values[1]),
        .status = try allocator.dupe(u8, row.values[2]),
    };
}

pub fn update_session_status(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, new_status: []const u8) !void {
    try db.exec(allocator,
        "UPDATE sessions SET status = ? WHERE id = ?",
        &.{ new_status, id });
}

pub fn delete_session(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM sessions WHERE id = ?",
        &.{id});
}

pub fn list_sessions(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ![]SessionInfo {
    var sessions = std.ArrayList(SessionInfo).init(allocator);
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    var rows = try db.query(allocator,
        "SELECT id, name, status FROM sessions ORDER BY id",
        &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        try sessions.append(SessionInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
        });
    }

    return try sessions.toOwnedSlice();
}

// ============================================================
// TESTS (inline at bottom of file)
// ============================================================

test "SessionInfo struct exists with id, name, status fields" {
    const info = SessionInfo{
        .id = try std.testing.allocator.dupe(u8, "sess1"),
        .name = try std.testing.allocator.dupe(u8, "Test Session"),
        .status = try std.testing.allocator.dupe(u8, "active"),
    };
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "sess1", info.id);
    try std.testing.expectEqualSlices(u8, "Test Session", info.name);
    try std.testing.expectEqualSlices(u8, "active", info.status);
}

test "create_session inserts a session and returns it" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    const session = try create_session(std.testing.allocator, &db, "sess123", "My Session");
    defer session.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "sess123", session.id);
    try std.testing.expectEqualSlices(u8, "My Session", session.name);
    try std.testing.expectEqualSlices(u8, "active", session.status);
}

test "get_session retrieves a session by id" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try db.exec(std.testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ "sess1", "Test", "inactive" });

    const session = try get_session(std.testing.allocator, &db, "sess1");
    defer session.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "sess1", session.id);
    try std.testing.expectEqualSlices(u8, "Test", session.name);
    try std.testing.expectEqualSlices(u8, "inactive", session.status);
}

test "update_session_status changes status" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try db.exec(std.testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ "sess1", "Test", "active" });

    try update_session_status(std.testing.allocator, &db, "sess1", "completed");

    const session = try get_session(std.testing.allocator, &db, "sess1");
    defer session.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "completed", session.status);
}

test "delete_session removes a session" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try db.exec(std.testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ "sess1", "Test", "active" });

    try delete_session(std.testing.allocator, &db, "sess1");

    try std.testing.expectError(sqlite.Error.RowNotFound,
        get_session(std.testing.allocator, &db, "sess1"));
}

test "list_sessions returns all sessions" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try db.exec(std.testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ "sess1", "Session One", "active" });
    try db.exec(std.testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, ?, ?)",
        &.{ "sess2", "Session Two", "inactive" });

    const sessions = try list_sessions(std.testing.allocator, &db);
    defer {
        for (sessions) |s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}

test "get_session returns error for non-existent id" {
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(std.testing.allocator,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try std.testing.expectError(sqlite.Error.RowNotFound,
        get_session(std.testing.allocator, &db, "nonexistent"));
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test 2>&1 | head -n 100`
Expected: All session_table tests PASS

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/session_table.zig
git commit -m "feat: add session_table module with CRUD operations"
```

---

## Task 2: Add Migration017

**Files:**
- Modify: `src/modules/databases/sqlite/migrations.zig`

- [ ] **Step 1: Add Migration017CreateSessionsTable after Migration016**

Add this struct after the existing migrations:

```zig
pub const Migration017CreateSessionsTable = struct {
    pub const version: u32 = 17;
    pub const name = "create_sessions_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    status TEXT NOT NULL DEFAULT 'active'
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status)",
            &[_][]const u8{});
    }
};
```

- [ ] **Step 2: Add to allMigrations array**

Add to the `allMigrations` slice:

```zig
.{ .version = Migration017CreateSessionsTable.version, .name = Migration017CreateSessionsTable.name, .up = Migration017CreateSessionsTable.up },
```

- [ ] **Step 3: Register in registerAllMigrations**

Add to the `registerAllMigrations()` function.

- [ ] **Step 4: Run tests to verify migration works**

Run: `zig build test 2>&1 | head -n 50`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/databases/sqlite/migrations.zig
git commit -m "feat: add Migration017CreateSessionsTable"
```

---

## Task 3: Export session_table from root.zig

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add export for session_table**

Add after other module exports:
```zig
pub const session_table = @import("ai_workflow/tui/session_table.zig");
```

- [ ] **Step 2: Verify build**

Run: `zig build 2>&1 | head -n 30`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add src/root.zig
git commit -m "feat: export session_table module from root.zig"
```

---

## Summary

| Task | Status |
|------|--------|
| Create `src/ai_workflow/tui/session_table.zig` with CRUD + tests | ⬜ |
| Add Migration017 | ⬜ |
| Export from root.zig | ⬜ |

**Total Commits:** 3
**Verification:** `zig build test` should pass all tests.
