const std = @import("std");
const builtin = @import("builtin");
const keybindings = @import("keybindings.zig");

// Enable TLS support for HTTP client
pub const std_options: std.Options = .{
    .http_disable_tls = false,
};

// HTTP SSE configuration
const HTTP_HOST = "127.0.0.1";
const HTTP_PORT: u16 = 8080;

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const green = "\x1b[32m";

const DOUBLE_ESC_WINDOW_MS: i64 = 500;

fn stdinBytesAvailable() c_int {
    if (builtin.os.tag == .windows) {
        return 0;
    } else {
        var bytes_available: c_int = 0;
        const result = std.posix.system.ioctl(std.posix.STDIN_FILENO, std.posix.system.T.FIONREAD, @intFromPtr(&bytes_available));
        return if (result == 0) bytes_available else 0;
    }
}

pub const CompletionState = struct {
    last_match_count: usize = 0,
    visible: bool = false,
    selected: usize = 0,
    matches: std.ArrayList([]const u8),
};

pub const COMMANDS = [_][]const u8{
    "/sessions",
    "/exit",
    "/help",
};

const App = struct {
    http_client: std.http.Client,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    original_termios: std.posix.termios,
    session_id: []u8,
    input: std.ArrayList(u8),
    pasting: bool,
    last_esc_time: ?i64 = null,
    agent_name_buf: [64]u8 = [_]u8{0} ** 64,
    keybindings: keybindings.Keybindings,
    verbose: bool = false,
    state: CompletionState = CompletionState{ .matches = .empty },

    pub fn init(allocator: std.mem.Allocator, verbose: bool) !App {
        // try spawnBackend(verbose);
        std.log.info("Spawned backend", .{});
        try waitForHttpServer(10000);
        std.log.info("HTTP server ready", .{});
        const original_termios = try enableRawMode();
        std.log.info("Raw mode enabled", .{});
        const session_id = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
        const kb = try keybindings.loadKeybindings(allocator);
        std.log.info("Session ID: {s}", .{session_id});
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const http_client = std.http.Client{ .allocator = arena.allocator() };
        return App{
            .http_client = http_client,
            .arena = arena,
            .allocator = allocator,
            .original_termios = original_termios,
            .session_id = session_id,
            .input = std.ArrayList(u8).empty,
            .pasting = false,
            .last_esc_time = null,
            .keybindings = kb,
            .verbose = verbose,
            .state = CompletionState{
                .matches = std.ArrayList([]const u8).empty,
            },
        };
    }

    pub fn deinit(app: *App) void {
        app.keybindings.deinit();
        disableRawMode(app.original_termios);
        app.allocator.free(app.session_id);
        app.input.deinit(app.allocator);
        app.state.matches.deinit(app.allocator);
        app.http_client.deinit();
        app.arena.deinit();
    }
};

// ─── Terminal ────────────────────────────────────────────────────────────────

fn enableRawMode() !std.posix.termios {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};
}

// ─── Backend ─────────────────────────────────────────────────────────────────

fn spawnBackend(_: bool) !void {
    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, "/usr/local/bin/zigginagentic");
    defer std.heap.page_allocator.free(backend_path);

    // Check if backend is already running by trying to connect to HTTP port
    const test_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
        // If we can't create a socket, skip spawning
        return;
    };
    defer std.posix.close(test_socket);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    var already_running = false;
    std.posix.connect(test_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        already_running = true;
    };

    if (already_running) {
        std.debug.print("{s}Backend already running, skipping spawn{s}\n", .{ green, reset });
        return;
    }

    // Spawn the backend using daemon() for proper daemonization
    const c = @cImport({
        @cInclude("unistd.h");
    });

    // Convert to null-terminated C string
    const backend_path_z = try std.heap.page_allocator.dupeZ(u8, backend_path);
    defer std.heap.page_allocator.free(backend_path_z);

    // daemon(1, 0) - change to / and close stdio
    // This is the standard Unix daemon() call
    if (c.daemon(1, 0) != 0) {
        std.debug.print("{s}Warning: daemon() failed{s}\n", .{ yellow, reset });
        return;
    }

    // We're now in the daemon child - execute the backend directly
    // Use execl which is simpler than execvp
    // Cast null to proper pointer type for variadic function
    const null_ptr: [*c]const u8 = null;
    _ = c.execl(backend_path_z, backend_path_z, null_ptr);
    // If we get here, exec failed
    std.debug.print("{s}Warning: failed to exec backend{s}\n", .{ yellow, reset });
    std.posix.exit(1);
}

fn waitForHttpServer(timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return error.Timeout;
        const socket_fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        defer std.posix.close(socket_fd);
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
        if (std.posix.connect(socket_fd, &addr.any, @sizeOf(std.net.Address))) {
            return;
        } else |_| {
            std.Thread.sleep(50_000_000);
        }
    }
}

// ─── Chunked transfer encoding decoder ───────────────────────────────────────
//
// HTTP/1.1 chunked format:
//   <hex size>\r\n
//   <data>\r\n
//   0\r\n\r\n   <- end
//
// Strips HTTP headers and chunk size lines, returns raw SSE text.

fn decodeChunked(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Skip HTTP response headers if present
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n");
    var pos: usize = if (header_end) |end| end + 4 else 0;

    // Check if this looks like chunked encoding (starts with hex number)
    const maybe_chunked = pos < raw.len and
        (std.ascii.isHex(raw[pos]) or raw[pos] == '\r' or raw[pos] == '\n');

    if (maybe_chunked and header_end != null) {
        // Parse chunked encoding
        while (pos < raw.len) {
            // Find end of chunk size line
            const size_end = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse break;
            const size_str = std.mem.trim(u8, raw[pos..size_end], " \t");
            if (size_str.len == 0) {
                pos = size_end + 2;
                continue;
            }

            // Parse hex chunk size
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
                pos = size_end + 2;
                continue;
            };

            if (chunk_size == 0) break; // end of chunked stream

            pos = size_end + 2;
            if (pos + chunk_size > raw.len) break; // incomplete, wait for more data

            try out.appendSlice(allocator, raw[pos .. pos + chunk_size]);
            pos += chunk_size;

            // Skip trailing \r\n after chunk data
            if (pos + 2 <= raw.len and raw[pos] == '\r' and raw[pos + 1] == '\n') {
                pos += 2;
            }
        }
    } else {
        // No chunked encoding - just return body (or entire input if no headers)
        try out.appendSlice(allocator, raw[pos..]);
    }

    return out.toOwnedSlice(allocator);
}

// ─── SSE parser ──────────────────────────────────────────────────────────────
//
// After chunked decode, SSE lines look like:
//   data: {"event":"chunk","data":"<xml escaped>"}\n\n
//   : keepalive\n\n
//
// This extracts and unescapes the "data" JSON field value from each data: line,
// concatenating all of them into one XML string.

fn extractSseData(allocator: std.mem.Allocator, sse_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, sse_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");

        // Skip empty lines (SSE event boundaries)
        if (trimmed.len == 0) continue;

        // Skip comment lines (keepalive, etc.)
        if (std.mem.startsWith(u8, trimmed, ":")) continue;

        // Skip event type lines - we just want the data
        if (std.mem.startsWith(u8, trimmed, "event:")) continue;

        // Extract data lines
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const payload = trimmed["data:".len..];
            // Add newline separator between data lines (SSE spec)
            if (out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, payload);
        }
    }

    return out.toOwnedSlice(allocator);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

pub fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    // Use stack buffer instead of heap allocation for better performance
    var close_tag_buf: [128]u8 = undefined;
    var open_tag_buf: [128]u8 = undefined;

    const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag}) catch return null;
    const open_tag = std.fmt.bufPrint(&open_tag_buf, "<{s}>", .{tag}) catch return null;

    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    const open_pos = std.mem.lastIndexOf(u8, xml[0..close_pos], open_tag) orelse return null;
    return xml[open_pos + open_tag.len .. close_pos];
}

// ─── SSE Connection Sync ─────────────────────────────────────────────────────

/// Wait for SSE "connected" event from server
/// Returns true if connected event received, false on timeout/error
fn waitForSseConnected(socket: std.posix.fd_t, timeout_ms: u64) bool {
    var buf: [4096]u8 = undefined;
    const start = std.time.milliTimestamp();

    // Enable TCP keepalive to detect connection drops
    var enable: u32 = 1;
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return false;

        var poll_fd = [1]std.posix.pollfd{
            .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const ready = std.posix.poll(&poll_fd, 100) catch 0;
        if (ready > 0 and (poll_fd[0].revents & std.posix.POLL.IN != 0)) {
            const n = std.posix.read(socket, &buf) catch return false;
            if (n == 0) return false;
            if (std.mem.indexOf(u8, buf[0..n], "event: connected") != null) {
                return true;
            }
        }
    }
}

/// Reconnect to SSE stream for the given session
/// Returns new socket fd on success, -1 on failure
fn reconnectSseStream(app: *App, current_socket: std.posix.fd_t) std.posix.fd_t {
    // Close old socket
    std.posix.close(current_socket);

    // Create new socket
    const new_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return -1;

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    std.posix.connect(new_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Send stream request
    const stream_request = std.fmt.allocPrint(app.arena.allocator(), "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, HTTP_HOST, HTTP_PORT }) catch {
        std.posix.close(new_socket);
        return -1;
    };

    _ = std.posix.write(new_socket, stream_request) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Wait for connected event
    if (!waitForSseConnected(new_socket, 5000)) {
        std.posix.close(new_socket);
        return -1;
    }

    return new_socket;
}

// ─── Messaging ───────────────────────────────────────────────────────────────

/// Escape a string for JSON output
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return "",
            '\\' => result.appendSlice(allocator, "\\\\") catch return "",
            '\n' => result.appendSlice(allocator, "\\n") catch return "",
            '\r' => result.appendSlice(allocator, "\\r") catch return "",
            '\t' => result.appendSlice(allocator, "\\t") catch return "",
            else => result.append(allocator, c) catch return "",
        }
    }

    return allocator.dupe(u8, result.items) catch "";
}

fn sendMessage(app: *App, message: []const u8) !void {
    const cwd = std.process.getCwdAlloc(app.arena.allocator()) catch "";
    const escaped_msg = escapeJsonString(app.arena.allocator(), message);
    const escaped_cwd = escapeJsonString(app.arena.allocator(), cwd);
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"run_llm","session_id":"{s}","content":"{s}","cwd_session":"{s}"}}
    , .{ app.session_id, escaped_msg, escaped_cwd });
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ HTTP_HOST, HTTP_PORT, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

fn sendCancelCommand(app: *App) !void {
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"cancel","session_id":"{s}"}}
    , .{app.session_id});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ HTTP_HOST, HTTP_PORT, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

fn sendSessionsCommand(app: *App) !void {
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"get_sessions"}}
    , .{});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ HTTP_HOST, HTTP_PORT, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

// ─── Response formatting ─────────────────────────────────────────────────────

fn printFormattedResponse(content: []const u8) void {
    const agent_name = extractTag(content, "agent") orelse "assistant";
    std.debug.print("{s}━━ {s} ━━{s}\n", .{ cyan, agent_name, reset });
    if (extractTag(content, "markdown")) |md| {
        const trimmed = trim(md);
        if (trimmed.len > 0) {
            std.debug.print("\n{s}{s}{s}\n", .{ bold, trimmed, reset });
        } else {
            std.debug.print("\n{s}{s}{s}\n", .{ bold, content, reset });
        }
    } else {
        std.debug.print("\n{s}{s}{s}\n", .{ bold, content, reset });
    }
}

// ─── Tool Result Extraction ─────────────────────────────────────────────────

const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    result: []const u8,
};

fn extractToolResults(allocator: std.mem.Allocator, xml: []const u8) !std.ArrayList(ToolResult) {
    var results = std.ArrayList(ToolResult).empty;
    errdefer results.deinit(allocator);
    var pos: usize = 0;
    while (pos < xml.len) {
        const tool_result_start = std.mem.indexOfPos(u8, xml, pos, "<tool_result>") orelse break;
        const tool_result_end = std.mem.indexOfPos(u8, xml, tool_result_start, "</tool_result>") orelse break;
        const tool_result_block = xml[tool_result_start .. tool_result_end + "</tool_result>".len];
        pos = tool_result_end + "</tool_result>".len;
        const id = if (extractTag(tool_result_block, "tool_call_id")) |v| v else "";
        const name = if (extractTag(tool_result_block, "tool_name")) |v| v else "";
        const result = if (extractTag(tool_result_block, "result")) |v| v else "";
        if (id.len > 0) {
            try results.append(allocator, .{ .id = id, .name = name, .result = result });
        }
    }
    return results;
}

// ─── Tool display ─────────────────────────────────────────────────────────────

fn displayBashResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    const std_out = std.mem.trim(u8, extractTag(result_xml, "stdout") orelse "", &std.ascii.whitespace);
    const cmd = extractTag(result_xml, "command");
    if (std.mem.eql(u8, std_out, "")) return;
    const stderr = extractTag(result_xml, "stderr");
    const truncated = std_out.len > max_result_len;
    const display = if (truncated) std_out[0..max_result_len] else std_out;
    const is_error = if (stderr) |ec| std.mem.eql(u8, ec, "0") else false;
    const color = if (is_error) "\x1b[31m" else "";
    if (cmd) |c| {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} $ {s}\n", .{ cyan, tool_name, reset, c });
    } else {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ cyan, tool_name, reset });
    }
    var lines = std.mem.splitScalar(u8, display, '\n');
    while (lines.next()) |line| {
        std.debug.print("{s}  {s}{s}\n", .{ color, line, if (is_error) reset else "" });
    }
    if (truncated) std.debug.print("  {s}[truncated...]{s}\n", .{ cyan, reset });
}

fn displaySearchResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    _ = max_result_len;
    const results = extractTag(result_xml, "results") orelse "";
    if (std.mem.eql(u8, results, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ cyan, tool_name, reset });
    var remaining = results;
    var total_shown: usize = 0;
    while (total_shown < 20) {
        const match_start = std.mem.indexOf(u8, remaining, "<m>") orelse break;
        const match_end = std.mem.indexOf(u8, remaining, "</m>") orelse break;
        const match_block = remaining[match_start .. match_end + "</m>".len];
        remaining = remaining[match_end + "</m>".len ..];
        const file = extractTag(match_block, "f") orelse "";
        const line_num = extractTag(match_block, "l") orelse "0";
        const snippet = extractTag(match_block, "s") orelse "";
        std.debug.print("  {s}:{s}:{s}\n", .{ file, line_num, snippet });
        total_shown += 1;
    }
    if (std.mem.indexOf(u8, remaining, "<m>") != null) {
        std.debug.print("  {s}[more matches...]{s}\n", .{ cyan, reset });
    }
}

fn displayReadFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const content = extractTag(result_xml, "content") orelse "";
    const total_lines = extractTag(result_xml, "total_lines") orelse "?";
    const start_line = extractTag(result_xml, "start_line") orelse "0";
    const end_line = extractTag(result_xml, "end_line") orelse "?";
    if (std.mem.eql(u8, content, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} lines {s}-{s}/{s}\n", .{ cyan, tool_name, reset, start_line, end_line, total_lines });
    const max_lines: usize = 20;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count >= max_lines) {
            std.debug.print("  {s}[...]{s}\n", .{ cyan, reset });
            break;
        }
        std.debug.print("  {s}\n", .{line});
        count += 1;
    }
}

fn displayWriteFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = extractTag(result_xml, "path") orelse "";
    const bytes_written = extractTag(result_xml, "bytes_written") orelse "0";
    const lines_written = extractTag(result_xml, "lines_written") orelse "0";
    if (std.mem.eql(u8, path, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} wrote {s} bytes ({s} lines) → {s}\n", .{ cyan, tool_name, reset, bytes_written, lines_written, path });
    if (extractTag(result_xml, "before")) |before| {
        if (!std.mem.eql(u8, before, "")) std.debug.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", reset, before });
    }
    if (extractTag(result_xml, "after")) |after| {
        if (!std.mem.eql(u8, after, "")) std.debug.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", reset, after });
    }
}

fn displayTextReplaceResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = extractTag(result_xml, "path") orelse "";
    const replaced_at_byte = extractTag(result_xml, "replaced_at_byte") orelse "?";
    if (std.mem.eql(u8, path, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} replaced at byte {s} → {s}\n", .{ cyan, tool_name, reset, replaced_at_byte, path });
    if (extractTag(result_xml, "old_str")) |old_str| {
        if (!std.mem.eql(u8, old_str, "")) std.debug.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", reset, old_str });
    }
    if (extractTag(result_xml, "new_str")) |new_str| {
        if (!std.mem.eql(u8, new_str, "")) std.debug.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", reset, new_str });
    }
}

// ─── Double ESC ───────────────────────────────────────────────────────────────

fn checkStdinForDoubleEscape(app: *App) bool {
    const bytes_available = stdinBytesAvailable();
    if (bytes_available == 0) return false;
    var buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;
    const first_byte = buf[0];
    if (first_byte == 0x1b) {
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[200~")) {
            app.last_esc_time = null;
            return false;
        }
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[201~")) {
            app.last_esc_time = null;
            return false;
        }
        const now = std.time.milliTimestamp();
        if (app.last_esc_time) |last| {
            if (now - last < DOUBLE_ESC_WINDOW_MS) {
                app.last_esc_time = null;
                return true;
            }
        }
        app.last_esc_time = now;
        return false;
    }
    return false;
}

// ─── Response streaming ──────────────────────────────────────────────────────

fn readResponseAndStreamRunLLM(app: *App, message: []const u8) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);

    var buf: [4096]u8 = undefined;
    var spinner_timer: usize = 0;
    const spinners = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var last_tick: i64 = 0;
    var retry_count: usize = 0;
    var streaming_started = false;

    // Timeout detection for SSE reconnection
    // Keepalive is sent every 30s, so use 90s (3x) to avoid false timeouts
    const SSE_TIMEOUT_MS: i64 = 90000; // 90 seconds
    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;
    const MAX_RECONNECTION_ATTEMPTS: u32 = 100;

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    // Enable TCP keepalive to detect connection drops
    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(app.arena.allocator(), "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, HTTP_HOST, HTTP_PORT });
    _ = try std.posix.write(stream_socket, stream_request);

    if (!waitForSseConnected(stream_socket, 5000)) {
        std.debug.print("{s}Warning: SSE connection timeout{s}\n", .{ yellow, reset });
    }
    try sendMessage(app, message);

    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var stream_interrupted = false;
    var displayed_tool_ids = std.ArrayList([]const u8).empty;
    defer {
        for (displayed_tool_ids.items) |id| app.allocator.free(id);
        displayed_tool_ids.deinit(app.allocator);
    }
    var last_printed_chunk_index: usize = 0;
    var last_finish_search_pos: usize = 0;
    var raw_buffer_processed_len: usize = 0;

    while (true) {
        // Cache timestamp once per loop — avoids redundant syscalls
        const now = std.time.milliTimestamp();

        // poll() blocks up to 100ms waiting for data — this replaces busy-waiting.
        // Using a longer timeout here is the primary CPU fix: instead of polling
        // every ~10ms (50ms poll + 10ms sleep), we just let poll() do the waiting.
        const ready = std.posix.poll(&poll_fds, 100) catch 0;
        var new_data = false;

        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    sendCancelCommand(app) catch {};
                    stream_interrupted = true;
                    break;
                }
                poll_fds[1].revents = 0;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
                new_data = true;
                // Update last data received timestamp (includes keepalive events)
                last_data_received_ms = now;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        } else {
            // poll() timed out — no data arrived in the last 100ms.
            // No need for an extra Thread.sleep() here; poll() already waited.

            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    std.debug.print("\r\x1b[2K\n{s}Connection lost. Max reconnection attempts reached.{s}\n", .{ yellow, reset });
                    break;
                }

                reconnection_attempts += 1;
                std.debug.print("\r\x1b[2K\n{s}Connection lost, reconnecting... (attempt {}/{})\n{s}", .{ yellow, reconnection_attempts, MAX_RECONNECTION_ATTEMPTS, reset });

                const new_socket = reconnectSseStream(app, stream_socket);
                if (new_socket < 0) {
                    std.debug.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ yellow, reset });
                    last_data_received_ms = now;
                    // No explicit sleep needed — poll() in next iteration will wait 100ms
                    continue;
                }

                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = std.time.milliTimestamp();
                std.debug.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ green, reset });
                continue;
            }

            // Spinner — only updated when idle (no streaming yet), and only in
            // the no-data branch so it doesn't run on every data-processing iteration.
            if (!streaming_started and now - last_tick >= 100) {
                last_tick = now;
                const spin = spinners[spinner_timer % spinners.len];
                spinner_timer += 1;
                std.debug.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes)", .{
                    yellow, spin, reset, raw_buffer.items.len,
                });
            }
        }

        if (new_data) {
            const new_raw = raw_buffer.items[raw_buffer_processed_len..];
            if (new_raw.len == 0) continue;

            if (decodeChunked(app.allocator, new_raw)) |decoded| {
                defer app.allocator.free(decoded);
                raw_buffer_processed_len = raw_buffer.items.len;

                if (extractSseData(app.allocator, decoded)) |xml| {
                    defer app.allocator.free(xml);

                    var chunk_pos: usize = 0;
                    while (std.mem.indexOfPos(u8, xml, chunk_pos, "<chunk")) |chunk_start| {
                        const chunk_end = std.mem.indexOfPos(u8, xml, chunk_start, "</chunk>") orelse break;
                        const chunk_block = xml[chunk_start .. chunk_end + "</chunk>".len];
                        chunk_pos = chunk_end + "</chunk>".len;

                        var chunk_index: usize = 0;
                        if (std.mem.indexOfPos(u8, chunk_block, 0, "index=\"")) |idx_start| {
                            const idx_end = std.mem.indexOfPos(u8, chunk_block, idx_start + 7, "\"") orelse continue;
                            const idx_str = chunk_block[idx_start + 7 .. idx_end];
                            chunk_index = std.fmt.parseInt(usize, idx_str, 10) catch continue;
                        }

                        if (chunk_index >= last_printed_chunk_index) {
                            last_printed_chunk_index = chunk_index + 1;
                            if (extractTag(chunk_block, "content")) |content| {
                                if (content.len > 0) {
                                    if (!streaming_started) {
                                        std.debug.print("\r\x1b[2K", .{});
                                        streaming_started = true;
                                    }
                                    std.debug.print("{s}", .{content});
                                }
                            }
                        }
                    }

                    if (extractToolResults(app.allocator, xml)) |tool_results_val| {
                        var tool_results = tool_results_val;
                        defer tool_results.deinit(app.allocator);

                        for (tool_results.items) |result| {
                            var already_displayed = false;
                            for (displayed_tool_ids.items) |id| {
                                if (std.mem.eql(u8, id, result.id)) {
                                    already_displayed = true;
                                    break;
                                }
                            }
                            if (!already_displayed) {
                                std.debug.print("\r\x1b[2K", .{});
                                const max_result_len: usize = 500;
                                if (std.mem.eql(u8, result.name, "bash")) {
                                    displayBashResult(result.result, result.name, max_result_len);
                                } else if (std.mem.eql(u8, result.name, "search")) {
                                    displaySearchResult(result.result, result.name, max_result_len);
                                } else if (std.mem.eql(u8, result.name, "read_file")) {
                                    displayReadFileResult(result.result, result.name);
                                } else if (std.mem.eql(u8, result.name, "write_file")) {
                                    displayWriteFileResult(result.result, result.name);
                                } else if (std.mem.eql(u8, result.name, "text_replace")) {
                                    displayTextReplaceResult(result.result, result.name);
                                }
                                if (extractTag(result.result, "change_agent_tool")) |_| {
                                    const agent_name = extractTag(result.result, "agent") orelse "unknown";
                                    std.debug.print("\n{s}[agent]{s} → {s}\n", .{ cyan, reset, agent_name });
                                }
                                const id_copy = app.allocator.dupe(u8, result.id) catch continue;
                                displayed_tool_ids.append(app.allocator, id_copy) catch {
                                    app.allocator.free(id_copy);
                                    continue;
                                };
                            }
                        }
                    } else |_| {}
                } else |_| {}
            } else |_| {}

            // finish_reason — O(1) amortized
            const search_start = @min(last_finish_search_pos, raw_buffer.items.len);
            if (std.mem.indexOfPos(u8, raw_buffer.items, search_start, "</finish_reason>")) |_| {
                last_finish_search_pos = raw_buffer.items.len;
                if (extractTag(raw_buffer.items, "finish_reason")) |fr| {
                    if (std.mem.eql(u8, fr, "notification_error")) {
                        retry_count += 1;
                        continue;
                    }
                    if (std.mem.eql(u8, fr, "cancelled")) {
                        std.debug.print("\r\x1b[2K\n{s}Task cancelled{s}\n", .{ yellow, reset });
                        break;
                    }
                    if (std.mem.eql(u8, fr, "user_choice")) break;
                    if (std.mem.eql(u8, fr, "stop")) break;
                }
            }
        }
    }

    std.debug.print("\r\x1b[2K", .{});
    if (stream_interrupted) {
        std.debug.print("\n{s}Interrupted (double ESC){s}\n", .{ yellow, reset });
    }

    std.debug.print("\n{s}[DEBUG] Raw buffer size: {d}{s}\n", .{ dim, raw_buffer.items.len, reset });

    const final_decoded = decodeChunked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    std.debug.print("{s}[DEBUG] Decoded size: {d}{s}\n", .{ dim, final_decoded.len, reset });

    const final_xml = extractSseData(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);
    std.debug.print("{s}[DEBUG] XML size: {d}{s}\n", .{ dim, final_xml.len, reset });
    if (final_xml.len > 0) {
        std.debug.print("{s}[DEBUG] XML preview: {s}{s}\n", .{ dim, final_xml[0..@min(final_xml.len, 200)], reset });
    }

    if (extractTag(final_xml, "content")) |content| {
        printFormattedResponse(content);
    } else if (final_xml.len > 0) {
        if (extractTag(final_xml, "message")) |msg| {
            printFormattedResponse(msg);
        } else {
            std.debug.print("{s}\n", .{final_xml});
        }
    } else {
        std.debug.print("{s}(no response){s}\n", .{ dim, reset });
    }

    std.debug.print("\r\n", .{});
    _ = app.arena.reset(.retain_capacity);
    return try raw_buffer.toOwnedSlice(app.allocator);
}

fn readResponseAndStreamGetSessions(app: *App) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);
    var buf: [4096]u8 = undefined;

    // Timeout detection for SSE reconnection
    // Keepalive is sent every 30s, so use 90s (3x) to avoid false timeouts
    const SSE_TIMEOUT_MS: i64 = 90000; // 90 seconds
    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;
    const MAX_RECONNECTION_ATTEMPTS: u32 = 3;

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    // Enable TCP keepalive to detect connection drops
    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, HTTP_PORT);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(app.arena.allocator(), "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, HTTP_HOST, HTTP_PORT });
    _ = try std.posix.write(stream_socket, stream_request);

    // Wait for "connected" event BEFORE sending command
    if (!waitForSseConnected(stream_socket, 5000)) {
        std.debug.print("{s}Warning: SSE connection timeout{s}\n", .{ yellow, reset });
    }
    try sendSessionsCommand(app);

    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        const now = std.time.milliTimestamp();
        const ready = std.posix.poll(&poll_fds, 50) catch 0;
        var new_data = false;
        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                poll_fds[1].revents = 0;
            }
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
                new_data = true;
                // Update last data received timestamp (includes keepalive events)
                last_data_received_ms = now;
            }
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        }

        if (!new_data) {
            // No data available - check for timeout
            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                // Timeout detected - attempt reconnection
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    std.debug.print("\r\x1b[2K\n{s}Connection lost. Max reconnection attempts reached.{s}\n", .{ yellow, reset });
                    break;
                }

                reconnection_attempts += 1;
                std.debug.print("\r\x1b[2K\n{s}Connection lost, reconnecting... (attempt {}/{})\n{s}", .{ yellow, reconnection_attempts, MAX_RECONNECTION_ATTEMPTS, reset });

                const new_socket = reconnectSseStream(app, stream_socket);
                if (new_socket < 0) {
                    std.debug.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ yellow, reset });
                    last_data_received_ms = now;
                    std.Thread.sleep(1_000_000_000);
                    continue;
                }

                // Reconnection successful
                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = now;
                std.debug.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ green, reset });
                continue;
            }

            // Sleep to prevent busy-waiting
            std.Thread.sleep(10_000_000); // 10ms
            continue;
        }

        const decoded = decodeChunked(app.allocator, raw_buffer.items) catch continue;
        defer app.allocator.free(decoded);
        const xml = extractSseData(app.allocator, decoded) catch continue;

        std.debug.print("\r\nXML len={d}: {s}\r\nEND_XML\r\n", .{ xml.len, xml[0..@min(xml.len, 200)] });
        defer app.allocator.free(xml);
        if (std.mem.indexOf(u8, xml, "</finish_reason>") != null) break;
    }

    std.debug.print("\r\x1b[2K\n", .{});

    const final_decoded = decodeChunked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    const final_xml = extractSseData(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);

    if (extractTag(final_xml, "sessions")) |md| {
        const trimmed = trim(md);
        std.debug.print("{s}Session ID           Directory                        Created{s}\n", .{ bold, reset });
        std.debug.print("─────────────────────────────────────────────────────────────────────\n", .{});
        var rest = trimmed;
        while (extractTag(rest, "session")) |session| {
            const id = extractTag(session, "id") orelse "";
            const dir = extractTag(session, "dir") orelse "";
            const ts = extractTag(session, "created") orelse "";
            std.debug.print("{s:<20} {s:<32} {s}\n", .{ id, dir, ts });
            const end = std.mem.indexOf(u8, rest, "</session>") orelse break;
            rest = rest[end + "</session>".len ..];
        }
    }

    _ = app.arena.reset(.retain_capacity);
    return try raw_buffer.toOwnedSlice(app.allocator);
}

// ─── Input handling ──────────────────────────────────────────────────────────

pub const KEYBINDING = enum(u8) {
    CTRL_C = 3,
    ENTER = 13,
};

fn readEscapeSequence(buf: *[16]u8) !usize {
    buf[0] = 0x1b;
    var i: usize = 1;
    while (i < buf.len) {
        var b: [1]u8 = undefined;
        const bytes_available = stdinBytesAvailable();
        if (bytes_available == 0) break;
        const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch break;
        if (n == 0) break;
        buf[i] = b[0];
        i += 1;
        if (b[0] == '~') break;
    }
    return i;
}

fn clearCompletions(app: *App) void {
    if (app.state.last_match_count == 0) return;
    var i: usize = 0;
    while (i < app.state.last_match_count) : (i += 1) {
        std.debug.print("\x1b[1B", .{});
        std.debug.print("\x1b[2K", .{});
    }
    std.debug.print("\x1b[{}A", .{app.state.last_match_count});
    app.state.visible = false;
    app.state.last_match_count = 0;
}

fn handleCompletion(app: *App) !bool {
    const input = app.input.items;
    if (app.state.visible and app.state.matches.items.len > 0) {
        app.state.selected = (app.state.selected + 1) % app.state.matches.items.len;
        renderCompletions(app);
        return true;
    }
    app.state.matches.clearRetainingCapacity();
    app.state.selected = 0;
    if (input.len == 0 or input[0] == '/') {
        for (COMMANDS) |cmd| {
            if (std.mem.startsWith(u8, cmd, input)) {
                try app.state.matches.append(app.allocator, cmd);
            }
        }
    }
    if (app.state.matches.items.len == 0) return true;
    if (app.state.matches.items.len == 1) {
        app.input.clearRetainingCapacity();
        try app.input.appendSlice(app.allocator, app.state.matches.items[0]);
        app.state.visible = false;
        app.state.last_match_count = 0;
        std.debug.print("\r\x1b[2K{s}>{s} {s}", .{ bold, reset, app.input.items });
    } else {
        app.state.visible = true;
        renderCompletions(app);
    }
    return true;
}

fn renderCompletions(app: *App) void {
    if (app.state.last_match_count > 0) {
        var i: usize = 0;
        while (i < app.state.last_match_count) : (i += 1) {
            std.debug.print("\x1b[1B", .{});
            std.debug.print("\x1b[2K", .{});
        }
        std.debug.print("\x1b[{}A", .{app.state.last_match_count});
    }
    std.debug.print("\x1b[s", .{});
    for (app.state.matches.items, 0..) |cmd, i| {
        std.debug.print("\x1b[1E", .{});
        if (i == app.state.selected) {
            std.debug.print("  \x1b[7m {s} \x1b[0m", .{cmd});
        } else {
            std.debug.print("    {s}", .{cmd});
        }
    }
    app.state.last_match_count = app.state.matches.items.len;
    std.debug.print("\x1b[u", .{});
}

fn handleInput(app: *App) !bool {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
    if (n == 0) {
        std.Thread.sleep(10000000);
        return false;
    }
    const c = buf[0];
    if (c == @intFromEnum(KEYBINDING.CTRL_C)) return true;

    if (c == 0x1b) {
        var esc: [16]u8 = undefined;
        const len = try readEscapeSequence(&esc);
        const seq = esc[0..len];

        if (std.mem.eql(u8, seq, "\x1b[200~")) {
            app.pasting = true;
        } else if (std.mem.eql(u8, seq, "\x1b[201~")) {
            app.pasting = false;
        } else {
            // Only clear completions for non-paste escape sequences
            clearCompletions(app);
        }
        return false;
    }

    if (c == 127 or c == 8) {
        if (!app.pasting and app.input.items.len > 0) {
            _ = app.input.pop();
            std.debug.print("\x08 \x08", .{});
        }
    } else if (c == '\t') {
        if (!app.pasting) {
            _ = try handleCompletion(app);
        } else {
            // Treat tab as spaces during paste
            try app.input.append(app.allocator, ' ');
            std.debug.print(" ", .{});
        }
    } else if (c == @intFromEnum(KEYBINDING.ENTER) or c == 10) {
        if (app.pasting) {
            // During paste, newlines become spaces instead of submitting
            try app.input.append(app.allocator, ' ');
            std.debug.print(" ", .{});
            return false;
        }
        if (app.input.items.len > 0) {
            if (std.mem.eql(u8, app.input.items, "/sessions")) {
                std.debug.print("\r\n", .{});
                const response = readResponseAndStreamGetSessions(app) catch "";
                defer app.allocator.free(response);
                if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
                app.input.clearRetainingCapacity();
                std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
                return false;
            }
            if (std.mem.eql(u8, app.input.items, "/exit")) return true;
            std.debug.print("\r\n\r\n", .{});
            const response = readResponseAndStreamRunLLM(app, app.input.items) catch "";
            defer app.allocator.free(response);
            if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
            app.input.clearRetainingCapacity();
        }
        std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
    } else if (c >= 32) {
        if (!app.pasting) clearCompletions(app);
        try app.input.append(app.allocator, c);
        std.debug.print("{c}", .{c});
    }
    return false;
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_allocator = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var verbose = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("zigginagentic-tui - Terminal UI for AI agent\n\nUsage: zigginagentic-tui [options]\n\nOptions:\n  -v, --verbose    Show backend debug output\n  -h, --help       Show this help message\n", .{});
            return;
        }
    }

    var app = try App.init(allocator, verbose);
    defer app.deinit();

    std.debug.print("Type message and press Enter. Ctrl+C to exit.\r\n\r\n", .{});
    std.debug.print("\x1b[?2004h", .{});
    defer std.debug.print("\x1b[?2004l", .{});
    std.debug.print("{s}>{s} ", .{ bold, reset });

    while (true) {
        const should_exit = try handleInput(&app);
        if (should_exit) break;
    }

    std.debug.print("\r\n{s}Bye!{s}\r\n", .{ dim, reset });
}

test {
    _ = @import("main_test.zig");
}
