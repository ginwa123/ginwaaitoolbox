const std = @import("std");
const tree1 = @import("tree1");
const agentMod = @import("modules/agent/agent.zig");
const ipc = @import("modules/ipc/ipc.zig");
const agent = @import("modules/agent/agent.zig");
const ai_workflow = @import("ai_workflow/ask_llm_workflow.zig");
const ai_workflow_mod = @import("ai_workflow/models.zig");
const sqlite = @import("modules/databases/sqlite/sqlite.zig");
const migrations = @import("modules/databases/sqlite/migrations.zig");

var g_api_key: []const u8 = "";
var g_model: []const u8 = "";
var g_base_url: []const u8 = "";

test {
    _ = @import("modules/databases/sqlite/sqlite_test.zig");
    _ = @import("modules/databases/sqlite/migrations_test.zig");
    _ = @import("modules/agent/tools/bash_test.zig");
    _ = @import("modules/agent/agent_test.zig");
    _ = @import("modules/ipc/ipc_test.zig");
    _ = @import("ai_workflow/ask_llm_workflow_test.zig");
}

pub const IPCMessage = struct {
    command_type: []const u8 = "",
    session_id: []const u8 = "",
    message: []const u8 = "",
    cwd_session: []const u8 = "",
};

/// Extract content between XML tags
pub fn extractTag(xml: []const u8, tag: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(allocator, "<{s}>", .{tag}) catch return null;
    defer allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(allocator, "</{s}>", .{tag}) catch return null;
    defer allocator.free(end_tag);

    const start_idx = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const content_start = start_idx + start_tag.len;
    const end_idx = std.mem.indexOf(u8, xml[content_start..], end_tag) orelse return null;
    
    return xml[content_start .. content_start + end_idx];
}

/// Decode XML entities
pub fn decodeXmlEntities(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try result.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try result.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try result.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try result.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try result.append(allocator, '\'');
                i += 6;
            } else {
                try result.append(allocator, s[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, s[i]);
            i += 1;
        }
    }
    
    return result.toOwnedSlice(allocator);
}

/// Parse XML message into IPCMessage struct
pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) !IPCMessage {
    var msg: IPCMessage = .{};
    
    if (extractTag(data, "command_type", allocator)) |val| {
        msg.command_type = try decodeXmlEntities(allocator, val);
    }
    if (extractTag(data, "session_id", allocator)) |val| {
        msg.session_id = try decodeXmlEntities(allocator, val);
    }
    if (extractTag(data, "content", allocator)) |val| {
        msg.message = try decodeXmlEntities(allocator, val);
    }
    if (extractTag(data, "cwd_session", allocator)) |val| {
        msg.cwd_session = try decodeXmlEntities(allocator, val);
    }
    
    return msg;
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

fn killExistingProcess() void {
    const process_name = "zigginagentic";
    const self_pid = std.c.getpid();

    var proc_dir = std.fs.openDirAbsolute("/proc", .{
        .iterate = true,
    }) catch return;
    defer proc_dir.close();

    var iterator = proc_dir.iterate();
    while (true) {
        const entry = iterator.next() catch break;
        if (entry == null) break;
        const entry_name = entry.?.name;
        const pid_num = std.fmt.parseInt(std.posix.pid_t, entry_name, 10) catch continue;
        if (pid_num == self_pid) continue;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid_num}) catch continue;
        const cmdline_file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer cmdline_file.close();

        const cmdline = cmdline_file.readToEndAlloc(std.heap.page_allocator, 4096) catch continue;
        defer std.heap.page_allocator.free(cmdline);

        if (std.mem.indexOf(u8, cmdline, process_name) != null) {
            std.debug.print("Killing existing process {d}\n", .{pid_num});
            _ = std.c.kill(pid_num, 15);
        }
    }
}

pub fn main() !void {
    killExistingProcess();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const parentAllocator = gpa.allocator();

    try loadEnv();

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(":memory:");

    var migrationManager = migrations.MigrationManager.init(parentAllocator, &dbSqlite);
    defer migrationManager.deinit();
    try migrationManager.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try migrationManager.runMigrations();

    const ctxParent = try parentAllocator.create(ai_workflow_mod.ContextIPCTui);
    defer parentAllocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{ .db = &dbSqlite };

    var server = ipc.IpcServer.init(parentAllocator, ctxParent);

    server.messageIncoming(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, conn_fd: std.posix.fd_t) void {
            std.debug.print("message incoming {s}\n", .{data});

            const ctxTui = @as(*ai_workflow_mod.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            const t = parseMessage(allocator, data) catch |err| {
                std.debug.print("parse error: {}\n", .{err});
                return;
            };

            if (std.mem.eql(u8, t.command_type, "agent_ask")) {
                var workflowAsk = ai_workflow.AskLLMWorkflow{
                    .db = ctxTui.db,
                    .allocator = allocator,
                    .conn_fd = conn_fd,
                    .api_key = g_api_key,
                    .model = g_model,
                    .base_url = g_base_url,
                    .message = t.message,
                    .session_id = t.session_id,
                    .cwd = t.cwd_session,
                };
                workflowAsk.run();
            }

            std.debug.print("Received: {s}\n", .{data});
        }
    }.handler);

    try server.run();
}
