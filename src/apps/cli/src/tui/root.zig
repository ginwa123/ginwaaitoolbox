//! Public API surface for the `tui` module.
//!
//! A from-scratch, Bubble-Tea-inspired TUI framework in Zig:
//!
//! ```zig
//! const tui = @import("tui");
//!
//! const MyModel = struct {
//!     pub fn update(self: *MyModel, msg: tui.Msg) !tui.Cmd { ... }
//!     pub fn view(self: *const MyModel, alloc, w, h) !tui.Frame { ... }
//! };
//!
//! var model = MyModel{};
//! var program = tui.Program(MyModel).init(&model, allocator, io);
//! try program.run();
//! ```

pub const color = @import("color.zig");
pub const style = @import("style.zig");
pub const key = @import("key.zig");
pub const terminal = @import("terminal.zig");
pub const frame = @import("frame.zig");
pub const msg = @import("msg.zig");
pub const program = @import("program.zig");
pub const widgets = @import("widgets.zig");

pub const Color = color.Color;
pub const Style = style.Style;
pub const Key = key.Key;
pub const Size = terminal.Size;
pub const Frame = frame.Frame;
pub const Cell = frame.Cell;
pub const Msg = msg.Msg;
pub const Cmd = msg.Cmd;
pub const Program = program.Program;

pub const Viewport = widgets.Viewport;
pub const Input = widgets.Input;
pub const Spinner = widgets.Spinner;
pub const StatusBar = widgets.StatusBar;

/// The chat application model (used by `nalar-tui`; reusable by other
/// frontends).
pub const app = @import("app.zig");
pub const transport = @import("transport.zig");
pub const sse = @import("sse.zig");

test {
    _ = color;
    _ = style;
    _ = key;
    _ = terminal;
    _ = frame;
    _ = msg;
    _ = program;
    _ = widgets;
    _ = app;
    _ = transport;
    _ = sse;
    _ = @import("think.zig");
    _ = @import("tool_envelope.zig");
    _ = @import("render_msg.zig");
    // TDD regression rounds (written before the fixes they pin).
    _ = @import("tdd_round2_test.zig");
}
