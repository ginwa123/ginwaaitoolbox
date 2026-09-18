// Exec wrappers for the `save_memory` / `load_memory` agent tools
// (append-only since 2026-09-12: `delete_memory` was removed per user
// decision — "memory is always add, no need edit or delete").

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const migration = @import("../migrations/migration.zig");

const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const memory_mod = nalarcore.memory;
const wrapToolOutput = tools.wrapToolOutput;

/// Probe an inner JSON payload for a top-level `"error"` key. The
/// returned slice borrows from `parsed` — keep it alive through the
/// `wrapToolOutput` call, then `deinit`. A payload that fails to parse
/// is treated as success (the producers always emit valid JSON).
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

// ─── save_memory ───

pub fn execSaveMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        memory_mod.SaveMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "save_memory failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = memory_mod.executeSaveMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "save_memory failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── load_memory ───

pub fn execLoadMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        memory_mod.LoadMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "load_memory failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = memory_mod.executeLoadMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "load_memory failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── tests ───

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

test "execSaveMemory: happy path wraps success=true and appends a new row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"row saved via exec wrapper\",\"tags\":\"test\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expectEqualStrings("save_memory", env.value.object.get("tool").?.string);
    try testing.expect(env.value.object.get("success").?.bool);
    try testing.expect(env.value.object.get("error").? == .null);
    // Inner payload rides in "data" with the saved row id.
    const data = env.value.object.get("data").?.object;
    try testing.expect(data.get("id").?.string.len > 0);

    // Saving the same payload again appends a second row (append-only).
    const result2 = try execSaveMemory(tcx, tc);
    defer if (result2.output_allocated) alloc.free(result2.output);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result2.output, .{});
    defer env2.deinit();
    try testing.expect(env2.value.object.get("success").?.bool);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "execSaveMemory: empty content surfaces inner error as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expect(!env.value.object.get("success").?.bool);
    try testing.expect(env.value.object.get("error").?.string.len > 0);
}
