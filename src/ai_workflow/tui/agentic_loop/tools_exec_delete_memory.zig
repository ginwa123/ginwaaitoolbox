// Exec wrapper for the `delete_memory` agent tool.
//
// Plan: docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md
// Task: task_1787546484030_8 (Task 3 of 6)
//
// RED PHASE: production code stub intentionally missing. See tests
// below — they exercise execDeleteMemory end-to-end and currently fail
// at compile time because execDeleteMemory is not yet defined.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const migration = @import("../../../migrations/migration.zig");

const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const delete_memory_mod = nalarcore.delete_memory;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execDeleteMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        delete_memory_mod.DeleteMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "delete_memory failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = delete_memory_mod.executeDeleteMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "delete_memory failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <delete_memory><error>...</error></delete_memory> shape and
    // surface it as a tool failure. The inner XML still rides in <data> so
    // the LLM can see the per-tool detail.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "delete_memory", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "delete_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

test "execDeleteMemory: happy path wraps success=true with deleted=true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "row to delete via exec wrapper",
        .tags = &.{"test"},
        .id = "exec-target",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("delete_memory", "{\"id\":\"exec-target\"}");

    const result = try execDeleteMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>delete_memory</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<id>exec-target</id>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<deleted>true</deleted>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);

    const after = try agent_memories.getMemoryById(alloc, &ctx.db, "exec-target");
    try testing.expect(after == null);
}

test "execDeleteMemory: empty id surfaces inner error as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("delete_memory", "{\"id\":\"\"}");

    const result = try execDeleteMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "id is required") != null);
}