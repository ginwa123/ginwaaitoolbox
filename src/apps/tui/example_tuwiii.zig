// ============================================================================
// Example: How to use tuwiii.zig - TUI Framework
// Run with: zig run -lc src/apps/tui/example_tuwiii.zig
// ============================================================================

const std = @import("std");
const tuwiii = @import("tuwiii.zig");
const box_module = @import("box.zig");
const input_module = @import("input.zig");

const box = box_module.Box;
const RenderedContent = box_module.RenderedContent;
const Input = input_module.Input;

// ============================================================================
// Example Application Model (Full Framework)
// ============================================================================

const App = struct {
    counter: u32 = 0,
    text: []const u8 = "Hello from tuwiii!",
    focused_input: bool = false,
    input_component: *Input,
    allocator: std.mem.Allocator,
    // Store input history
    history: std.ArrayList([]const u8),
    // Scroll offset for history view (to handle long histories)
    history_scroll: usize = 0,
    // Number of visible lines in history box (set on first render)
    history_visible_lines: usize = 10,
    // Terminal dimensions (set on init)
    terminal_cols: u16 = 80,

    const Self = @This();

    pub fn update(self: *Self, msg: tuwiii.Msg) !tuwiii.Cmd {
        switch (msg) {
            .quit => {
                return .none;
            },
            .key => |key| {
                switch (key) {
                    'i' => {
                        self.focused_input = true;
                        return .none;
                    },
                    'b' => {
                        self.focused_input = false;
                        return .none;
                    },
                    'q' => {
                        return .{ .msgs = &[_]tuwiii.Msg{.quit} };
                    },
                    '+' => {
                        self.counter += 1;
                        return .none;
                    },
                    '-' => {
                        if (self.counter > 0) {
                            self.counter -= 1;
                        }
                        return .none;
                    },
                    else => {
                        if (self.focused_input) {
                            // Check for Enter key (13 or 10 = carriage return / newline)
                            if (key == 13 or key == 10) {
                                // Submit the input - add to history
                                const input_text = self.input_component.getText();
                                if (input_text.len > 0) {
                                    const history_entry = try self.allocator.dupe(u8, input_text);
                                    try self.history.append(self.allocator, history_entry);
                                    self.input_component.clear();
                                    // Reset scroll to show newest items
                                    self.history_scroll = if (self.history.items.len > self.history_visible_lines)
                                        self.history.items.len - self.history_visible_lines
                                    else
                                        0;
                                }
                            } else if (key == 127 or key == 8) {
                                // Backspace key (127 = Delete, 8 = Backspace)
                                try self.input_component.backspace();
                            } else if (key >= 32 and key <= 126) {
                                // Printable characters
                                try Input.insert(self.input_component, key);
                            }
                        }
                    },
                }
            },
            .key_seq => |seq| {
                if (std.mem.eql(u8, seq, "\x1b[A")) { // Up
                    // If history has content, scroll up (show older messages)
                    if (self.history.items.len > 0 and self.history_scroll > 0) {
                        self.history_scroll -= 1;
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[B")) { // Down
                    // If history has content, scroll down (show newer messages)
                    const max_scroll = if (self.history.items.len > self.history_visible_lines)
                        self.history.items.len - self.history_visible_lines
                    else
                        0;
                    if (self.history_scroll < max_scroll) {
                        self.history_scroll += 1;
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[C")) { // Right arrow
                    if (self.focused_input) {
                        self.input_component.moveRight();
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[D")) { // Left arrow
                    if (self.focused_input) {
                        self.input_component.moveLeft();
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[5~")) { // PageUp
                    // Scroll up by page
                    if (self.history.items.len > 0) {
                        if (self.history_scroll >= self.history_visible_lines) {
                            self.history_scroll -= self.history_visible_lines;
                        } else {
                            self.history_scroll = 0;
                        }
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[6~")) { // PageDown
                    // Scroll down by page
                    const max_scroll = if (self.history.items.len > self.history_visible_lines)
                        self.history.items.len - self.history_visible_lines
                    else
                        0;
                    if (self.history_scroll < max_scroll) {
                        self.history_scroll += self.history_visible_lines;
                        if (self.history_scroll > max_scroll) {
                            self.history_scroll = max_scroll;
                        }
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[H")) { // Home
                    // Scroll to beginning
                    self.history_scroll = 0;
                } else if (std.mem.eql(u8, seq, "\x1b[F")) { // End
                    // Scroll to end (most recent)
                    self.history_scroll = if (self.history.items.len > self.history_visible_lines)
                        self.history.items.len - self.history_visible_lines
                    else
                        0;
                }
            },
            else => {},
        }
        return .none;
    }

    pub fn view(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(allocator);

        // Build history content from stored history (with scrolling support)
        var history_lines = std.ArrayList(u8).empty;
        errdefer history_lines.deinit(allocator);

        if (self.history.items.len > 0) {
            // Calculate the range of visible history items based on scroll position
            const total_items = self.history.items.len;
            const start_idx = self.history_scroll;
            const end_idx = @min(start_idx + self.history_visible_lines, total_items);

            // Clamp start_idx to valid range
            const safe_start = @min(start_idx, total_items);

            for (self.history.items[safe_start..end_idx], safe_start..) |entry, i| {
                try history_lines.appendSlice(allocator, "> ");
                try history_lines.appendSlice(allocator, entry);
                if (i < total_items - 1) {
                    try history_lines.append(allocator, '\n');
                }
            }

            // Track if there are more items above or below
            const has_more_above = safe_start > 0;
            const has_more_below = end_idx < total_items;

            // Add scroll indicator if needed
            if (has_more_above or has_more_below) {
                try history_lines.appendSlice(allocator, "\n--- ");
                if (has_more_above) {
                    try history_lines.appendSlice(allocator, "(+older) ");
                }
                if (has_more_below) {
                    try history_lines.appendSlice(allocator, "(+newer)");
                }
                try history_lines.appendSlice(allocator, " ---");
            }
        } else {
            try history_lines.appendSlice(allocator, "History is empty. Type something and press Enter!");
        }

        const history_text = try history_lines.toOwnedSlice(allocator);
        defer allocator.free(history_text);

        // Get the input text
        _ = self.input_component.getText();

        // Set focus state for cursor rendering
        self.input_component.setFocus(self.focused_input);

        // Render input with cursor animation (using timestamp for blinking)
        // Pass terminal_cols for match_parent width mode
        const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
        const input_rendered = try self.input_component.render(timestamp_ms, self.terminal_cols);
        defer self.allocator.free(input_rendered);

        // Render the container box with history and input inside
        // try buffer.appendSlice(allocator, "\x1b[35mChat Application\x1b[0m\n");

        // Render history box using the Box component
        const historyRenderFn = struct {
            fn render() RenderedContent {
                return .{ .text = "" };
            }
        }.render;

        var history_box = try box.init(allocator, .{
            .border = false,
            .title = "History",
            // .padding = .{ .individual = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 } },
            .width = .match_parent,
            .height = .auto,
        }, historyRenderFn);
        // Set dynamic content
        history_box.setContent(history_text);
        defer history_box.destroy();

        const history_output = try history_box.renderToString();
        defer allocator.free(history_output);
        try buffer.appendSlice(allocator, history_output);
        try buffer.append(allocator, '\n');

        // Render input box using the Box component
        const inputRenderFn = struct {
            fn render() RenderedContent {
                return .{ .text = "" };
            }
        }.render;

        var input_box = try box.init(allocator, .{
            .border = true,
            .title = "Input",
            .padding = .{ .individual = .{ .top = 0, .right = 1, .bottom = 0, .left = 1 } },
            .width = .match_parent,
            .height = .{ .fixed = 3 }, // Need at least 3: top border + content + bottom border
        }, inputRenderFn);
        // Set dynamic content
        input_box.setContent(input_rendered);
        defer input_box.destroy();

        const input_output = try input_box.renderToString();
        defer allocator.free(input_output);
        try buffer.appendSlice(allocator, input_output);
        try buffer.append(allocator, '\n');

        // Status bar
        try buffer.appendSlice(allocator, "\x1b[1;36m"); // Bold cyan
        try buffer.appendSlice(allocator, "Status: ");
        if (self.focused_input) {
            try buffer.appendSlice(allocator, "Typing mode (press Enter to submit)");
        } else {
            try buffer.appendSlice(allocator, "Navigation mode (press 'i' to type)");
        }
        try buffer.appendSlice(allocator, " | Press 'q' to quit\x1b[0m\n");

        return buffer.toOwnedSlice(allocator);
    }

    pub const vtable: tuwiii.Model.VTable = .{
        .update = updateWrapper,
        .view = viewWrapper,
        .init = initWrapper,
        .deinit = deinitWrapper,
    };

    fn initWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Get terminal size to set appropriate visible lines
        const term_size = getTerminalSize();
        // Subtract some lines for other UI elements (title, input box, status bar)
        self.history_visible_lines = if (term_size.rows > 10) term_size.rows - 10 else 10;
        // Store terminal columns for input rendering
        self.terminal_cols = term_size.cols;
    }

    /// Get terminal size, returns default 80x24 if unavailable
    fn getTerminalSize() struct { rows: u16, cols: u16 } {
        // Try TIOCGWINSZ via direct syscall - try stdout first, then stderr, then stdin
        const fds = [_]u32{ std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO, std.posix.STDIN_FILENO };
        for (fds) |fd| {
            var ws: extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 } = undefined;
            const rc = std.os.linux.syscall3(
                std.os.linux.SYS.ioctl,
                @as(u64, fd),
                @as(u64, 0x5413), // TIOCGWINSZ
                @intFromPtr(&ws),
            );
            // Check for success (rc == 0) or -1 (errno) - also check ws values are non-zero
            if (rc >= 0 and ws.ws_col > 0 and ws.ws_row > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col };
            }
        }
        // Fallback to environment
        if (std.posix.getenv("LINES")) |lines| {
            if (std.posix.getenv("COLUMNS")) |columns| {
                const rows = std.fmt.parseInt(u16, lines, 10) catch 24;
                const cols = std.fmt.parseInt(u16, columns, 10) catch 80;
                return .{ .rows = rows, .cols = cols };
            }
        }
        // Final fallback
        return .{ .rows = 24, .cols = 80 };
    }

    fn deinitWrapper(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn updateWrapper(ptr: *anyopaque, msg: tuwiii.Msg) anyerror!tuwiii.Cmd {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.update(msg);
    }

    fn viewWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.view(allocator);
    }

    pub fn create(allocator: std.mem.Allocator) !*tuwiii.Model {
        // Input component (for actual input handling)
        const input_instance = try Input.init(allocator, .{
            .style = .plain,
            .mode = .multi_line,
            .cursor_blink_ms = 500, // Enable cursor blinking
            .width = .match_parent,
        });

        // Create app instance
        const app = try allocator.create(Self);
        app.* = .{
            .text = "Hello from tuwiii!",
            .focused_input = false,
            .input_component = input_instance,
            .allocator = allocator,
            .history = std.ArrayList([]const u8).empty,
        };

        // Create model wrapper
        const model = try allocator.create(tuwiii.Model);
        model.* = .{
            .ptr = app,
            .allocator = allocator,
            .vtable = &Self.vtable,
        };

        return model;
    }

    pub fn deinit(self: *Self) void {
        // Free all history entries
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        self.input_component.destroy();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    // Check for command line arguments
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the application model
    const model = try App.create(allocator);

    // Create and run the TUI program
    var program = try tuwiii.Program.init(allocator, model, .{
        .enable_mouse = false,
        .enable_raw = true,
        .use_alt_screen = true,
    });
    defer program.deinit();

    try program.run();

    // program.deinit() already cleans up the model via deinitModel()
    // so no additional cleanup needed here
}
