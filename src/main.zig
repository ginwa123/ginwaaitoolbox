const std = @import("std");
const tree1 = @import("tree1");
const agentMod = @import("modules/agent/agent.zig");
const ipc = @import("modules/ipc/ipc.zig");
const agent = @import("modules/agent/agent.zig");
const ai_workflow = @import("ai_workflow/ask_llm_workflow.zig");
const sqlite = @import("modules/databases/sqlite/sqlite.zig");

var g_api_key: []const u8 = "";
var g_model: []const u8 = "";
var g_base_url: []const u8 = "";

test {
    _ = @import("modules/databases/sqlite/sqlite_test.zig");
    _ = @import("modules/agent/tools/bash_test.zig");
    _ = @import("modules/agent/agent_test.zig");
    _ = @import("modules/ipc/ipc_test.zig");
}

pub const IPCMessage = struct {
    command_type: []const u8,
};

pub fn parseMessage(comptime T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    const json = try std.json.parseFromSlice(T, allocator, data, .{});
    defer json.deinit();
    return json.value;
}

fn loadEnv() !void {
    const env_path = "/home/ginwa/agentic_coding_zig/tree1/src/.env";
    const content = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, env_path, 1024);
    defer std.heap.page_allocator.free(content);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "API_KEY=")) {
            g_api_key = try std.heap.page_allocator.dupe(u8, line[8..]);
        } else if (std.mem.startsWith(u8, line, "MODEL=")) {
            g_model = try std.heap.page_allocator.dupe(u8, line[6..]);
        } else if (std.mem.startsWith(u8, line, "BASE_URL=")) {
            g_base_url = try std.heap.page_allocator.dupe(u8, line[9..]);
        }
    }
}

pub const ContextIPCTui = struct {
    db: *sqlite.SqliteBackend,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const parentAllocator = gpa.allocator();

    try loadEnv();

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(":memory:");

    const ctxParent = try parentAllocator.create(ContextIPCTui);
    ctxParent.* = ContextIPCTui{ .db = &dbSqlite };

    var server = ipc.IpcServer.init(parentAllocator, ctxParent);

    server.messageIncoming(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void {
            const ctxTui = @as(*ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const db = ctxTui.db;
            _ = db;

            const t = parseMessage(IPCMessage, allocator, data) catch |err| {
                std.debug.print("parse error: {}\n", .{err});
                return;
            };

            if (std.mem.eql(u8, t.command_type, "agent_ask")) {
                var agenttt = try agent.Agent.init(allocator);
                defer agenttt.deinit();

                agenttt.apiKey = g_api_key;
                agenttt.model = g_model;
                agenttt.baseUrl = g_base_url;
            }

            std.debug.print("Received: {s}\n", .{data});
        }
    }.handler);

    try server.run();
}
