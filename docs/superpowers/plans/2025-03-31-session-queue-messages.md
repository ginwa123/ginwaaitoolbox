# Session Queue Messages Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new database table `session_queue_messages` with columns `id`, `session_id`, `message`, including migration, CRUD operations, and tests using TDD approach.

**Architecture:** 
- Add migration (version 18) to create `session_queue_messages` table in `src/modules/databases/sqlite/migrations.zig`
- Create new module `src/ai_workflow/tui/session_queue_messages.zig` with CRUD operations following existing patterns
- Create tests in `src/ai_workflow/tui/session_queue_messages_test.zig`
- Register migration in `registerAllMigrations()`

**Tech Stack:** Zig 0.15.2, SQLite, existing database patterns from `session_table.zig`

---

## Chunk 1: TDD - Test First, Then Migration

### Task 1: Write Failing Test for SessionQueueMessage Struct

**Files:**
- Create: `src/ai_workflow/tui/session_queue_messages_test.zig`
- Modify: `src/ai_workflow/tui/session_queue_messages.zig` (to be created)
- Reference: `src/ai_workflow/tui/session_table_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const session_queue_messages = @import("session_queue_messages.zig");
const sqlite = @import("nalarcore").sqlite;

test "SessionQueueMessage struct fields" {
    const allocator = std.testing.allocator;
    const msg = session_queue_messages.SessionQueueMessage{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .message = try allocator.dupe(u8, "Hello world"),
    };
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.id);
    try std.testing.expectEqualStrings("session-1", msg.session_id);
    try std.testing.expectEqualStrings("Hello world", msg.message);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: FAIL with "cannot find module 'session_queue_messages.zig'"

- [ ] **Step 3: Create minimal struct in session_queue_messages.zig**

```zig
const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

pub const SessionQueueMessage = struct {
    id: []u8,
    session_id: []u8,
    message: []u8,

    pub fn deinit(self: SessionQueueMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.message);
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/session_queue_messages.zig src/ai_workflow/tui/session_queue_messages_test.zig
git commit -m "feat: add SessionQueueMessage struct with deinit"
```

---

### Task 2: Write Failing Test for create_queue_message

**Files:**
- Modify: `src/ai_workflow/tui/session_queue_messages.zig`
- Modify: `src/ai_workflow/tui/session_queue_messages_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "create_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL
        \\)
    , &.{});

    const msg = try session_queue_messages.create_queue_message(
        allocator, &db, "msg-1", "session-1", "Test message"
    );
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.id);
    try std.testing.expectEqualStrings("session-1", msg.session_id);
    try std.testing.expectEqualStrings("Test message", msg.message);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: FAIL with "create_queue_message' is not a member of"

- [ ] **Step 3: Add create_queue_message function**

```zig
/// Create a new queue message
pub fn create_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    message: []const u8,
) !SessionQueueMessage {
    const sql = "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, session_id, message });

    return SessionQueueMessage{
        .id = try allocator.dupe(u8, id),
        .session_id = try allocator.dupe(u8, session_id),
        .message = try allocator.dupe(u8, message),
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/session_queue_messages.zig src/ai_workflow/tui/session_queue_messages_test.zig
git commit -m "feat: add create_queue_message function"
```

---

### Task 3: Write Failing Test for get_queue_message

**Files:**
- Modify: `src/ai_workflow/tui/session_queue_messages.zig`
- Modify: `src/ai_workflow/tui/session_queue_messages_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "get_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Test message" }
    );

    const msg = try session_queue_messages.get_queue_message(allocator, &db, "msg-1");
    try std.testing.expect(msg != null);
    defer msg.?.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.?.id);
    try std.testing.expectEqualStrings("session-1", msg.?.session_id);
    try std.testing.expectEqualStrings("Test message", msg.?.message);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: FAIL with "get_queue_message' is not a member of"

- [ ] **Step 3: Add get_queue_message function**

```zig
/// Get a queue message by id
pub fn get_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?SessionQueueMessage {
    const sql = "SELECT id, session_id, message FROM session_queue_messages WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const msg = SessionQueueMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .message = try allocator.dupe(u8, row.values[2]),
        };
        row.deinit(allocator);
        return msg;
    }

    return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/session_queue_messages.zig src/ai_workflow/tui/session_queue_messages_test.zig
git commit -m "feat: add get_queue_message function"
```

---

### Task 4: Write Failing Test for get_messages_by_session

**Files:**
- Modify: `src/ai_workflow/tui/session_queue_messages.zig`
- Modify: `src/ai_workflow/tui/session_queue_messages_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "get_messages_by_session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Message 1" }
    );
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-2", "session-1", "Message 2" }
    );
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-3", "session-2", "Message 3" }
    );

    const messages = try session_queue_messages.get_messages_by_session(allocator, &db, "session-1");
    defer {
        for (messages) |m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqualStrings("msg-2", messages[1].id);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: FAIL with "get_messages_by_session' is not a member of"

- [ ] **Step 3: Add get_messages_by_session function**

```zig
/// Get all queue messages for a session
pub fn get_messages_by_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]SessionQueueMessage {
    const sql = "SELECT id, session_id, message FROM session_queue_messages WHERE session_id = ? ORDER BY id";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(SessionQueueMessage).empty;
    errdefer {
        for (messages.items) |m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = SessionQueueMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .message = try allocator.dupe(u8, row.values[2]),
        };
        try messages.append(allocator, msg);
        row.deinit(allocator);
    }

    return try messages.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/session_queue_messages.zig src/ai_workflow/tui/session_queue_messages_test.zig
git commit -m "feat: add get_messages_by_session function"
```

---

### Task 5: Write Failing Test for delete_queue_message

**Files:**
- Modify: `src/ai_workflow/tui/session_queue_messages.zig`
- Modify: `src/ai_workflow/tui/session_queue_messages_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "delete_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Test message" }
    );

    try session_queue_messages.delete_queue_message(allocator, &db, "msg-1");

    const msg = try session_queue_messages.get_queue_message(allocator, &db, "msg-1");
    try std.testing.expect(msg == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: FAIL with "delete_queue_message' is not a member of"

- [ ] **Step 3: Add delete_queue_message function**

```zig
/// Delete a queue message by id
pub fn delete_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM session_queue_messages WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/session_queue_messages.zig src/ai_workflow/tui/session_queue_messages_test.zig
git commit -m "feat: add delete_queue_message function"
```

---

## Chunk 2: Migration and Integration

### Task 6: Add Migration for session_queue_messages Table

**Files:**
- Modify: `src/modules/databases/sqlite/migrations.zig`

- [ ] **Step 1: Add Migration018CreateSessionQueueMessages struct**

Add to `migrations.zig` (before `registerAllMigrations` function):

```zig
pub const Migration018CreateSessionQueueMessages = struct {
    pub const version: u32 = 18;
    pub const name = "create_session_queue_messages";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_queue_messages (
            \\    id TEXT NOT NULL,
            \\    session_id TEXT NOT NULL,
            \\    message TEXT NOT NULL
            \\)
        , &[_][]const u8{});
        
        try db.exec(allocator, 
            "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session ON session_queue_messages(session_id)", 
            &[_][]const u8{}
        );
    }
};
```

- [ ] **Step 2: Register migration in allMigrations slice**

Add to `allMigrations` array:

```zig
.{ .version = Migration018CreateSessionQueueMessages.version, .name = Migration018CreateSessionQueueMessages.name, .up = Migration018CreateSessionQueueMessages.up },
```

- [ ] **Step 3: Add test to verify migration works**

Add to `migrations.zig` or create `migrations_test.zig`:

```zig
test "Migration018CreateSessionQueueMessages" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try Migration018CreateSessionQueueMessages.up(&db, allocator);
    
    // Verify table exists
    try db.exec(allocator, "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)", &.{ "msg-1", "session-1", "Test" });
    
    var rows = try db.query(allocator, "SELECT * FROM session_queue_messages", &.{});
    defer rows.deinit();
    
    const row = try rows.next();
    try std.testing.expect(row != null);
}
```

- [ ] **Step 4: Run tests to verify migration**

Run: `zig build test --summary all 2>&1 | head -n 100`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/databases/sqlite/migrations.zig
git commit -m "feat: add Migration018CreateSessionQueueMessages"
```

---

### Task 7: Run Full Test Suite

- [ ] **Step 1: Run full test suite**

Run: `zig build test --summary all 2>&1 | head -n 200`

- [ ] **Step 2: Verify all tests pass**

Expected: All tests PASS

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete session_queue_messages feature with migration"
```

---

## Summary

| Task | Description | Status |
|------|-------------|--------|
| 1 | SessionQueueMessage struct with tests | TDD: Fail → Pass → Commit |
| 2 | create_queue_message function | TDD: Fail → Pass → Commit |
| 3 | get_queue_message function | TDD: Fail → Pass → Commit |
| 4 | get_messages_by_session function | TDD: Fail → Pass → Commit |
| 5 | delete_queue_message function | TDD: Fail → Pass → Commit |
| 6 | Migration018CreateSessionQueueMessages | Integration |
| 7 | Full test suite verification | Verification |

**Files Created:**
- `src/ai_workflow/tui/session_queue_messages.zig` - CRUD operations
- `src/ai_workflow/tui/session_queue_messages_test.zig` - Unit tests

**Files Modified:**
- `src/modules/databases/sqlite/migrations.zig` - Added migration 18

**Database Schema:**
```sql
CREATE TABLE IF NOT EXISTS session_queue_messages (
    id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    message TEXT NOT NULL
);
CREATE INDEX idx_session_queue_messages_session ON session_queue_messages(session_id);
```
