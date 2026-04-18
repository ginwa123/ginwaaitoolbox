const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;

/// Simple test setup: create the tables needed for worker operations
fn setupWorkerTables(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    // Create sessions table (needed by upsertWorker)
    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT DEFAULT 'active',
        \\    working_directory TEXT,
        \\    agent TEXT DEFAULT 'Agent',
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    
    // Create worker table
    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity INTEGER,
        \\    last_activity_description TEXT
        \\)
    , &.{});
}

test "update_activity updates worker by session_id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create in-memory SQLite database
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup only the worker table (no full migration needed)
    try setupWorkerTables(allocator, &db);

    const session_id = "test_session_12345";

    // Register a worker using upsertWorker (this is what workflow does)
    try llm_history.upsertWorker(allocator, &db, session_id, session_id, "/test/cwd");

    // Verify worker was created
    const workers = try llm_history.get_active_workers(allocator, &db);
    try std.testing.expect(workers.len > 0);

    // Find our worker
    var found_worker: bool = false;
    for (workers) |worker| {
        if (std.mem.eql(u8, worker.session_id, session_id)) {
            found_worker = true;
            // Verify initial description is empty
            try std.testing.expectEqual(worker.last_activity_description.len, 0);
        }
        allocator.free(worker.session_id);
        allocator.free(worker.working_directory);
        allocator.free(worker.last_activity_description);
    }
    try std.testing.expect(found_worker);

    // Update activity with description
    const test_thought = "[2025-01-20 16:50] test_session_12345 @ /test/cwd | Testing | Testing update_activity";
    try llm_history.updateWorkerActivityWithDescription(allocator, &db, session_id, test_thought);

    // Fetch workers again and verify description was updated
    const updated_workers = try llm_history.get_active_workers(allocator, &db);
    for (updated_workers) |worker| {
        if (std.mem.eql(u8, worker.session_id, session_id)) {
            try std.testing.expect(worker.last_activity_description.len > 0);
            try std.testing.expect(std.mem.eql(u8, worker.last_activity_description, test_thought));
            std.debug.print("✓ Worker description updated: {s}\n", .{worker.last_activity_description});
        }
        allocator.free(worker.session_id);
        allocator.free(worker.working_directory);
        allocator.free(worker.last_activity_description);
    }
}

test "update_activity fails gracefully with mismatched worker_id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup only the worker table
    try setupWorkerTables(allocator, &db);

    const session_id = "test_session_12345";
    const wrong_worker_id = "worker_test_session_12345"; // This is the WRONG format

    // Register a worker with session_id as worker_id
    try llm_history.upsertWorker(allocator, &db, session_id, session_id, "/test/cwd");

    // Try to update with wrong worker_id - this should fail (UPDATE matches 0 rows)
    llm_history.updateWorkerActivityWithDescription(allocator, &db, wrong_worker_id, "test") catch {
        // This is expected - the UPDATE fails because worker_id doesn't exist
        std.debug.print("✓ Correctly failed to update non-existent worker_id\n", .{});
    };

    // Verify the original worker still has empty description
    const workers = try llm_history.get_active_workers(allocator, &db);
    for (workers) |worker| {
        if (std.mem.eql(u8, worker.session_id, session_id)) {
            try std.testing.expectEqual(worker.last_activity_description.len, 0);
            std.debug.print("✓ Original worker still has empty description (bug confirmed)\n", .{});
        }
        allocator.free(worker.session_id);
        allocator.free(worker.working_directory);
        allocator.free(worker.last_activity_description);
    }
}

test "update_activity succeeds with matching worker_id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    // Setup only the worker table
    try setupWorkerTables(allocator, &db);

    const session_id = "test_session_12345";

    // Register a worker with session_id as worker_id (correct approach)
    try llm_history.upsertWorker(allocator, &db, session_id, session_id, "/test/cwd");

    // Update with matching session_id - this should succeed
    const test_thought = "[2025-01-20 16:50] test @ /test | Testing";
    try llm_history.updateWorkerActivityWithDescription(allocator, &db, session_id, test_thought);

    // Verify the update worked
    const workers = try llm_history.get_active_workers(allocator, &db);
    var found = false;
    for (workers) |worker| {
        if (std.mem.eql(u8, worker.session_id, session_id)) {
            found = true;
            try std.testing.expect(std.mem.eql(u8, worker.last_activity_description, test_thought));
            std.debug.print("✓ Successfully updated worker with matching session_id\n", .{});
        }
        allocator.free(worker.session_id);
        allocator.free(worker.working_directory);
        allocator.free(worker.last_activity_description);
    }
    try std.testing.expect(found);
}
