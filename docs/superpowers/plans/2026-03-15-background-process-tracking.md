# Background Process Tracking Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement SQLite-backed background process tracking for agent sessions, with status polling and session cancellation integration.

**Architecture:** New `session_background_process` table with CRUD operations, integrated into bash tool and session cancellation registry.

**Tech Stack:** Zig 0.15.2, SQLite (via existing sqlite.zig backend)

---

## Chunk 1: Database Migration & Background Process Module

### Task 1: Add Migration for session_background_process Table

**Files:**
- Modify: `src/modules/databases/sqlite/migrations.zig:182` (add after Migration013)
- Test: Uses existing migration test infrastructure

- [ ] **Step 1: Write the failing test**

Create a test in `src/modules/databases/sqlite/migrations_test.zig` that verifies the new table can be created and queried. First, check if migration test exists and understand its pattern.

```zig
// Add to migrations_test.zig - test that new migration can be added
test "migration 014 creates session_background_process table" {
    // This test will fail because Migration014 doesn't exist yet
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/databases/sqlite/migrations_test.zig`
Expected: FAIL - unresolved identifier Migration014

- [ ] **Step 3: Add Migration014 to migrations.zig**

Add after Migration013 (line 182):

```zig
pub const Migration014AddBackgroundProcess = struct {
    pub const version: u32 = 14;
    pub const name = "add_background_process";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_background_process (
            \\    session_id TEXT NOT NULL,
            \\    pid INTEGER NOT NULL,
            \\    command TEXT NOT NULL,
            \\    log_path TEXT NOT NULL,
            \\    started_at INTEGER NOT NULL,
            \\    status TEXT NOT NULL DEFAULT 'running',
            \\    PRIMARY KEY (session_id, pid)
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_bg_process_session ON session_background_process(session_id)", &[_][]const u8{});
    }
};
```

- [ ] **Step 4: Register Migration014 in allMigrations array**

Add to `allMigrations` slice (line 248):

```zig
.{ .version = Migration014AddBackgroundProcess.version, .name = Migration014AddBackgroundProcess.name, .up = Migration014AddBackgroundProcess.up },
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig test src/modules/databases/sqlite/migrations_test.zig`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/modules/databases/sqlite/migrations.zig
git commit -m "feat(db): add migration 014 for session_background_process table"
```

---

### Task 2: Create Background Process Database Module

**Files:**
- Create: `src/modules/databases/sqlite/background_process.zig`
- Test: `src/modules/databases/sqlite/background_process_test.zig`

- [ ] **Step 1: Write the failing test**

Create `src/modules/databases/sqlite/background_process_test.zig`:

```zig
const std = @import("std");
const sqlite = @import("sqlite.zig");
const background_process = @import("background_process.zig");

test "save and retrieve background process" {
    var allocator = std.testing.allocator;
    
    // Create in-memory database
    var db = try sqlite.SqliteBackend.init(allocator, ":memory:");
    defer db.deinit(allocator);
    
    // Create table manually for test
    try db.exec(allocator,
        \\CREATE TABLE session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &[_][]const u8{});
    
    // Save a background process
    try background_process.save(&db, allocator, "session-123", 12345, "sleep 60", "/tmp/bg_123.log", 1699999999);
    
    // Retrieve processes for session
    var processes = try background_process.getBySession(&db, allocator, "session-123");
    defer {
        for (processes) |p| allocator.free(p.command);
        allocator.free(processes);
    }
    
    try std.testing.expect(processes.len == 1);
    try std.testing.expect(processes[0].pid == 12345);
    try std.testing.expect(std.mem.eql(u8, processes[0].command, "sleep 60"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/databases/sqlite/background_process_test.zig`
Expected: FAIL - module not found

- [ ] **Step 3: Create minimal background_process.zig**

Create `src/modules/databases/sqlite/background_process.zig`:

```zig
const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const BackgroundProcess = struct {
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
};

pub fn save(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, command: []const u8, log_path: []const u8, started_at: i64) !void {
    try db.exec(allocator,
        \\INSERT OR REPLACE INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, ?, 'running')
    , &.{ session_id, std.fmt.allocPrint(allocator, "{}", .{pid}) catch unreachable, command, log_path, std.fmt.allocPrint(allocator, "{}", .{started_at}) catch unreachable });
}

pub fn getBySession(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) ![]BackgroundProcess {
    var rows = try db.query(allocator, "SELECT pid, command, log_path, started_at, status FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();
    
    var processes = std.ArrayList(BackgroundProcess).init(allocator);
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit();
    }
    
    while (try rows.next()) |row| {
        const pid_str = row.values[0];
        const command = row.values[1];
        const log_path = row.values[2];
        const started_at_str = row.values[3];
        const status = row.values[4];
        
        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);
        
        try processes.append(.{
            .session_id = session_id,
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }
    
    return processes.toOwnedSlice();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/databases/sqlite/background_process_test.zig`
Expected: PASS

- [ ] **Step 5: Add updateStatus and delete functions**

Add to `background_process.zig`:

```zig
pub fn updateStatus(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, new_status: []const u8) !void {
    try db.exec(allocator,
        \\UPDATE session_background_process SET status = ? WHERE session_id = ? AND pid = ?
    , &.{ new_status, session_id, std.fmt.allocPrint(allocator, "{}", .{pid}) catch unreachable });
}

pub fn delete(db: *sqlite.SqliteBackend, session_id: []const u8, pid: u32) !void {
    try db.exec(allocator, "DELETE FROM session_background_process WHERE session_id = ? AND pid = ?", &.{ session_id, std.fmt.allocPrint(std.mem.Allocator, "{}", .{pid}) catch unreachable });
}

pub fn getRunning(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator) ![]BackgroundProcess {
    var rows = try db.query(allocator, "SELECT session_id, pid, command, log_path, started_at, status FROM session_background_process WHERE status = 'running'", &[_][]const u8{});
    defer rows.deinit();
    
    var processes = std.ArrayList(BackgroundProcess).init(allocator);
    errdefer {
        for (processes.items) |p| {
            allocator.free(p.session_id);
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        processes.deinit();
    }
    
    while (try rows.next()) |row| {
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        const log_path = row.values[3];
        const started_at_str = row.values[4];
        const status = row.values[5];
        
        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);
        
        try processes.append(.{
            .session_id = try allocator.dupe(u8, session_id),
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
        });
    }
    
    return processes.toOwnedSlice();
}
```

- [ ] **Step 6: Add tests for new functions**

Add tests for `updateStatus`, `delete`, and `getRunning` to `background_process_test.zig`.

- [ ] **Step 7: Run all tests**

Run: `zig test src/modules/databases/sqlite/background_process_test.zig`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/modules/databases/sqlite/background_process.zig src/modules/databases/sqlite/background_process_test.zig
git commit -m "feat(db): add background_process module with CRUD operations"
```

---

## Chunk 2: Bash Tool Integration

### Task 3: Integrate Background Process Tracking with Bash Tool

**Files:**
- Modify: `src/modules/agent/tools/bash.zig` (lines ~50-80)
- Test: Add integration test

- [ ] **Step 1: Read current bash.zig implementation**

Find exact location where background process is spawned and PID is returned.

- [ ] **Step 2: Write failing integration test**

Create test that verifies when background=true, the process is saved to DB.

```zig
// In bash_test.zig or new file
test "bash background mode saves to database" {
    // This test will fail because integration doesn't exist
}
```

- [ ] **Step 3: Modify bash.zig to accept db parameter**

Update function signature to accept optional `db: ?*sqlite.SqliteBackend` parameter.

- [ ] **Step 4: Call save function after spawning**

After successfully spawning background process (getting PID), call:
```zig
if (db) |d| {
    try background_process.save(d, allocator, session_id, pid, command, log_path, std.time.timestamp());
}
```

- [ ] **Step 4: Run tests**

Run: `zig test src/modules/agent/tools/...`
Expected: PASS (existing tests + new integration)

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "feat(agent): integrate background process tracking with bash tool"
```

---

## Chunk 3: Status Polling & Session Cancellation

### Task 4: Add Status Polling to Session Monitor

**Files:**
- Modify: `src/modules/session/session_monitor.zig` (lines ~40-60)
- Test: Add test for polling

- [ ] **Step 1: Read current session_monitor.zig**

Understand current monitoring loop structure.

- [ ] **Step 2: Write failing test**

```zig
test "session monitor polls background process status" {
    // Verify polling updates status
}
```

- [ ] **Step 3: Add polling logic to session_monitor.zig**

In the existing monitor loop, add:
1. Query all 'running' processes via `background_process.getRunning()`
2. For each process, check if PID still exists (using `kill(pid, 0)`)
3. Update status based on result:
   - Process exists → 'running' (no change)
   - Process doesn't exist → check exit code, update to 'completed' or 'failed'
4. Call `background_process.updateStatus()` for changed processes

- [ ] **Step 4: Run tests**

Run: `zig test src/modules/session/session_monitor_test.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/session/session_monitor.zig
git commit -m "feat(session): add background process status polling to session monitor"
```

---

### Task 5: Add Kill All Background Processes to Cancellation Registry

**Files:**
- Modify: `src/modules/session/cancellation_registry.zig`
- Test: Add test for kill functionality

- [ ] **Step 1: Read current cancellation_registry.zig**

Understand current cancellation mechanism.

- [ ] **Step 2: Write failing test**

```zig
test "cancellation kills background processes" {
    // Verify processes are killed on session cancellation
}
```

- [ ] **Step 3: Add killBackgroundProcesses function**

Add function that:
1. Queries running processes for session via `background_process.getBySession()`
2. Sends SIGTERM to each PID
3. Updates status to 'killed' in database
4. (Optional: implement SIGKILL after timeout)

```zig
pub fn killBackgroundProcesses(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) !void {
    var processes = try background_process.getBySession(db, allocator, session_id);
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }
    
    for (processes) |p| {
        if (std.os.kill(p.pid, std.posix.SIGTERM) == 0) {
            try background_process.updateStatus(db, allocator, session_id, p.pid, "killed");
        }
    }
}
```

- [ ] **Step 4: Integrate with existing cancel() method**

Call `killBackgroundProcesses()` when session is cancelled.

- [ ] **Step 5: Run tests**

Run: `zig test src/modules/session/cancellation_registry_test.zig`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/modules/session/cancellation_registry.zig
git commit -m "feat(session): add background process cleanup on session cancellation"
```

---

## Chunk 4: Export & Final Integration

### Task 6: Export Module from Root

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add export for background_process module**

Add to root.zig:
```zig
pub const background_process = @import("modules/databases/sqlite/background_process.zig");
```

- [ ] **Step 2: Verify build**

Run: `zig build`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/root.zig
git commit -m "feat: export background_process module"
```

---

## Summary

| Chunk | Tasks | Files Changed |
|-------|-------|---------------|
| 1 | 2 | migrations.zig, background_process.zig, background_process_test.zig |
| 2 | 1 | bash.zig |
| 3 | 2 | session_monitor.zig, cancellation_registry.zig |
| 4 | 1 | root.zig |

**Total: 6 tasks across 4 chunks**

After completing all chunks, run full test suite:
```bash
zig build test
```

Expected: All tests pass
