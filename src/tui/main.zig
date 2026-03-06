const std = @import("std");
const builtin = @import("builtin");
const keybindings = @import("keybindings.zig");

const SOCKET_PATH = "/tmp/agent.sock";

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const green = "\x1b[32m";

const sockaddr_un = if (builtin.os.tag != .windows)
    extern struct { sun_family: c_ushort, sun_path: [108]u8 }
else
    void;

// Double ESC detection window in milliseconds
const DOUBLE_ESC_WINDOW_MS: i64 = 500;

// ─── Platform-specific stdin bytes available check ─────────────────────────────

/// Check how many bytes are available to read from stdin without blocking.
/// Returns 0 on Windows or if the operation is not supported.
fn stdinBytesAvailable() c_int {
    if (builtin.os.tag == .windows) {
        // On Windows, we would need to use PeekConsoleInput or similar.
        // For now, return 0 to indicate no data available (non-blocking behavior).
        // This effectively disables double-ESC detection on Windows.
        return 0;
    } else {
        // Linux and macOS support FIONREAD via ioctl
        var bytes_available: c_int = 0;
        const result = std.posix.system.ioctl(std.posix.STDIN_FILENO, std.posix.system.T.FIONREAD, @intFromPtr(&bytes_available));
        return if (result == 0) bytes_available else 0;
    }
}

// ─── App struct ──────────────────────────────────────────────────────────────
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
    // add more commands here
};

const App = struct {
    // connection
    socket_fd: std.posix.fd_t,

    // terminal
    original_termios: std.posix.termios,

    // session
    session_id: []u8,
    allocator: std.mem.Allocator,

    // input
    input: std.ArrayList(u8),
    pasting: bool,

    // double ESC detection
    last_esc_time: ?i64 = null,

    // agent name buffer (fixed size to avoid memory issues)
    agent_name_buf: [64]u8 = [_]u8{0} ** 64,

    // runtime-configurable keybindings
    keybindings: keybindings.Keybindings,

    // verbose mode for backend debug output
    verbose: bool = false,

    state: CompletionState = CompletionState{ .matches = .empty },

    pub fn init(allocator: std.mem.Allocator, verbose: bool) !App {
        try spawnBackend(verbose);
        try waitForSocket(10000);

        const socket_fd = try connectToSocket();
        const original_termios = try enableRawMode();
        const session_id = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
        const kb = try keybindings.loadKeybindings(allocator);

        return App{
            .socket_fd = socket_fd,
            .original_termios = original_termios,
            .session_id = session_id,
            .allocator = allocator,
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
        std.posix.close(app.socket_fd);
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

// ─── Backend / Socket ────────────────────────────────────────────────────────
fn spawnBackend(verbose: bool) !void {
    // Remove stale socket file if it exists but nothing is listening
    if (std.fs.accessAbsolute(SOCKET_PATH, .{})) |_| {
        // Try connecting — if it works, backend is alive, skip spawn
        const test_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch null;
        if (test_fd) |fd| {
            defer std.posix.close(fd);
            var addr = std.mem.zeroInit(sockaddr_un, .{});
            addr.sun_family = std.posix.AF.UNIX;
            @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
            if (std.posix.connect(fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un))) {
                return; // already running
            } else |_| {}
        }
        // Stale socket — remove it
        std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};
    } else |_| {}

    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, "/usr/local/bin/zigginagentic");
    defer std.heap.page_allocator.free(backend_path);
    var child = std.process.Child.init(&.{backend_path}, std.heap.page_allocator);

    // Redirect stdout and stderr to /dev/null to prevent backend debug output
    // from interfering with the TUI display (unless --verbose is set)
    if (!verbose) {
        child.stdout_behavior = .Close;
        child.stderr_behavior = .Close;
    }
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;

    child.spawn() catch |err| {
        std.debug.print("{s}Warning: failed to spawn backend: {s}{s}\n", .{ yellow, @errorName(err), reset });
        return;
    };
    std.debug.print("{s}Backend started in background{s}\n", .{ green, reset });
}
fn waitForSocket(timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) {
            return error.Timeout;
        }
        const socket_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        defer std.posix.close(socket_fd);
        var addr = std.mem.zeroInit(sockaddr_un, .{});
        addr.sun_family = std.posix.AF.UNIX;
        @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
        if (std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un))) {
            return; // connected!
        } else |_| {
            std.Thread.sleep(50_000_000); // 50ms
        }
    }
}

fn connectToSocket() !std.posix.fd_t {
    const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(socket_fd);
    var addr = std.mem.zeroInit(sockaddr_un, .{});
    addr.sun_family = std.posix.AF.UNIX;
    @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
    try std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un));
    return socket_fd;
}

// ─── XML helpers ─────────────────────────────────────────────────────────────

fn escapeXmlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try result.appendSlice(allocator, "&amp;"),
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

// ─── Messaging ───────────────────────────────────────────────────────────────

fn sendMessage(app: *App, message: []const u8) !void {
    var xml_buf = std.ArrayList(u8).empty;
    defer xml_buf.deinit(app.allocator);

    const cwd = std.process.getCwdAlloc(app.allocator) catch "";
    defer app.allocator.free(cwd);

    const escaped_message = try escapeXmlString(app.allocator, message);
    defer app.allocator.free(escaped_message);
    const escaped_session_id = try escapeXmlString(app.allocator, app.session_id);
    defer app.allocator.free(escaped_session_id);
    const escaped_cwd = try escapeXmlString(app.allocator, cwd);
    defer app.allocator.free(escaped_cwd);

    try xml_buf.writer(app.allocator).print(
        "<message><app_type>tui</app_type><command_type>run_llm</command_type><session_id>{s}</session_id><content>{s}</content><cwd_session>{s}</cwd_session></message>",
        .{ escaped_session_id, escaped_message, escaped_cwd },
    );
    _ = try std.posix.write(app.socket_fd, xml_buf.items);
}

fn sendSessionsCommand(app: *App) !void {
    var xml_buf = std.ArrayList(u8).empty;
    defer xml_buf.deinit(app.allocator);

    try xml_buf.writer(app.allocator).print(
        "<message><app_type>tui</app_type><command_type>get_sessions</command_type></message>",
        .{},
    );
    _ = try std.posix.write(app.socket_fd, xml_buf.items);
}

// ─── Response formatting ─────────────────────────────────────────────────────

fn printFormattedResponse(content: []const u8) void {
    const agent_name = extractTag(content, "agent") orelse "unknown";
    std.debug.print("{s}━━ {s} ━━{s}\n", .{ cyan, agent_name, reset });

    if (extractTag(content, "markdown")) |md| {
        const trimmed = trim(md);
        if (trimmed.len > 0) {
            std.debug.print("\n{s}{s}{s}\n", .{ bold, trimmed, reset });
        } else {
            // Empty markdown tag - print raw content as fallback
            std.debug.print("\n{s}{s}{s}\n", .{ bold, content, reset });
        }
    } else {
        // No markdown tag found - print content directly as fallback
        std.debug.print("\n{s}{s}{s}\n", .{ bold, content, reset });
    }

    // printAllTags(content, &.{ "agent", "markdown" }, 0);
}

fn isNestedElsewhere(xml: []const u8, tag: []const u8, tag_content: []const u8) bool {
    const tag_content_ptr = @intFromPtr(tag_content.ptr);
    var pos: usize = 0;
    while (pos < xml.len) {
        const open_start = std.mem.indexOfPos(u8, xml, pos, "<") orelse break;
        const open_end = std.mem.indexOfPos(u8, xml, open_start + 1, ">") orelse break;
        const other_tag = xml[open_start + 1 .. open_end];
        pos = open_end + 1;

        if (other_tag.len == 0 or other_tag[0] == '/' or std.mem.indexOfScalar(u8, other_tag, ' ') != null) continue;
        if (std.mem.eql(u8, other_tag, tag)) continue;

        const other_content = extractTag(xml, other_tag) orelse continue;
        const other_ptr = @intFromPtr(other_content.ptr);
        const other_end = other_ptr + other_content.len;

        if (tag_content_ptr >= other_ptr and tag_content_ptr + tag_content.len <= other_end) {
            return true;
        }
    }
    return false;
}

fn printAllTags(content: []const u8, skip: []const []const u8, depth: usize) void {
    var pos: usize = 0;
    var printed_buf: [64][]const u8 = undefined;
    var printed_len: usize = 0;

    while (pos < content.len) {
        const open_start = std.mem.indexOfPos(u8, content, pos, "<") orelse break;
        const open_end = std.mem.indexOfPos(u8, content, open_start + 1, ">") orelse break;
        const tag = content[open_start + 1 .. open_end];
        pos = open_end + 1;

        if (tag.len == 0 or tag[0] == '/' or std.mem.indexOfScalar(u8, tag, ' ') != null) continue;

        const should_skip = for (skip) |s| {
            if (std.mem.eql(u8, s, tag)) break true;
        } else false;
        if (should_skip) continue;

        const already_printed = for (printed_buf[0..printed_len]) |p| {
            if (std.mem.eql(u8, p, tag)) break true;
        } else false;
        if (already_printed) continue;

        const tag_content = extractTag(content, tag) orelse continue;

        if (isNestedElsewhere(content, tag, tag_content)) continue;

        if (printed_len < printed_buf.len) {
            printed_buf[printed_len] = tag;
            printed_len += 1;
        }

        printTagBox(tag, tag_content, depth);
    }
}

fn printTagBox(tag: []const u8, content: []const u8, depth: usize) void {
    const colors = [_][]const u8{ cyan, green, yellow, dim };
    var hash: usize = 0;
    for (tag) |c| hash = hash *% 31 +% c;
    const color = colors[hash % colors.len];

    const indent_base = "                "; // 16 spaces
    const indent_str = indent_base[0..@min(depth * 2, indent_base.len)];

    var label_buf: [64]u8 = undefined;
    const label = blk: {
        const n = @min(tag.len, label_buf.len);
        @memcpy(label_buf[0..n], tag[0..n]);
        if (label_buf[0] >= 'a' and label_buf[0] <= 'z') label_buf[0] -= 32;
        for (label_buf[0..n]) |*c| if (c.* == '_') {
            c.* = ' ';
        };
        break :blk label_buf[0..n];
    };

    var border_buf: [256]u8 = undefined;
    var border_len: usize = 0;
    const dash = "─";
    const dash_count = label.len + 4;
    for (0..dash_count) |_| {
        if (border_len + dash.len <= border_buf.len) {
            @memcpy(border_buf[border_len..][0..dash.len], dash);
            border_len += dash.len;
        }
    }
    const border = border_buf[0..border_len];

    const trimmed = trim(content);
    const has_children = std.mem.indexOf(u8, trimmed, "<") != null;

    std.debug.print("{s}{s}┌─ {s} ─{s}\n", .{ indent_str, color, label, reset });

    if (has_children) {
        printAllTags(content, &.{}, depth + 1);
    } else if (trimmed.len > 0) {
        std.debug.print("{s}{s}│{s} {s}\n", .{ indent_str, color, reset, trimmed });
    }

    std.debug.print("{s}{s}└{s}{s}\n", .{ indent_str, color, border, reset });
}

pub fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close_tag);
    const open_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open_tag);

    // For <content>, find it inside the final <message> block (not streaming chunks)
    // Streaming chunks have: <response><chunk><content>...</content></chunk></response>
    // Final response has: <response><choices><choice><message><content>...</content></message>...
    if (std.mem.eql(u8, tag, "content")) {
        // Find <message> tag first
        if (std.mem.lastIndexOf(u8, xml, "</message>")) |msg_end| {
            if (std.mem.lastIndexOf(u8, xml[0..msg_end], "<message>")) |msg_start| {
                const message_content = xml[msg_start .. msg_end + "</message>".len];
                // Now find <content> inside this message block
                if (std.mem.indexOf(u8, message_content, open_tag)) |open_pos| {
                    const content_start = open_pos + open_tag.len;
                    if (std.mem.indexOf(u8, message_content[content_start..], close_tag)) |close_offset| {
                        return message_content[content_start .. content_start + close_offset];
                    }
                }
            }
        }
        return null;
    }

    // Default: find last complete tag pair
    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    const open_pos = std.mem.lastIndexOf(u8, xml[0..close_pos], open_tag) orelse return null;
    return xml[open_pos + open_tag.len .. close_pos];
}

// ─── Tool Result Extraction ─────────────────────────────────────────────────

/// Struct to hold extracted tool result data
const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    result: []const u8,
};

/// Extract all tool_result blocks from XML buffer
/// Returns an ArrayList of ToolResult structs (caller owns the memory)
fn extractToolResults(allocator: std.mem.Allocator, xml: []const u8) !std.ArrayList(ToolResult) {
    var results = std.ArrayList(ToolResult).empty;
    errdefer results.deinit(allocator);

    var pos: usize = 0;
    while (pos < xml.len) {
        // Find next <tool_result> tag
        const tool_result_start = std.mem.indexOfPos(u8, xml, pos, "<tool_result>") orelse break;
        const tool_result_end = std.mem.indexOfPos(u8, xml, tool_result_start, "</tool_result>") orelse break;

        const tool_result_block = xml[tool_result_start .. tool_result_end + "</tool_result>".len];
        pos = tool_result_end + "</tool_result>".len;

        // Extract tool_call_id
        const id = if (extractTag(tool_result_block, "tool_call_id")) |v| v else "";

        // Extract tool_name
        const name = if (extractTag(tool_result_block, "tool_name")) |v| v else "";

        // Extract result
        const result = if (extractTag(tool_result_block, "result")) |v| v else "";

        if (id.len > 0) {
            try results.append(allocator, .{
                .id = id,
                .name = name,
                .result = result,
            });
        }
    }

    return results;
}

// ─── Response streaming ──────────────────────────────────────────────────────

/// Check stdin for ESC key and detect double ESC within time window
/// Returns true if double ESC detected (stream should be interrupted)
fn checkStdinForDoubleEscape(app: *App) bool {
    // Use platform-agnostic stdin bytes available check
    const bytes_available = stdinBytesAvailable();

    if (bytes_available == 0) return false;

    // Read the byte(s) available
    var buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;

    // Check if it's an escape sequence or standalone ESC
    const first_byte = buf[0];

    // If it's ESC (0x1b), check for double ESC
    if (first_byte == 0x1b) {
        // Check if this is a bracketed paste sequence
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[200~")) {
            // Start of bracketed paste - reset ESC tracking
            app.last_esc_time = null;
            return false;
        }
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[201~")) {
            // End of bracketed paste - reset ESC tracking
            app.last_esc_time = null;
            return false;
        }

        // Standalone ESC - check for double press
        const now = std.time.milliTimestamp();
        if (app.last_esc_time) |last| {
            if (now - last < DOUBLE_ESC_WINDOW_MS) {
                // Double ESC detected!
                app.last_esc_time = null;
                return true;
            }
        }
        // Record this ESC press
        app.last_esc_time = now;
        return false;
    }

    return false;
}

fn readResponseAndStreamRunLLM(app: *App) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(app.allocator);
    var buf: [4096]u8 = undefined;
    var spinner_timer: usize = 0;
    const spinners = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var last_tick = std.time.milliTimestamp();
    // var last_displayed_len: usize = 0; // track what we've already printed

    var retry_count: usize = 0;

    // Set up poll for both socket and stdin
    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = app.socket_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var stream_interrupted = false;
    var thought: []const u8 = "";
    var displayed_tool_ids = std.ArrayList([]const u8).empty;
    defer {
        for (displayed_tool_ids.items) |id| app.allocator.free(id);
        displayed_tool_ids.deinit(app.allocator);
    }

    // std.debug.print("Your sessions {s}\r\n\n", .{app.session_id});

    while (true) {
        const ready = std.posix.poll(&poll_fds, 50) catch 0;

        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    stream_interrupted = true;
                    std.debug.print("stream interrupted\n", .{});
                    break;
                }
                poll_fds[1].revents = 0;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(app.socket_fd, &buf) catch break;
                if (n == 0) {
                    break;
                }
                try buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                std.debug.print("socket error\n", .{});
                break;
            }
        }

        const now = std.time.milliTimestamp();
        if (now - last_tick >= 100) {
            last_tick = now;
            const spin = spinners[spinner_timer % spinners.len];
            spinner_timer += 1;

            if (extractTag(buffer.items, "content")) |raw_content| {
                var clean: [100]u8 = undefined;
                var len: usize = 0;
                for (raw_content) |ch| {
                    if (len >= clean.len - 1) break;
                    clean[len] = if (ch == '\n' or ch == '\r') ' ' else ch;
                    len += 1;
                }
                const fr = clean[0..len];
                const max_len: usize = 6;
                thought = if (fr.len > max_len)
                    try std.fmt.allocPrint(app.allocator, "{s}...", .{fr[0..max_len]})
                else
                    fr;
            }

            var tool_results = extractToolResults(app.allocator, buffer.items) catch continue;
            defer tool_results.deinit(app.allocator);

            for (tool_results.items) |result| {
                var already_displayed = false;
                for (displayed_tool_ids.items) |id| {
                    if (std.mem.eql(u8, id, result.id)) {
                        already_displayed = true;
                    }
                }

                if (!already_displayed) {
                    const max_result_len: usize = 500;
                    const std_out = std.mem.trim(u8, extractTag(result.result, "stdout") orelse "", &std.ascii.whitespace);
                    const cmd = extractTag(result.result, "command");
                    const change_agent_tool = extractTag(result.result, "change_agent_tool");

                    if (std.mem.eql(u8, std_out, "") == false) {
                        const stderr = extractTag(result.result, "stderr");
                        const truncated = std_out.len > max_result_len;
                        const display = if (truncated) std_out[0..max_result_len] else std_out;
                        const is_error = if (stderr) |ec| std.mem.eql(u8, ec, "0") else false;
                        const color = if (is_error) "\x1b[31m" else "";
                        if (cmd) |c| {
                            std.debug.print("\r\x1b[2K\n{s}[{s}]{s} $ {s}\n", .{ cyan, result.name, reset, c });
                        } else {
                            std.debug.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ cyan, result.name, reset });
                        }

                        // indent each line
                        var lines = std.mem.splitScalar(u8, display, '\n');
                        while (lines.next()) |line| {
                            std.debug.print("{s}  {s}{s}\n", .{ color, line, if (is_error) reset else "" });
                        }
                        if (truncated) std.debug.print("  {s}[truncated...]{s}\n", .{ cyan, reset });
                    }

                    if (change_agent_tool) |_| {
                        const agent_name = extractTag(result.result, "agent") orelse "unknown";
                        std.debug.print("\r\x1b[2K\n{s}[agent]{s} → {s}\n", .{ cyan, reset, agent_name });
                    }

                    const id_copy = app.allocator.dupe(u8, result.id) catch continue;
                    displayed_tool_ids.append(app.allocator, id_copy) catch {
                        app.allocator.free(id_copy);
                        continue;
                    };
                }
            }

            std.debug.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes) Retry count: {d} thought: {s}", .{ yellow, spin, reset, buffer.items.len, retry_count, thought });
        }

        if (std.mem.indexOf(u8, buffer.items, "</finish_reason>") == null) continue;

        if (extractTag(buffer.items, "finish_reason")) |fr| {
            if (std.mem.eql(u8, fr, "user_choice")) {
                std.debug.print("\n Your input \n", .{});
                break;
            }

            if (std.mem.eql(u8, fr, "notification_error")) {
                retry_count += 1;
            }
        }
    }

    // Clear spinner and print clean response
    std.debug.print("\r\x1b[2K", .{});

    if (stream_interrupted) {
        std.debug.print("\n{s}Stream interrupted by user (double ESC){s}\n", .{ yellow, reset });
    } else {
        std.debug.print("\n", .{});
    }

    // Extract and display the valuable content
    if (extractTag(buffer.items, "content")) |content| {
        printFormattedResponse(content);
    } else {
        // Fallback: just print the raw buffer
        std.debug.print("{s}", .{buffer.items});
    }

    std.debug.print("\r\n", .{});
    return try buffer.toOwnedSlice(app.allocator);
}

fn readResponseAndStreamGetSessions(app: *App) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(app.allocator);
    var buf: [4096]u8 = undefined;

    // Set up poll for both socket and stdin
    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = app.socket_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var stream_interrupted = false;

    while (true) {
        // Poll with 50ms timeout to allow checking for ESC
        const ready = std.posix.poll(&poll_fds, 50) catch 0;

        if (ready > 0) {
            // Check stdin first for double ESC
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    stream_interrupted = true;
                    break;
                }
                poll_fds[1].revents = 0;
            }

            // Then check socket for data
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(app.socket_fd, &buf) catch break;
                if (n == 0) break;
                try buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
            }

            // Check for socket hangup or error
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                break;
            }
        }

        if (std.mem.indexOf(u8, buffer.items, "</finish_reason>") == null) continue;

        if (extractTag(buffer.items, "finish_reason")) |fr| {
            if (std.mem.eql(u8, fr, "user_choice")) {
                std.debug.print("\n Your input \n", .{});
                break;
            }
        }
    }

    // Clear spinner and print clean response
    std.debug.print("\r\x1b[2K", .{});

    if (stream_interrupted) {
        std.debug.print("\n{s}Stream interrupted by user (double ESC){s}\n", .{ yellow, reset });
    } else {
        std.debug.print("\n", .{});
    }

    // // Extract and display the valuable content
    // if (extractTag(buffer.items, "content")) |content| {
    //     printFormattedResponse(content);
    // } else {
    //     // Fallback: just print the raw buffer
    //     std.debug.print("{s}", .{buffer.items});
    // }

    if (extractTag(buffer.items, "sessions")) |md| {
        const trimmed = trim(md);
        std.debug.print("> /sessions\n Your input\n\n", .{});
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

    // printAllTags(content, &.{ "agent", "markdown" }, 0);
    //
    // std.debug.print("\r\n", .{});
    return try buffer.toOwnedSlice(app.allocator);
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

    // Move down to the first completion line, clear each line
    var i: usize = 0;
    while (i < app.state.last_match_count) : (i += 1) {
        std.debug.print("\x1b[1B", .{}); // move down one line
        std.debug.print("\x1b[2K", .{}); // clear the line
    }

    // Move back up to original position
    std.debug.print("\x1b[{}A", .{app.state.last_match_count});

    // Reset state
    app.state.visible = false;
    app.state.last_match_count = 0;
}

fn handleCompletion(app: *App) !bool {
    const input = app.input.items;

    // If completions are visible, cycle through matches
    if (app.state.visible and app.state.matches.items.len > 0) {
        app.state.selected = (app.state.selected + 1) % app.state.matches.items.len;
        renderCompletions(app);
        return true;
    }

    // Clear any previous matches
    app.state.matches.clearRetainingCapacity();
    app.state.selected = 0;

    // Only complete if input is empty or starts with '/'
    if (input.len == 0 or input[0] == '/') {
        for (COMMANDS) |cmd| {
            if (std.mem.startsWith(u8, cmd, input)) {
                try app.state.matches.append(app.allocator, cmd);
            }
        }
    }

    if (app.state.matches.items.len == 0) {
        // No matches, nothing to do
        return true;
    }

    if (app.state.matches.items.len == 1) {
        // Single match — auto-complete immediately
        app.input.clearRetainingCapacity();
        try app.input.appendSlice(app.allocator, app.state.matches.items[0]);
        app.state.visible = false;
        app.state.last_match_count = 0;
        std.debug.print("\r\x1b[2K{s}>{s} {s}", .{ bold, reset, app.input.items });
    } else {
        // Multiple matches — display them
        app.state.visible = true;
        renderCompletions(app);
    }

    return true;
}

fn renderCompletions(app: *App) void {
    // Clear any previous completions first
    if (app.state.last_match_count > 0) {
        var i: usize = 0;
        while (i < app.state.last_match_count) : (i += 1) {
            std.debug.print("\x1b[1B", .{}); // move down one line
            std.debug.print("\x1b[2K", .{}); // clear the line
        }
        std.debug.print("\x1b[{}A", .{app.state.last_match_count}); // move back up
    }

    // Save cursor position
    std.debug.print("\x1b[s", .{});

    // Print completions below the prompt
    for (app.state.matches.items, 0..) |cmd, i| {
        std.debug.print("\x1b[1E", .{}); // move to beginning of next line
        if (i == app.state.selected) {
            // Highlighted row
            std.debug.print("  \x1b[7m {s} \x1b[0m", .{cmd});
        } else {
            std.debug.print("    {s}", .{cmd});
        }
    }

    // Track how many lines we printed
    app.state.last_match_count = app.state.matches.items.len;

    // Restore cursor position
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

    if (c == @intFromEnum(KEYBINDING.CTRL_C)) return true; // signal exit

    if (c == 0x1b) {
        clearCompletions(app);
        var esc: [16]u8 = undefined;
        const len = try readEscapeSequence(&esc);
        const seq = esc[0..len];
        if (std.mem.eql(u8, seq, "\x1b[200~")) app.pasting = true else if (std.mem.eql(u8, seq, "\x1b[201~")) app.pasting = false;
        return false;
    }

    if (c == 127 or c == 8) {
        if (!app.pasting and app.input.items.len > 0) {
            _ = app.input.pop();
            std.debug.print("\x08 \x08", .{});
        }
    } else if (c == '\t') {
        _ = try handleCompletion(app);
    } else if (c == @intFromEnum(KEYBINDING.ENTER) or c == 10) {
        // const arena_allocator = std.heap.ArenaAllocator.init(app.allocator);
        // defer arena_allocator.deinit();
        if (app.pasting) {
            try app.input.append(app.allocator, '\n');
            std.debug.print("\r\n", .{});
        } else {
            if (app.input.items.len > 0) {
                // Check for /sessions command
                if (std.mem.eql(u8, app.input.items, "/sessions")) {
                    std.debug.print("\r\n", .{});
                    try sendSessionsCommand(app);
                    const response = readResponseAndStreamGetSessions(app) catch "";
                    if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
                    app.input.clearRetainingCapacity();
                    std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
                    return false;
                }

                if (std.mem.eql(u8, app.input.items, "/exit")) {
                    return true;
                }

                std.debug.print("\r\n\r\n", .{});
                try sendMessage(app, app.input.items);
                const response = readResponseAndStreamRunLLM(app) catch "";
                if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
                app.input.clearRetainingCapacity();
            }
            std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
        }
    } else if (c >= 32) {
        clearCompletions(app);
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

    // Parse command-line arguments for --verbose
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var verbose = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("zigginagentic-tui - Terminal UI for AI agent\n\n", .{});
            std.debug.print("Usage: zigginagentic-tui [options]\n\n", .{});
            std.debug.print("Options:\n", .{});
            std.debug.print("  -v, --verbose    Show backend debug output\n", .{});
            std.debug.print("  -h, --help       Show this help message\n", .{});
            return;
        }
    }

    var app = try App.init(allocator, verbose);
    defer app.deinit();

    // std.debug.print("{s}Connected!{s}\r\n", .{ green, reset });
    std.debug.print("Type message and press Enter. Ctrl+C to exit.\r\n\r\n", .{});

    std.debug.print("\x1b[?2004h", .{}); // enable bracketed paste
    defer std.debug.print("\x1b[?2004l", .{});

    std.debug.print("{s}>{s} ", .{ bold, reset });

    while (true) {
        const should_exit = try handleInput(&app);
        if (should_exit) break;
    }

    std.debug.print("\r\n{s}Bye!{s}\r\n", .{ dim, reset });
}
