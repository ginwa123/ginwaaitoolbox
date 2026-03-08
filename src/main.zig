const std = @import("std");
const tree1 = @import("nalarcore");
const agentMod = tree1.agent;
const ipc = tree1.ipc;
const agent = tree1.agent;
const ai_workflow = tree1.ai_workflow;
const session_monitor = tree1.session_monitor;
const tui_workflow = tree1.ai_workflow;
const ai_workflow_mod = tree1.ai_workflow_models;
const sqlite = tree1.sqlite;
const migrations = tree1.migrations;

pub const IPCMessage = struct {
    app_type: []const u8 = "",
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
    if (extractTag(data, "app_type", allocator)) |val| {
        msg.app_type = try decodeXmlEntities(allocator, val);
    }

    return msg;
}

fn killExistingProcess() void {
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

        // Check if this is the backend process (not the TUI)
        // The cmdline format is typically: "/path/to/zigginagentic\0..."
        // We want to match "zigginagentic" but NOT "zigginagentic-tui"
        const cmdline_str = std.mem.sliceTo(cmdline, 0);
        if (std.mem.endsWith(u8, cmdline_str, "zigginagentic") or
            std.mem.indexOf(u8, cmdline_str, "/zigginagentic") != null)
        {
            // Double-check it's not the TUI by looking for "-tui" suffix
            if (std.mem.indexOf(u8, cmdline_str, "zigginagentic-tui") == null) {
                std.debug.print("Killing existing backend process {d}\n", .{pid_num});
                _ = std.c.kill(pid_num, 15);
            }
        }
    }
}

/// Get the database path following XDG standards: ~/.config/zigginagentic/agent.db
/// Creates the config directory if it doesn't exist.
/// Caller owns the returned memory.
fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set", .{});
        return error.HomeNotFound;
    };

    // Build the config directory path: ~/.config/zigginagentic
    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "zigginagentic",
    });
    defer allocator.free(config_dir);

    // Create the directory if it doesn't exist (makePath creates all parent directories too)
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create config directory: {s}", .{config_dir});
            return err;
        }
    };

    // Build the full database path
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    // Return as null-terminated string (required by sqlite init)
    return try allocator.dupeZ(u8, db_path);
}

pub fn main() !void {
    killExistingProcess();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const parentAllocator = gpa.allocator();

    // Load LLM config from JSON file
    var llm_config = tree1.config.LlmConfig.init(parentAllocator, null) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    defer llm_config.deinit();
    try llm_config.validate();

    // Get database path following XDG standards: ~/.config/zigginagentic/agent.db
    const db_path = try getDbPath(parentAllocator);
    defer parentAllocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(db_path);

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

    try migrationManager.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration007AddSessionTracking.version,
        .name = migrations.Migration007AddSessionTracking.name,
        .up = migrations.Migration007AddSessionTracking.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration008AddSessionSkills.version,
        .name = migrations.Migration008AddSessionSkills.name,
        .up = migrations.Migration008AddSessionSkills.up,
    });
    try migrationManager.registerMigration(.{
        .version = migrations.Migration009RemoveCreatedColumn.version,
        .name = migrations.Migration009RemoveCreatedColumn.name,
        .up = migrations.Migration009RemoveCreatedColumn.up,
    });
    try migrationManager.runMigrations();

    const ctxParent = try parentAllocator.create(ai_workflow_mod.ContextIPCTui);
    defer parentAllocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{
        .db = &dbSqlite,
        .llm_config = &llm_config,
    };

    // Initialize global cancellation registry
    ai_workflow.cancellation_registry.initGlobalRegistry(parentAllocator);
    defer ai_workflow.cancellation_registry.deinitGlobalRegistry();

    // Spawn session monitor to exit if no active sessions
    var monitor = session_monitor.SessionMonitor.spawn() catch |err| {
        std.log.err("Failed to spawn session monitor: {s}", .{@errorName(err)});
        return err;
    };
    defer monitor.stop();

    var server = ipc.IpcServer.init(parentAllocator, ctxParent);

    server.messageIncoming(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, conn_fd: std.posix.fd_t) void {
            std.debug.print("message incoming {s}\n", .{data});

            const ctxTui = @as(*ai_workflow_mod.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            const t = parseMessage(allocator, data) catch |err| {
                std.debug.print("parse error: {}\n", .{err});
                return;
            };

            if (std.mem.eql(u8, t.app_type, "tui")) {

                // Handle cancel command first
                if (std.mem.eql(u8, t.command_type, "cancel")) {
                    if (ai_workflow.cancellation_registry.getGlobalRegistry()) |registry| {
                        registry.cancel(t.session_id);
                    }
                    return;
                }
                // Register/reset session for cancellation tracking
                if (ai_workflow.cancellation_registry.getGlobalRegistry()) |registry| {
                        registry.register(t.session_id) catch |err| {
                            std.debug.print("Failed to register session: {}\n", .{err});
                            return;
                        };
                    }
                var workflowAsk = ai_workflow.TUIWorkflow.init(allocator, ctxTui.db) catch |err| {
                    std.debug.print("Failed to init workflow: {}\n", .{err});
                    return;
                };

                // Load previously saved skills for this session
                // workflowAsk.loadSkillsFromDB(allocator) catch |err| {
                //     std.debug.print("Failed to load skills from database: {s}\n", .{@errorName(err)});
                // };
                if (std.mem.eql(u8, t.command_type, "run_llm")) {
                    workflowAsk.run(allocator, t.session_id, t.message, t.cwd_session, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, conn_fd);
                }
                if (std.mem.eql(u8, t.command_type, "get_sessions")) {
                    // todo rework
                    // const sessions = workflowAsk.get_session_by_dir(allocator) catch |err| {
                    //     std.debug.print("Failed to get sessions: {}\n", .{err});
                    //     return;
                    // };
                    // workflowAsk.sendSessionsResponse(allocator, sessions);
                    // _ = try workflowAsk.sendUserChoice(allocator);
                }
            }

            std.debug.print("Received: {s}\n", .{data});
        }
    }.handler);

    try server.run();
}
