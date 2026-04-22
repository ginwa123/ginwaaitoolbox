//! Test TextInput behavior
const std = @import("std");
const zz = @import("zigzag");

pub const TestModel = struct {
    input: zz.TextInput,
    count: i32 = 0,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
    };

    pub fn init(self: *TestModel, ctx: *zz.Context) zz.Cmd(Msg) {
        self.input = zz.TextInput.init(ctx.allocator);
        self.input.setPrompt("> ");
        self.input.setPlaceholder("Type...");
        return .none;
    }

    pub fn update(self: *TestModel, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                std.debug.print("KEY EVENT: {}\n", .{k});
                switch (k.key) {
                    .char => |c| {
                        std.debug.print("CHAR: '{c}' (={d})\n", .{c, c});
                        self.input.handleKey(k);
                        std.debug.print("VALUE after char: '{s}'\n", .{self.input.getValue()});
                    },
                    .enter => {
                        std.debug.print("ENTER pressed, value: '{s}'\n", .{self.input.getValue()});
                        self.count += 1;
                    },
                    else => {
                        self.input.handleKey(k);
                    },
                }
            },
        }
        return .none;
    }

    pub fn view(self: *const TestModel, ctx: *const zz.Context) []const u8 {
        const input_text = self.input.view(ctx.allocator) catch "";
        const count_str = std.fmt.allocPrint(ctx.allocator, "Count: {d}\n{s}", .{ self.count, input_text }) catch "";
        return zz.place.place(ctx.allocator, ctx.width, ctx.height, .center, .top, count_str) catch count_str;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var program = try zz.Program(TestModel).init(gpa.allocator());
    defer program.deinit();
    try program.run();
}