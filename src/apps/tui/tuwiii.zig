const std = @import("std");
const box = @import("box.zig");
const input = @import("input.zig");

// ============================================================================
// tuwiii - TUI Framework (Bubbletea-inspired for Zig)
// ============================================================================
// A terminal user interface framework that provides:
// - Model-Update-View architecture (like Bubbletea)
// - Component composition (Box, Input, etc.)
// - Event-driven updates
// - Screen clearing and rendering
// - Message passing between components
//
// Similar to: Bubbletea (Go), Ratatui (Rust), Lip Gloss (Go)
// ============================================================================

// ============================================================================
// Core Types
// ============================================================================

/// Message type for communication between components and the TUI
pub const Msg = union(enum) {
    /// Quit the TUI application
    quit,
    /// Key press event
    key: u8,
    /// Special key sequence (arrows, function keys, etc.)
    key_seq: []const u8,
    /// Mouse event
    mouse: MouseEvent,
    /// Tick/timeout event
    tick,
    /// Custom user message with optional data
    custom: struct {
        type: []const u8,
        data: ?*anyopaque,
    },
    /// Batch of messages to process sequentially
    batch: []const Msg,
};

/// Mouse event data
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    action: MouseAction,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,
};

pub const MouseAction = enum {
    press,
    release,
    drag,
};

/// Model interface - the core of the TUI application
/// Implement this trait for your application state
pub const Model = struct {
    /// Pointer to the implementing type
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Handle incoming messages and return commands
        update: *const fn (*anyopaque, Msg) anyerror!Cmd,
        /// Render the current state to a string
        view: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const u8,
        /// Initialize the model (optional)
        init: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null,
        /// Cleanup resources (optional)
        deinit: ?*const fn (*anyopaque) void = null,
    };

    /// Update the model with a message and return commands
    pub fn update(self: *Model, msg: Msg) anyerror!Cmd {
        return self.vtable.update(self.ptr, msg);
    }

    /// View the current model state
    pub fn view(self: *Model, allocator: std.mem.Allocator) anyerror![]const u8 {
        return self.vtable.view(self.ptr, allocator);
    }

    /// Initialize the model
    pub fn initModel(self: *Model) anyerror!void {
        if (self.vtable.init) |init_fn| {
            return init_fn(self.ptr, self.allocator);
        }
    }

    /// Cleanup the model
    pub fn deinitModel(self: *Model) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self.ptr);
        }
    }
};

/// Command - an effect to be executed (async operation, timer, etc.)
pub const Cmd = union(enum) {
    /// No operation
    none,
    /// Send a message after a delay
    wait: struct {
        duration: u64, // milliseconds
        msg: *Msg,
    },
    /// Subscribe to an event source
    batch: []const Cmd,
    /// Send multiple messages
    msgs: []const Msg,
    /// Function to execute
    exec: *const fn () anyerror!?Msg,
};

/// Program configuration
pub const ProgramOptions = struct {
    /// Initial startup message
    startup_msg: ?Msg = null,
    /// Enable mouse support
    enable_mouse: bool = false,
    /// Enable raw mode
    enable_raw: bool = true,
    /// Alternative screen buffer
    use_alt_screen: bool = true,
    /// Custom keybindings
    keybindings: ?*Keybindings = null,
};

/// Keybindings configuration
pub const Keybindings = struct {
    quit: u8 = 3, // Ctrl+C
    quit_alt: u8 = 27, // Escape
    submit: u8 = 13, // Enter
    backspace: u8 = 127, // Delete/Backspace
    up: []const u8 = "\x1b[A",
    down: []const u8 = "\x1b[B",
    left: []const u8 = "\x1b[D",
    right: []const u8 = "\x1b[C",
    home: []const u8 = "\x1b[H",
    end: []const u8 = "\x1b[F",
};

// ============================================================================
// TUI Program - Main application orchestrator
// ============================================================================

/// The main TUI program that runs the event loop
pub const Program = struct {
    model: *Model,
    allocator: std.mem.Allocator,
    options: ProgramOptions,
    commands: std.ArrayList(Cmd),
    batch_queue: std.ArrayList([]const Msg),
    keybindings: Keybindings,
    running: bool = true,

    /// Create a new TUI program
    pub fn init(allocator: std.mem.Allocator, model: *Model, options: ProgramOptions) !Program {
        var program = Program{
            .model = model,
            .allocator = allocator,
            .options = options,
            .commands = std.ArrayList(Cmd).empty,
            .batch_queue = std.ArrayList([]const Msg).empty,
            .keybindings = if (options.keybindings) |kb| kb.* else .{},
        };

        try model.initModel();

        if (options.startup_msg) |msg| {
            try program.commands.append(allocator, .{ .msgs = &[_]Msg{msg} });
        }

        return program;
    }

    /// Run the TUI program
    pub fn run(self: *Program) !void {
        var term = try Terminal.init(self.allocator, .{
            .enable_raw = self.options.enable_raw,
            .use_alt_screen = self.options.use_alt_screen,
            .enable_mouse = self.options.enable_mouse,
        });
        defer term.deinit();

        // Initial clear only on first render
        try term.clearScreen();

        // Initial render (no clear needed - Terminal.render handles cursor positioning)
        var rendered = try self.model.view(self.allocator);
        defer self.allocator.free(rendered);
        try term.render(rendered);

        while (self.running) {
            // Process batch queue first
            while (self.batch_queue.items.len > 0) {
                const batch = self.batch_queue.orderedRemove(0);
                for (batch) |msg| {
                    try self.processMessage(msg);
                }
                self.allocator.free(batch);
            }

            // Process commands
            try self.processCommands();

            // Wait for input (non-blocking with small timeout)
            const msg = try term.readEvent(100);

            // Only re-render if there's input to process
            if (msg) |m| {
                try self.processMessage(m);

                // Re-render after processing the message
                rendered = try self.model.view(self.allocator);
                defer self.allocator.free(rendered);
                try term.render(rendered);
                
                // Small sleep to reduce flicker
                std.Thread.sleep(10 * 1000 * 1000); // 10ms
            }
        }

        // Cleanup
        term.restoreScreen();
    }

    /// Process a single message
    fn processMessage(self: *Program, msg: Msg) !void {
        // Handle built-in messages
        switch (msg) {
            .quit => {
                self.running = false;
                return;
            },
            .key => |key| {
                // Map key to higher-level messages if needed
                if (key == self.keybindings.quit or key == self.keybindings.quit_alt) {
                    try self.processMessage(.quit);
                    return;
                }
            },
            else => {},
        }

        // Pass message to model
        const cmd = try self.model.update(msg);

        // Queue the command
        try self.commands.append(self.allocator, cmd);
    }

    /// Process pending commands
    fn processCommands(self: *Program) !void {
        if (self.commands.items.len == 0) return;

        const cmd = self.commands.orderedRemove(0);

        switch (cmd) {
            .none => {},
            .wait => |wait| {
                std.Thread.sleep(wait.duration * 1_000_000);
                try self.batch_queue.append(self.allocator, &[_]Msg{wait.msg.*});
            },
            .batch => |batch| {
                var msgs = std.ArrayList(Msg).empty;
                defer msgs.deinit(self.allocator);
                for (batch) |c| {
                    try self.expandCommand(c, &msgs, self.allocator);
                }
                const batch_slice = try msgs.toOwnedSlice(self.allocator);
                try self.batch_queue.append(self.allocator, batch_slice);
            },
            .msgs => |msgs| {
                const msgs_copy = try self.allocator.dupe(Msg, msgs);
                try self.batch_queue.append(self.allocator, msgs_copy);
            },
            .exec => |exec_fn| {
                const maybe_msg = try exec_fn();
                if (maybe_msg) |m| {
                    try self.batch_queue.append(self.allocator, &[_]Msg{m});
                }
            },
        }
    }

    /// Expand a command into messages
    fn expandCommand(self: *Program, cmd: Cmd, out_msgs: *std.ArrayList(Msg), allocator: std.mem.Allocator) !void {
        switch (cmd) {
            .none => {},
            .wait => |wait| {
                _ = wait; // Not expanded immediately
            },
            .batch => |batch| {
                for (batch) |c| {
                    try self.expandCommand(c, out_msgs, self.allocator);
                }
            },
            .msgs => |msgs| {
                for (msgs) |m| {
                    try out_msgs.append(allocator, m);
                }
            },
            .exec => |exec_fn| {
                const maybe_msg = try exec_fn();
                if (maybe_msg) |m| {
                    try out_msgs.append(allocator, m);
                }
            },
        }
    }

    pub fn deinit(self: *Program) void {
        self.commands.deinit(self.allocator);
        for (self.batch_queue.items) |batch| {
            self.allocator.free(batch);
        }
        self.batch_queue.deinit(self.allocator);
        self.model.deinitModel();
    }
};

// ============================================================================
// Terminal - Low-level terminal control
// ============================================================================

const termios = if (@import("builtin").os.tag == .linux)
    @cImport({
        @cInclude("termios.h");
        @cInclude("unistd.h");
    })
else if (@import("builtin").os.tag == .macos)
    @cImport({
        @cInclude("termios.h");
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h");
    })
else
    struct {};

const TermOptions = struct {
    enable_raw: bool = true,
    use_alt_screen: bool = true,
    enable_mouse: bool = false,
};

const Terminal = struct {
    allocator: std.mem.Allocator,
    original_termios: if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) termios.termios else void,
    options: TermOptions,

    fn init(allocator: std.mem.Allocator, options: TermOptions) !Terminal {
        var self: Terminal = .{
            .allocator = allocator,
            .options = options,
            .original_termios = undefined,
        };

        if (options.enable_raw) {
            self.enableRawMode();
        }

        if (options.use_alt_screen) {
            try self.enableAltScreen();
        }

        if (options.enable_mouse) {
            try self.enableMouse();
        }

        return self;
    }

    fn deinit(self: *Terminal) void {
        if (self.options.enable_mouse) {
            self.disableMouse();
        }
        if (self.options.use_alt_screen) {
            self.disableAltScreen();
        }
        if (self.options.enable_raw) {
            self.disableRawMode();
        }
    }

    fn clearScreen(self: *Terminal) !void {
        _ = self;
        const clear = "\x1b[2J\x1b[H";
        const stdout = std.fs.File.stdout();
        _ = try stdout.write(clear);
    }

    fn restoreScreen(self: *Terminal) void {
        _ = self;
        const reset = "\x1b[?1049l\x1b[?25h";
        const stdout = std.fs.File.stdout();
        _ = stdout.write(reset) catch {};
    }

    fn render(self: *Terminal, content: []const u8) !void {
        _ = self;
        const stdout = std.fs.File.stdout();
        // Clear screen then position cursor at top
        _ = try stdout.write("\x1b[2J\x1b[H");
        _ = try stdout.write(content);
    }

    fn enableAltScreen(self: *Terminal) !void {
        _ = self;
        const enable = "\x1b[?1049h";
        const stdout = std.fs.File.stdout();
        _ = try stdout.write(enable);
    }

    fn disableAltScreen(self: *Terminal) void {
        _ = self;
        const disable = "\x1b[?1049l";
        const stdout = std.fs.File.stdout();
        _ = stdout.write(disable) catch {};
    }

    fn enableRawMode(self: *Terminal) void {
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) {
            const stdout = std.fs.File.stdout();

            // Save original termios FIRST
            _ = termios.tcgetattr(stdout.handle, &self.original_termios);
            var new_termios = self.original_termios;

            new_termios.c_lflag &= ~(@as(c_uint, @bitCast(termios.ICANON)) | @as(c_uint, @bitCast(termios.ECHO)));
            new_termios.c_cc[termios.VMIN] = 0;
            new_termios.c_cc[termios.VTIME] = 1;

            _ = termios.tcsetattr(stdout.handle, termios.TCSAFLUSH, &new_termios);
        }
    }

    fn disableRawMode(self: *Terminal) void {
        if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) {
            const stdout = std.fs.File.stdout();
            _ = termios.tcsetattr(stdout.handle, termios.TCSAFLUSH, &self.original_termios);
        }
    }

    fn enableMouse(self: *Terminal) !void {
        _ = self;
        const enable = "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h";
        const stdout = std.fs.File.stdout();
        _ = try stdout.write(enable);
    }

    fn disableMouse(self: *Terminal) void {
        _ = self;
        const disable = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l";
        const stdout = std.fs.File.stdout();
        _ = stdout.write(disable) catch {};
    }

    fn readEvent(self: *Terminal, timeout_ms: u64) !?Msg {
        _ = self;
        const stdin = std.fs.File.stdin();

        var poll_fd = [1]std.posix.pollfd{.{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = std.posix.poll(&poll_fd, @intCast(timeout_ms)) catch return null;
        if (poll_result == 0) return null;

        if (poll_fd[0].revents & std.posix.POLL.IN != 0) {
            var buf: [10]u8 = undefined;
            const n = try stdin.read(&buf);

            if (n == 1) {
                return .{ .key = buf[0] };
            }

            if (n >= 2 and buf[0] == 0x1b and buf[1] == '[') {
                return .{ .key_seq = buf[0..n] };
            }
        }

        return null;
    }
};

// ============================================================================
// Component Wrappers
// ============================================================================

/// Wrap a Box component for use in TUI
pub const BoxComponent = struct {
    box: *box.Box,

    pub fn init(box_component: *box.Box) BoxComponent {
        return .{ .box = box_component };
    }

    pub fn render(self: BoxComponent, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        return self.box.renderToString();
    }
};

/// Wrap an Input component for use in TUI
pub const InputComponent = struct {
    input: *input.Input,

    pub fn init(input_component: *input.Input) InputComponent {
        return .{ .input = input_component };
    }

    pub fn render(self: InputComponent, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        return self.input.render();
    }

    pub fn handleKey(self: *InputComponent, key: u8) !void {
        switch (key) {
            13 => {}, // Enter - handled by parent
            127, 8 => try self.input.backspace(),
            3 => {}, // Ctrl+C - handled by parent
            else => {
                if (key >= 32 and key <= 126) {
                    try self.input.insert(key);
                }
            },
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a simple text model
pub fn SimpleTextModel(comptime T: type) type {
    _ = T;
    return struct {
        text: []const u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn update(self: *Self, msg: Msg) !Cmd {
            _ = self;
            _ = msg;
            return .none;
        }

        pub fn view(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, self.text);
        }

        pub const vtable: Model.VTable = .{
            .update = Self.updateWrapper,
            .view = Self.viewWrapper,
        };

        fn updateWrapper(ptr: *anyopaque, msg: Msg) anyerror!Cmd {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.update(msg);
        }

        fn viewWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.view(allocator);
        }
    };
}

/// Create a model wrapper for any type
pub fn ModelWrapper(comptime T: type) type {
    return struct {
        inner: T,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, inner: T) !*Model {
            const wrapper = try allocator.create(Self);
            wrapper.* = .{
                .inner = inner,
                .allocator = allocator,
            };

            const model = try allocator.create(Model);
            model.* = .{
                .vtable = &Self.vtable,
                .allocator = allocator,
            };
            return model;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn update(self: *Self, msg: Msg) !Cmd {
            _ = self;
            _ = msg;
            return .none;
        }

        pub fn view(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            _ = self;
            return allocator.dupe(u8, "");
        }

        pub const vtable: Model.VTable = .{
            .update = Self.updateWrapper,
            .view = Self.viewWrapper,
        };

        fn updateWrapper(ptr: *anyopaque, msg: Msg) anyerror!Cmd {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.update(msg);
        }

        fn viewWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.view(allocator);
        }
    };
}

// ============================================================================
// Layout Helpers
// ============================================================================

/// Layout container for arranging multiple components
pub const Layout = struct {
    components: std.ArrayList(*Model),
    direction: box.Direction = .column,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{
            .components = std.ArrayList(*Model).empty,
            .allocator = allocator,
        };
    }

    pub fn addComponent(self: *Layout, component: *Model) !void {
        try self.components.append(self.allocator, component);
    }

    pub fn render(self: *Layout, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit();

        for (self.components.items) |component| {
            const rendered = try component.view(allocator);
            defer allocator.free(rendered);
            try buffer.appendSlice(allocator, rendered);
            if (self.direction == .column) {
                try buffer.append(allocator, '\n');
            }
        }

        return buffer.toOwnedSlice(allocator);
    }
};
