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
// Simple Example Without Full Framework
// ============================================================================

pub fn simpleExample() !void {
    const allocator = std.heap.page_allocator;

    // Clear screen - use escape sequences directly
    const clear_screen = "\x1b[2J\x1b[H";
    std.debug.print("{s}", .{clear_screen});

    // Create and display a box
    const box_render_fn = struct {
        fn render() RenderedContent {
            return .{ .text = "Simple tuwiii example!\nPress any key to quit..." };
        }
    }.render;

    const my_box = box.init(allocator, .{
        .border = true,
        .title = "tuwiii Demo",
        .padding = .{ .individual = .{ .top = 2, .right = 4, .bottom = 2, .left = 4 } },
    }, box_render_fn) catch unreachable;
    defer my_box.destroy();

    const output = my_box.renderToString() catch unreachable;
    std.debug.print("{s}\n\n", .{output});

    // Create and display an input
    const my_input = Input.init(allocator, .{
        .width = 40,
        .placeholder = "Type something...",
        .style = .boxed,
        .title = "Input Field",
    }) catch unreachable;
    defer my_input.destroy();

    // Pre-fill some text
    try Input.insertSlice(my_input, "Hello tuwiii!");
    const input_output = my_input.render() catch unreachable;
    std.debug.print("{s}\n\n", .{input_output});

    std.debug.print("\x1b[32mExample complete! Press Enter to exit...\x1b[0m", .{});
    var buf: [1]u8 = undefined;
    _ = try std.posix.read(std.posix.STDIN_FILENO, &buf);
}

// ============================================================================
// Example Application Model (Full Framework)
// ============================================================================

const App = struct {
    counter: u32 = 0,
    text: []const u8 = "Hello from tuwiii!",
    focused_input: bool = false,
    box_component: *box_module.Box,
    input_component: *Input,
    allocator: std.mem.Allocator,

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
                            try Input.insert(self.input_component, key);
                        }
                    },
                }
            },
            .key_seq => |seq| {
                if (std.mem.eql(u8, seq, "\x1b[A")) { // Up
                    self.counter += 1;
                } else if (std.mem.eql(u8, seq, "\x1b[B")) { // Down
                    if (self.counter > 0) self.counter -= 1;
                }
            },
            else => {},
        }
        return .none;
    }

    pub fn view(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(allocator);

        // Header
        try buffer.appendSlice(allocator, "\x1b[36m"); // Cyan
        try buffer.appendSlice(allocator, "╔══════════════════════════════════════════════════════╗\n");
        try buffer.appendSlice(allocator, "║         tuwiii TUI Framework - Interactive Demo      ║\n");
        try buffer.appendSlice(allocator, "╚══════════════════════════════════════════════════════╝\x1b[0m\n\n");

        // Instructions
        try buffer.appendSlice(allocator, "\x1b[33m"); // Yellow
        try buffer.appendSlice(allocator, "Controls:\n");
        try buffer.appendSlice(allocator, "  i  - Focus input field\n");
        try buffer.appendSlice(allocator, "  b  - Focus box (view counter)\n");
        try buffer.appendSlice(allocator, "  +  - Increment counter\n");
        try buffer.appendSlice(allocator, "  -  - Decrement counter\n");
        try buffer.appendSlice(allocator, "  ↑  - Arrow up (increment)\n");
        try buffer.appendSlice(allocator, "  ↓  - Arrow down (decrement)\n");
        try buffer.appendSlice(allocator, "  q  - Quit\n");
        try buffer.appendSlice(allocator, "\x1b[0m\n");

        // Counter display
        try buffer.appendSlice(allocator, "Counter: ");
        try buffer.appendSlice(allocator, "\x1b[32m"); // Green
        const counter_str = try std.fmt.allocPrint(allocator, "{d}", .{self.counter});
        defer allocator.free(counter_str);
        try buffer.appendSlice(allocator, counter_str);
        try buffer.appendSlice(allocator, "\x1b[0m\n\n");

        // Box component
        try buffer.appendSlice(allocator, "\x1b[35mBox Component:\x1b[0m\n");
        const box_output = try self.box_component.renderToString();
        defer allocator.free(box_output);
        try buffer.appendSlice(allocator, box_output);
        try buffer.append(allocator, '\n');

        // Input component
        try buffer.appendSlice(allocator, "\x1b[35mInput Component ");
        if (self.focused_input) {
            try buffer.appendSlice(allocator, "[FOCUSED]");
        } else {
            try buffer.appendSlice(allocator, "(press 'i' to focus)");
        }
        try buffer.appendSlice(allocator, ":\x1b[0m\n");
        const input_output = try self.input_component.render();
        defer allocator.free(input_output);
        try buffer.appendSlice(allocator, input_output);
        try buffer.append(allocator, '\n');

        // Status bar
        try buffer.appendSlice(allocator, "\x1b[1;36m"); // Bold cyan
        try buffer.appendSlice(allocator, "Status: ");
        if (self.focused_input) {
            try buffer.appendSlice(allocator, "Typing mode");
        } else {
            try buffer.appendSlice(allocator, "Navigation mode");
        }
        try buffer.appendSlice(allocator, " | tuwiii is running\x1b[0m\n");

        return buffer.toOwnedSlice(allocator);
    }

    pub const vtable: tuwiii.Model.VTable = .{
        .update = updateWrapper,
        .view = viewWrapper,
        .init = initWrapper,
        .deinit = deinitWrapper,
    };

    fn initWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = ptr;
        _ = allocator;
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
        // Create box component
        const box_render_fn = struct {
            fn render() RenderedContent {
                return .{ .text = "This is a Box component!\nIt can hold any content.\nUse arrow keys to change the counter." };
            }
        }.render;

        const box_instance = try box.init(allocator, .{
            .border = true,
            .title = "My Box",
            .padding = .{ .individual = .{ .top = 1, .right = 2, .bottom = 1, .left = 2 } },
            .width = .{ .fixed = 50 },
            .height = .{ .fixed = 6 },
        }, box_render_fn);

        // Create input component
        const input_instance = try Input.init(allocator, .{
            .width = 40,
            .placeholder = "Type here...",
            .style = .boxed,
            .title = "Message",
            .mode = .single_line,
        });

        // Create app instance
        const app = try allocator.create(Self);
        app.* = .{
            .counter = 0,
            .text = "Hello from tuwiii!",
            .focused_input = false,
            .box_component = box_instance,
            .input_component = input_instance,
            .allocator = allocator,
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
        self.box_component.destroy();
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

    if (args.len > 1 and std.mem.eql(u8, args[1], "--simple")) {
        try simpleExample();
        return;
    }

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

    // Cleanup
    const app_ptr: *App = @ptrCast(@alignCast(model.ptr));
    app_ptr.deinit();
    allocator.destroy(model);
}
