const std = @import("std");

const tree1 = @import("nalarcore");
const agentMod = tree1.agent;
const http_server = tree1.http_server;
const httpz = http_server.httpz;
const agent = tree1.agent;
const ai_workflow = tree1.ai_workflow;
const session_monitor = tree1.session_monitor;
const tui_workflow = tree1.ai_workflow;
const ai_workflow_mod = tree1.ai_workflow_models;
const sqlite = tree1.sqlite;
const migrations = tree1.migrations;

pub const CommandMessage = struct {
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

/// Parse message (JSON or XML) into CommandMessage struct
pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) !CommandMessage {
    // Try JSON first (HTTP format)
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        // Fall back to XML parsing (IPC format)
        var msg: CommandMessage = .{};

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
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    var msg: CommandMessage = .{};

    if (root.get("command_type")) |v| {
        msg.command_type = try allocator.dupe(u8, v.string);
    }
    if (root.get("session_id")) |v| {
        msg.session_id = try allocator.dupe(u8, v.string);
    }
    if (root.get("content")) |v| {
        msg.message = try allocator.dupe(u8, v.string);
    }
    if (root.get("cwd_session")) |v| {
        msg.cwd_session = try allocator.dupe(u8, v.string);
    }

    // MUST deinit parsed AFTER we've dupe'd all needed strings
    parsed.deinit();

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
        // The cmdline format is typically: "/path/to/nalar\0..."
        // We want to match "nalar" but NOT "nalar-tui"
        const cmdline_str = std.mem.sliceTo(cmdline, 0);
        if (std.mem.endsWith(u8, cmdline_str, "nalar") or
            std.mem.indexOf(u8, cmdline_str, "/nalar") != null)
        {
            // Double-check it's not the TUI by looking for "-tui" suffix
            if (std.mem.indexOf(u8, cmdline_str, "nalar-tui") == null) {
                std.debug.print("Killing existing backend process {d}\n", .{pid_num});
                _ = std.c.kill(pid_num, 15);
            }
        }
    }
}

/// Get the database path following XDG standards: ~/.config/nalar/agent.db
/// Creates the config directory if it doesn't exist.
/// Caller owns the returned memory.
fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set", .{});
        return error.HomeNotFound;
    };

    // Build the config directory path: ~/.config/nalar
    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "nalar",
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
    // killExistingProcess();

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

    // Get database path following XDG standards: ~/.config/nalar/agent.db
    const db_path = try getDbPath(parentAllocator);
    defer parentAllocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(db_path);

    var migrationManager = migrations.MigrationManager.init(parentAllocator, &dbSqlite);
    defer migrationManager.deinit();
    try migrations.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    // Get platform-appropriate temp directory
    // Use /tmp as fallback (more predictable than HOME)
    const tmp_path = std.posix.getenv("TMPDIR") orelse
        std.posix.getenv("TEMP") orelse
        std.posix.getenv("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(parentAllocator, &.{ tmp_path, "agentic_coding.log" });
    defer parentAllocator.free(log_file_path);

    // SET PANIC LOG PATH EARLY - before any code that could panic
    tree1.setPanicLogPath(log_file_path);

    // Initialize global logger
    tree1.logger.initGlobalColor(parentAllocator, .{
        .min_level = .info,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer tree1.logger.deinitGlobal();

    const global_logger_ptr = tree1.logger.getGlobal().?;

    const ctxParent = try parentAllocator.create(ai_workflow_mod.ContextIPCTui);
    defer parentAllocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{
        .db = &dbSqlite,
        .llm_config = &llm_config,
        .logger = global_logger_ptr,
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

    // Default port (0 means auto-select, HttpServer will use 8080)
    var port: u16 = 0;

    // Parse command line arguments
    const args = try std.process.argsAlloc(parentAllocator);
    defer std.process.argsFree(parentAllocator, args);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --port requires a value\n", .{});
                return error.InvalidArgs;
            }
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 2;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nalar [--port PORT]\n", .{});
            std.debug.print("  --port PORT    Port to run the HTTP server on (default: 8080)\n", .{});
            return;
        }
    }

    var server = http_server.HttpServer.init(parentAllocator, ctxParent, port);

    server.setMessageHandler(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void {
            std.debug.print("message incoming {s}\n", .{data});

            const ctxTui = @as(*ai_workflow_mod.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            const t = parseMessage(allocator, data) catch |err| {
                std.debug.print("parse error: {}\n", .{err});
                return;
            };

            var workflowAsk = ai_workflow.TUIWorkflow.init(ctxTui.db, ctxTui.logger);

            // Load previously saved skills for this session
            // workflowAsk.loadSkillsFromDB(allocator) catch |err| {
            //     std.debug.print("Failed to load skills from database: {s}\n", .{@errorName(err)});
            // };
            if (std.mem.eql(u8, t.command_type, "run_llm")) {
                std.debug.print("COMMAND: run_llm with session_id={s}, message={s}\n", .{ t.session_id, t.message });
                // Pass 0 as conn_fd - HTTP mode doesn't use socket
                std.debug.print("LAUNCHING WORKFLOW for session_id={s}...\n", .{t.session_id});
                workflowAsk.run(allocator, t.session_id, t.message, t.cwd_session, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, ctxTui.llm_config);
                std.debug.print("WORKFLOW RETURNED for session_id={s}\n", .{t.session_id});
            }
            if (std.mem.eql(u8, t.command_type, "get_sessions")) {
                // Get sessions from database
                std.debug.print("COMMAND: get_sessions\n", .{});

                // TODO: Query sessions from database and return them
            }
            if (std.mem.eql(u8, t.command_type, "create_session")) {
                // Create a new session
                std.debug.print("COMMAND: create_session\n", .{});

                // For now, generate a session ID and return it
                // In production, this would create a session in the database
                var session_id_buf: [64]u8 = undefined;
                const session_id = std.fmt.bufPrint(&session_id_buf, "session_{}", .{std.time.timestamp()}) catch "session_error";

                // Use a fixed-size buffer for the response
                var response_buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(&response_buf, "{{\"sessionId\":\"{s}\"}}", .{session_id}) catch unreachable;

                // Send response back to client
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    const event = http_server.SseEvent{
                        .event_type = "session_created",
                        .data = response,
                    };
                    sse_manager.sendEvent(session_id, event) catch |err| {
                        std.debug.print("Failed to send session_created response: {s}\n", .{@errorName(err)});
                    };
                }

                std.debug.print("Created session: {s}\n", .{session_id});
            }
            if (std.mem.eql(u8, t.command_type, "ping")) {
                // Ping command - check if session is still connected via SSE
                // Return JSON response to tell TUI whether to reconnect
                std.debug.print("COMMAND: ping from session_id={s}\n", .{t.session_id});

                // Use a fixed-size buffer for the response (max 256 bytes is plenty)
                var response_buf: [256]u8 = undefined;
                var response: []const u8 = undefined;

                if (http_server.getGlobalSseManager()) |sse_manager| {
                    if (sse_manager.hasSession(t.session_id)) {
                        response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"connected\":true}}", .{t.session_id}) catch unreachable;
                        std.debug.print("Pong: session {s} is connected\n", .{t.session_id});
                    } else {
                        response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{t.session_id}) catch unreachable;
                        std.debug.print("Pong: session {s} not connected, TUI should reconnect SSE\n", .{t.session_id});
                    }
                } else {
                    response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{t.session_id}) catch unreachable;
                }
                // Send the response back to the TUI via SSE event
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    const event = http_server.SseEvent{
                        .event_type = "pong",
                        .data = response,
                    };
                    sse_manager.sendEvent(t.session_id, event) catch |err| {
                        std.debug.print("Failed to send pong response: {s}\n", .{@errorName(err)});
                    };
                }
            }

            std.debug.print("Received: {s}\n", .{data});
        }
    }.handler);

    // Set session handler for synchronous session operations (create/get sessions)
    server.setSessionHandler(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, res: *httpz.Response) void {
            std.debug.print("session handler called with: {s}\n", .{data});

            // Note: ctx can be used for database access if needed later
            _ = ctx;

            // Parse the request body as JSON
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
                res.status = 400;
                res.body = "{\"error\":\"Invalid JSON\"}";
                return;
            };
            defer parsed.deinit();

            const root = parsed.value.object;

            // Get optional agent_type from request
            var agent_type: []const u8 = "general";
            if (root.get("agent_type")) |v| {
                agent_type = v.string;
            }

            // Generate session ID
            var session_id_buf: [64]u8 = undefined;
            const session_id = std.fmt.bufPrint(&session_id_buf, "session_{}", .{std.time.timestamp()}) catch "session_error";

            // Return JSON response
            var response_buf: [256]u8 = undefined;
            const response = std.fmt.bufPrint(&response_buf, "{{\"sessionId\":\"{s}\",\"agentType\":\"{s}\"}}", .{ session_id, agent_type }) catch unreachable;

            res.status = 200;
            res.body = response;

            std.debug.print("Created session: {s} with agentType: {s}\n", .{ session_id, agent_type });
        }
    }.handler);

    try server.run();
}
