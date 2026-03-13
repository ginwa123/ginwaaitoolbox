// ============================================================================
// Example: How to use box.zig
// Run with: zig run src/apps/tui/example_box.zig
// ============================================================================

const box = @import("box.zig");
const Box = box.Box;
const BoxOptions = box.BoxOptions;
const Padding = box.Padding;
const Dim = box.Dim;
const RenderedContent = box.RenderedContent;
const Direction = box.Direction;
const JustifyContent = box.JustifyContent;
const AlignItems = box.AlignItems;
const Overflow = box.Overflow;
const std = @import("std");

// Simple render functions for each example
fn renderHello() RenderedContent {
    return .{ .text = "Hello, World!" };
}

fn renderTitled() RenderedContent {
    return .{ .text = "Content inside titled box" };
}

fn renderPadded() RenderedContent {
    return .{ .text = "Box with extra padding" };
}

fn renderNoBorder() RenderedContent {
    return .{ .text = "No border box" };
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Simple box with text content
    const simpleBox = Box.init(allocator, .{
        .border = true,
        .title = null,
        .padding = .default(),
        .width = .default(),
        .height = .default(),
        .direction = .default(),
        .justify_content = .default(),
        .align_items = .default(),
        .overflow = .default(),
    }, renderHello) catch unreachable;
    defer simpleBox.destroy();

    const output = simpleBox.renderToString() catch unreachable;
    defer allocator.free(output);
    std.debug.print("Example 1: Simple box\n{s}\n\n", .{output});

    // Example 2: Box with a title
    const titledBox = Box.init(allocator, .{
        .border = true,
        .title = "My Title",
        .padding = .default(),
        .width = .default(),
        .height = .default(),
        .direction = .default(),
        .justify_content = .default(),
        .align_items = .default(),
        .overflow = .default(),
    }, renderTitled) catch unreachable;
    defer titledBox.destroy();

    const output2 = titledBox.renderToString() catch unreachable;
    defer allocator.free(output2);
    std.debug.print("Example 2: Box with title\n{s}\n\n", .{output2});

    // Example 3: Box with custom padding
    const paddedBox = Box.init(allocator, .{
        .border = true,
        .title = null,
        .padding = .{ .individual = .{ .top = 2, .right = 4, .bottom = 2, .left = 4 } },
        .width = .default(),
        .height = .default(),
        .direction = .default(),
        .justify_content = .default(),
        .align_items = .default(),
        .overflow = .default(),
    }, renderPadded) catch unreachable;
    defer paddedBox.destroy();

    const output3 = paddedBox.renderToString() catch unreachable;
    defer allocator.free(output3);
    std.debug.print("Example 3: Box with custom padding\n{s}\n\n", .{output3});

    // Example 4: Box without border
    const noBorderBox = Box.init(allocator, .{
        .border = false,
        .title = null,
        .padding = .default(),
        .width = .default(),
        .height = .default(),
        .direction = .default(),
        .justify_content = .default(),
        .align_items = .default(),
        .overflow = .default(),
    }, renderNoBorder) catch unreachable;
    defer noBorderBox.destroy();

    const output4 = noBorderBox.renderToString() catch unreachable;
    defer allocator.free(output4);
    std.debug.print("Example 4: Box without border\n{s}\n\n", .{output4});

    std.debug.print("All examples completed!\n", .{});
}
