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
            .role = [_]u8{0} ** 16,
            .role_len = 0,
            .content = [_]u8{0} ** MAX_MESSAGE_LEN,
            .content_len = 0,
            .timestamp = 0,
        };
    }

    pub fn setRole(msg: *MessageEntry, role: []const u8) void {
        const copy_len = @min(role.len, 15);
        @memcpy(msg.role[0..copy_len], role[0..copy_len]);
        msg.role[copy_len] = 0;
        msg.role_len = copy_len;
    }

    pub fn setContent(msg: *MessageEntry, content: []const u8) void {
        // Zero the buffer first to avoid garbage
        @memset(&msg.content, 0);
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
                switch (k.key) {
                    .enter => {
                        // TextInput doesn't handle Enter, so we handle it here
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
                    },
                    .char => |_| {
                        // Handle regular character input
                        self.input.handleKey(k);
                    },
                    .paste => |text| {
                        // Handle paste events (piped input)
                        for (text) |c| {
                            if (c != '\n' and c != '\r') {
                                self.input.handleKey(.{ .modifiers = .{}, .key = .{ .char = c } });
                            }
                        }
                    },
                    else => {
                        // Pass other keys (backspace, arrows, etc.) to the text input
                        self.input.handleKey(k);
                    },
                }
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
        // Build styles
        var title_style = zz.Style{};
        title_style = title_style.bold(true);
        title_style = title_style.fg(zz.Color.cyan());
        title_style = title_style.inline_style(true);

        var dim_style = zz.Style{};
        dim_style = dim_style.dim(true);
        dim_style = dim_style.fg(zz.Color.gray(8));
        dim_style = dim_style.inline_style(true);

        var help_style = zz.Style{};
        help_style = help_style.fg(zz.Color.gray(12));
        help_style = help_style.inline_style(true);

        const status_color: zz.Color = if (self.is_connected) zz.Color.green() else zz.Color.red();
        var status_style = zz.Style{};
        status_style = status_style.fg(status_color);
        status_style = status_style.inline_style(true);

        // Build header
        const title = title_style.render(ctx.allocator, "Nalar ZigZag TUI") catch "Nalar TUI";
        const status_text = if (self.is_connected) "Connected" else "Disconnected";
        const status = status_style.render(ctx.allocator, status_text) catch status_text;
        const session = self.session_id[0..self.session_id_len];
        const port_str = std.fmt.allocPrint(ctx.allocator, "{d}", .{self.http_port}) catch "8080";

        const header = std.fmt.allocPrint(
            ctx.allocator,
            "{s}\nSession: {s}  Port: {s}  Status: {s}\n",
            .{ title, session, port_str, status },
        ) catch "Error";

        // Build messages with simple ASCII box
        var messages_text = std.ArrayList(u8).empty;
        defer messages_text.deinit(ctx.allocator);
        const msg_writer = messages_text.writer(ctx.allocator);

        msg_writer.print("+", .{}) catch {};
        for (0..24) |_| msg_writer.print("-", .{}) catch {};
        msg_writer.print("+\n", .{}) catch {};

        if (self.message_count == 0) {
            const dim_text = dim_style.render(ctx.allocator, " No messages yet...") catch " No messages yet...";
            msg_writer.print("|{s} |\n", .{dim_text}) catch {};
        } else {
            for (0..self.message_count) |i| {
                const m = &self.messages[i];
                const content = m.getContent();
                const role = m.getRole();
                // Truncate if needed
                const display_content = if (content.len > 20) content[0..20] else content;
                msg_writer.print("| [{s}] {s}\n", .{ role, display_content }) catch {};
            }
        }

        msg_writer.print("+", .{}) catch {};
        for (0..24) |_| msg_writer.print("-", .{}) catch {};
        msg_writer.print("+\n", .{}) catch {};

        // Build input section
        const input_text = self.input.view(ctx.allocator) catch "";
        // Help text
        const help = help_style.render(
            ctx.allocator,
            "Enter: Send  |  c: Clear  |  q: Quit",
        ) catch "";

        // Combine all parts
        const final_str = std.fmt.allocPrint(
            ctx.allocator,
            "{s}\n{s}\n{s}\n\n{s}",
            .{ header, messages_text.items, input_text, help },
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

// Minimal test for MessageEntry behavior
test "MessageEntry basic operations" {
    // Create a Model-like structure
    var messages: [MAX_MESSAGES]MessageEntry = undefined;
    
    // Initialize all messages
    for (0..MAX_MESSAGES) |i| {
        messages[i] = MessageEntry.init();
    }
    
    // Test 1: Add a message manually to messages[0]
    messages[0].setRole("user");
    messages[0].setContent("Hello, this is a test message!");
    messages[0].timestamp = std.time.timestamp();
    
    // Test 2: Verify getRole() and getContent()
    const role = messages[0].getRole();
    const content = messages[0].getContent();
    
    std.debug.print("\n=== MessageEntry Test Results ===\n", .{});
    std.debug.print("Role: '{s}' (len={d})\n", .{ role, role.len });
    std.debug.print("Content: '{s}' (len={d})\n", .{ content, content.len });
    std.debug.print("Timestamp: {d}\n", .{messages[0].timestamp});
    
    // Verify the values
    try std.testing.expectEqualStrings("user", role);
    try std.testing.expectEqualStrings("Hello, this is a test message!", content);
    
    std.debug.print("\n✓ All assertions passed!\n", .{});
    
    // Test 3: Add assistant message
    messages[1].setRole("assistant");
    messages[1].setContent("I am the assistant responding.");
    
    const role2 = messages[1].getRole();
    const content2 = messages[1].getContent();
    
    std.debug.print("\n=== Second Message Test ===\n", .{});
    std.debug.print("Role: '{s}' (len={d})\n", .{ role2, role2.len });
    std.debug.print("Content: '{s}' (len={d})\n", .{ content2, content2.len });
    
    try std.testing.expectEqualStrings("assistant", role2);
    try std.testing.expectEqualStrings("I am the assistant responding.", content2);
    
    std.debug.print("✓ Second message test passed!\n", .{});
}

// Test to verify messages array initialization doesn't have issues
test "MessageEntry array initialization" {
    var messages: [10]MessageEntry = undefined;
    
    // This mimics what Model.init() does
    for (0..10) |i| {
        messages[i] = MessageEntry.init();
    }
    
    // Check that content_len is 0 for uninitialized access
    std.debug.print("\n=== Array Initialization Test ===\n", .{});
    std.debug.print("messages[5].content_len = {d}\n", .{messages[5].content_len});
    std.debug.print("messages[5].role_len = {d}\n", .{messages[5].role_len});
    
    // Verify empty message returns empty slice
    const empty_content = messages[5].getContent();
    const empty_role = messages[5].getRole();
    
    std.debug.print("Empty content slice len: {d}\n", .{empty_content.len});
    std.debug.print("Empty role slice len: {d}\n", .{empty_role.len});
    
    try std.testing.expect(empty_content.len == 0);
    try std.testing.expect(empty_role.len == 0);
    
    std.debug.print("✓ Array initialization test passed!\n", .{});
}

// Test session_id initialization issue
test "session_id undefined behavior" {
    var session_id: [64]u8 = undefined;
    const session_id_len: usize = 0;
    
    // This is what happens in Model.init() when allocPrint fails or returns empty
    // The memcpy is skipped, but session_id_len stays 0
    // session_id remains undefined!
    
    std.debug.print("\n=== Session ID Undefined Test ===\n", .{});
    std.debug.print("session_id_len = {d}\n", .{session_id_len});
    
    // This is SAFE because we're slicing 0..0
    const session_slice = session_id[0..session_id_len];
    std.debug.print("session_slice.len = {d}\n", .{session_slice.len});
    
    // But if we try to print the actual bytes when undefined...
    std.debug.print("First 8 bytes of undefined session_id: ", .{});
    for (0..8) |i| {
        std.debug.print("{d} ", .{session_id[i]});
    }
    std.debug.print("\n", .{});
    
    // This shows the garbage values!
    std.debug.print("\n⚠️  WARNING: If allocPrint fails, session_id contains garbage!\n", .{});
    
    try std.testing.expect(session_id_len == 0);
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
