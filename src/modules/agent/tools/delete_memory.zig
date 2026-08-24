//! Agent-callable tool: `delete_memory` — PERMANENTLY remove one row
//! from the agent_memories store by id.
//!
//! Plan: docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md (Task 2)
//! Task: task_1787546484030_8
//!
//! Wire shape:
//!   input:  { id: string }            (id is REQUIRED)
//!   output: <delete_memory><id>...</id><deleted>true|false</deleted></delete_memory>
//!   or:     <delete_memory><error>...</error></delete_memory>
//!
//! The actual DELETE lives in `agent_memories.deleteMemory`.
//! This file is a thin XML wrapper (mirrors the `save_memory.zig`
//! pattern).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

/// Input for `delete_memory`.
pub const DeleteMemoryInput = struct {
    /// Exact memory id (mem_<16-hex> or caller-provided slug).
    /// Required. Empty string → error.
    id: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const delete_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_memory",
        .description =
            \\Permanently delete ONE saved memory by its exact `id`. Use this when a note is genuinely obsolete (e.g. the user asks to forget it, or a correction invalidates the old entry entirely).
            \\
            \\**WARNING: deletion is permanent. There is no undo, no soft-delete, no recycle bin.** When in doubt, prefer overwriting the existing note via `save_memory` (UPSERT) over deleting.
            \\
            \\Wire: pass the exact `id` from a prior `save_memory`/`load_memory` call. If unsure which row to target, call `load_memory` first to find the id.
            \\
            \\Behavior:
            \\- id matches a row → row is removed (FTS5 index updates automatically), `<deleted>true</deleted>`.
            \\- id is unknown → no error, returns `<deleted>false</deleted>` (idempotent — safe to retry).
            \\- id is empty → `<error>id is required</error>`.
            \\
            \\Scope: deleting a user-preference memory is generally the WRONG action unless the user explicitly asks — the load-first rule applies. Deleting your own scratch notes (e.g. things tagged `scratch` or `temp`) is fine when no longer needed.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "id", .type = "string", .description = "Exact memory id (mem_<16-hex> or caller-provided slug). Required." },
            },
            .required = &.{"id"},
        },
    },
};

/// Execute delete_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeDeleteMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: DeleteMemoryInput,
) ![]const u8 {
    if (input.id.len == 0) {
        return errorXml(allocator, "id is required");
    }

    const deleted = agent_memories.deleteMemory(allocator, db, input.id) catch |err| {
        const msg = switch (err) {
            error.InvalidId => "id is required",
            else => @errorName(err),
        };
        return errorXml(allocator, msg);
    };

    return successXml(allocator, input.id, deleted);
}

fn successXml(allocator: std.mem.Allocator, id: []const u8, deleted: bool) ![]u8 {
    const id_e = try xmlEscape(allocator, id);
    defer allocator.free(id_e);
    return std.fmt.allocPrint(allocator,
        "<delete_memory>" ++
        "<id>{s}</id>" ++
        "<deleted>{}</deleted>" ++
        "</delete_memory>",
        .{ id_e, deleted });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<delete_memory><error>{s}</error></delete_memory>",
        .{escaped});
}

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

const delete_memory_mod = @import("delete_memory.zig");

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

test "delete_memory_tool: tool name is 'delete_memory'" {
    const tool = delete_memory_mod.delete_memory_tool;
    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("delete_memory", tool.function.name);
}

test "delete_memory_tool: parameters include only id, which is required" {
    const tool = delete_memory_mod.delete_memory_tool;
    const params = tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 1), params.properties.len);
    try testing.expectEqualStrings("id", params.properties[0].name);
    try testing.expectEqualStrings("string", params.properties[0].type);
    try testing.expectEqual(@as(usize, 1), params.required.len);
    try testing.expectEqualStrings("id", params.required[0]);
}

test "delete_memory_tool: returns success envelope with deleted=true on existing row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "row to be deleted",
        .tags = &.{},
        .id = "to-delete",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    const xml = try delete_memory_mod.executeDeleteMemory(alloc, &ctx.db, .{ .id = "to-delete" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>to-delete</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>true</deleted>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "delete_memory_tool: returns success envelope with deleted=false on unknown id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const xml = try delete_memory_mod.executeDeleteMemory(alloc, &ctx.db, .{ .id = "ghost" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>ghost</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>false</deleted>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "delete_memory_tool: returns error envelope on empty id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const xml = try delete_memory_mod.executeDeleteMemory(alloc, &ctx.db, .{ .id = "" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>") == null);
}

test "delete_memory_tool: round-trip — deleted row is gone from getMemoryById" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "round-trip target",
        .tags = &.{"test"},
        .id = "rt-target",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    const before = (try agent_memories.getMemoryById(alloc, &ctx.db, "rt-target")) orelse return error.RowMissingBeforeDelete;
    defer agent_memories.freeMemoryRow(alloc, before);

    const xml = try delete_memory_mod.executeDeleteMemory(alloc, &ctx.db, .{ .id = "rt-target" });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>true</deleted>") != null);

    const after = try agent_memories.getMemoryById(alloc, &ctx.db, "rt-target");
    try testing.expect(after == null);
}