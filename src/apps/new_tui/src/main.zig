//! New TUI using ZigZag framework
//! A modern terminal UI for the nalarcore AI agent

const std = @import("std");
const zz = @import("zigzag");

// Re-export zigzag types for convenience
pub const Program = zz.Program;
pub const Cmd = zz.Cmd;
pub const Context = zz.Context;
pub const Style = zz.Style;
pub const Color = zz.Color;
pub const TextInput = zz.TextInput;
pub const List = zz.List;
pub const Viewport = zz.Viewport;

// Application constants
pub const HTTP_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8080;
pub const DEFAULT_PROCESS = "nalar";
const BACKEND_PATH = "/usr/local/bin/";
const MAX_MESSAGES = 100;
const MAX_MESSAGE_LEN = 4096;

// Session message entry - using fixed-size arrays to avoid allocation issues
pub const MessageEntry = struct {
    role: [16]u8,
    role_len: usize,
    content: [MAX_MESSAGE_LEN]u8,
    content_len: usize,
    timestamp: i64,

    pub fn init() MessageEntry {
        return .{
            .role = undefined,
            .role_len = 0,
            .content = undefined,
            .content_len = 0,
            .timestamp = 0,
        };
    }

    pub fn setRole(msg: *MessageEntry, role: []const u8) void {
        @memcpy(msg.role[0..role.len], role);
        msg.role_len = role.len;
    }

    pub fn setContent(msg: *MessageEntry, content: []const u8) void {
        const copy_len = @min(content.len, MAX_MESSAGE_LEN - 1);
        @memcpy(msg.content[0..copy_len], content[0..copy_len]);
        msg.content[copy_len] = 0;
        msg.content_len = copy_len;
    }

    pub fn getRole(msg: *const MessageEntry) []const u8 {
        return msg.role[0..msg.role_len];
    }

    pub fn getContent(msg: *const MessageEntry) []const u8 {
        return msg.content[0..msg.content_len];
    }
};

/// Model for our TUI application
pub const Model = struct {
    count: i32,
    messages: [MAX_MESSAGES]MessageEntry,
    message_count: usize,
    is_processing: bool,
    show_help: bool,
    debug_mode: bool,
    session_id: [64]u8,
    session_id_len: usize,
    http_port: u16,
    process_name: []const u8,
    is_connected: bool,
    verbose: bool,
    input: TextInput,
    allocator: std.mem.Allocator,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        submit: void,
        clear: void,
        ping: void,
        sessions: void,
        model_info: void,
        config_show: void,
        compact: void,
        exit: void,
    };

    pub fn init(self: *Model, ctx: *zz.Context) Cmd(Msg) {
        self.* = .{
            .count = 0,
            .messages = undefined,
            .message_count = 0,
            .is_processing = false,
            .show_help = false,
            .debug_mode = false,
            .session_id = undefined,
            .session_id_len = 0,
            .http_port = DEFAULT_PORT,
            .process_name = DEFAULT_PROCESS,
            .is_connected = false,
            .verbose = false,
            .input = TextInput.init(ctx.allocator),
            .allocator = ctx.allocator,
        };
        
        // Initialize session ID
        const sid = std.fmt.allocPrint(ctx.allocator, "session_{}", .{std.time.timestamp()}) catch "";
        @memcpy(self.session_id[0..sid.len], sid);
        self.session_id_len = sid.len;
        
        // Initialize messages array
        for (0..MAX_MESSAGES) |i| {
            self.messages[i] = MessageEntry.init();
        }
        
        self.input.setPlaceholder("Type your message...");
        self.input.setPrompt("> ");
        return .none;
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                // Handle Enter key for submit
                if (k.key == .enter) {
                    const text = self.input.getValue();
                    if (text.len > 0 and self.message_count < MAX_MESSAGES) {
                        // Add message to history
                        self.messages[self.message_count].setRole("user");
                        self.messages[self.message_count].setContent(text);
                        self.messages[self.message_count].timestamp = std.time.timestamp();
                        self.message_count += 1;
                        self.input.setValue("") catch {};
                    }
                    return .none;
                }
                // Handle Tab for autocomplete
                if (k.key == .tab) {
                    return .none;
                }
                // Pass all other keys to the text input
                self.input.handleKey(k);
            },
            .clear => {
                self.message_count = 0;
            },
            .exit => return .quit,
            else => {},
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        // Title style
        var title_style = zz.Style{};
        title_style = title_style.bold(true);
        title_style = title_style.fg(zz.Color.cyan());
        title_style = title_style.inline_style(true);

        // Border style for messages
        var msg_box_style = zz.Style{};
        msg_box_style = msg_box_style.borderAll(zz.Border.rounded);
        msg_box_style = msg_box_style.borderForeground(zz.Color.magenta());
        msg_box_style = msg_box_style.paddingAll(1);

        // Connection status style
        var status_style = zz.Style{};
        status_style = status_style.inline_style(true);
        const status_color: zz.Color = if (self.is_connected) zz.Color.green() else zz.Color.red();
        status_style = status_style.fg(status_color);

        const status_text = if (self.is_connected) "Connected" else "Disconnected";
        const status = status_style.render(ctx.allocator, status_text) catch status_text;

        // Build header
        const title = title_style.render(ctx.allocator, "Nalar ZigZag TUI") catch "Nalar TUI";
        const port_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{self.http_port}) catch "8080";
        const session = self.session_id[0..self.session_id_len];

        const header = std.fmt.allocPrint(
            ctx.allocator,
            "{s}\nSession: {s}  Port: {s}  Status: {s}",
            .{ title, session, port_str, status },
        ) catch "Error";

        // Build messages section
        var messages_text = std.ArrayList(u8).empty;
        defer messages_text.deinit(ctx.allocator);
        const msg_writer = messages_text.writer(ctx.allocator);

        if (self.message_count == 0) {
            msg_writer.print("No messages yet...\n", .{}) catch {};
        } else {
            for (0..self.message_count) |i| {
                const m = &self.messages[i];
                msg_writer.print("[{s}] {s}\n", .{ m.getRole(), m.getContent() }) catch {};
            }
        }

        const messages_rendered = msg_box_style.render(ctx.allocator, messages_text.items) catch messages_text.items;

        // Build input section
        var input_style = zz.Style{};
        input_style = input_style.borderAll(zz.Border.rounded);
        input_style = input_style.borderForeground(zz.Color.cyan());
        input_style = input_style.paddingLeft(1);
        input_style = input_style.paddingRight(1);

        const input_text = self.input.view(ctx.allocator) catch "";
        const input_rendered = input_style.render(ctx.allocator, input_text) catch input_text;

        // Help text
        var help_style = zz.Style{};
        help_style = help_style.fg(zz.Color.gray(12));
        help_style = help_style.inline_style(true);
        const help = help_style.render(
            ctx.allocator,
            "Enter: Send  |  h: Help  |  c: Clear  |  q: Quit",
        ) catch "";

        // Process indicator
        const process_text = if (self.is_processing) blk: {
            var proc_style = zz.Style{};
            proc_style = proc_style.fg(zz.Color.yellow());
            proc_style = proc_style.bold(true);
            break :blk proc_style.render(ctx.allocator, "[Processing...]") catch "";
        } else "";

        // Combine all parts
        const final_str = std.fmt.allocPrint(
            ctx.allocator,
            "{s}\n\n{s}\n\n{s}\n{s}\n\n{s}",
            .{ header, messages_rendered, input_rendered, process_text, help },
        ) catch "Error";

        // Center in terminal
        return zz.place.place(
            ctx.allocator,
            ctx.width,
            ctx.height,
            .center,
            .top,
            final_str,
        ) catch final_str;
    }
};

/// Spawn the backend server as a daemon process
pub fn spawnBackend(verbose: bool, port: u16, process_name: []const u8) !void {
    const backend_path_str = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ BACKEND_PATH, process_name });
    defer std.heap.page_allocator.free(backend_path_str);
    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, backend_path_str);
    defer std.heap.page_allocator.free(backend_path);

    // Check if backend is already running
    const test_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
        return;
    };
    defer std.posix.close(test_socket);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    std.posix.connect(test_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        // Connection failed = not running, we should spawn
        if (verbose) std.debug.print("Spawning backend on port {d}\n", .{port});
        
        const c = @cImport({
            @cInclude("unistd.h");
            @cInclude("sys/wait.h");
        });

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid > 0) {
            _ = c.usleep(500_000);
            return;
        }

        // Child - daemonize
        const backend_path_z = try std.heap.page_allocator.dupeZ(u8, backend_path);
        defer std.heap.page_allocator.free(backend_path_z);

        if (c.daemon(1, 0) != 0) return error.DaemonFailed;

        const port_arg = "--port";
        var port_num_buf: [6]u8 = .{0} ** 6;
        const port_num_sentinel = std.fmt.bufPrintZ(&port_num_buf, "{}", .{port}) catch unreachable;
        const port_num_ptr: [*c]const u8 = @ptrCast(port_num_sentinel);

        const null_ptr: [*c]const u8 = null;
        _ = c.execl(backend_path_z, backend_path_z, port_arg, port_num_ptr, null_ptr);
        return error.ExecFailed;
    };
    // connected successfully = already running
    return;
}

/// Wait for the HTTP server to become available
pub fn waitForHttpServer(timeout_ms: u64, port: u16) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return error.Timeout;
        const socket_fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        defer std.posix.close(socket_fd);
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        std.posix.connect(socket_fd, &addr.any, @sizeOf(std.net.Address)) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        return;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Try to spawn backend (optional)
    spawnBackend(false, DEFAULT_PORT, DEFAULT_PROCESS) catch {};

    var program = try zz.Program(Model).init(gpa.allocator());
    defer program.deinit();
    try program.run();
}
