// ============================================================================
// Example: How to use input.zig
// Run with: zig run src/apps/tui/example_input.zig
// ============================================================================

const input = @import("input.zig");
const Input = input.Input;
const InputOptions = input.InputOptions;
const InputMode = input.InputMode;
const InputStyle = input.InputStyle;
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== TUI Input Component Examples ===\n\n", .{});

    // Example 1: Simple text input with placeholder
    std.debug.print("Example 1: Simple text input with placeholder\n", .{});
    const simpleInput = Input.init(allocator, .{
        .width = 30,
        .placeholder = "Enter your name...",
        .mode = .single_line,
        .style = .boxed,
        .title = "Name",
    }) catch unreachable;
    defer simpleInput.destroy();

    try simpleInput.insertSlice("John Doe");
    const output1 = simpleInput.render() catch unreachable;
    defer allocator.free(output1);
    std.debug.print("{s}\n", .{output1});

    // Example 2: Password input
    std.debug.print("Example 2: Password input (masked)\n", .{});
    const passwordInput = input.createPasswordInput(allocator, 30) catch unreachable;
    defer passwordInput.destroy();

    try passwordInput.insertSlice("secret123");
    const output2 = passwordInput.render() catch unreachable;
    defer allocator.free(output2);
    std.debug.print("{s}\n", .{output2});

    // Example 3: Plain style input
    std.debug.print("Example 3: Plain style input\n", .{});
    const plainInput = Input.init(allocator, .{
        .width = 40,
        .mode = .single_line,
        .style = .plain,
    }) catch unreachable;
    defer plainInput.destroy();

    try plainInput.insertSlice("Plain text input without border");
    const output3 = plainInput.render() catch unreachable;
    defer allocator.free(output3);
    std.debug.print("{s}\n", .{output3});

    // Example 4: Underlined style input
    std.debug.print("Example 4: Underlined style input\n", .{});
    const underlinedInput = Input.init(allocator, .{
        .width = 35,
        .placeholder = "Type here...",
        .mode = .single_line,
        .style = .underlined,
    }) catch unreachable;
    defer underlinedInput.destroy();

    try underlinedInput.insertSlice("Underlined input");
    const output4 = underlinedInput.render() catch unreachable;
    defer allocator.free(output4);
    std.debug.print("{s}\n", .{output4});

    // Example 5: Input with max length
    std.debug.print("Example 5: Input with max length (10)\n", .{});
    const maxLengthInput = Input.init(allocator, .{
        .width = 30,
        .max_length = 10,
        .mode = .single_line,
        .style = .boxed,
        .title = "Max 10 chars",
    }) catch unreachable;
    defer maxLengthInput.destroy();

    try maxLengthInput.insertSlice("This is too long");
    const output5 = maxLengthInput.render() catch unreachable;
    defer allocator.free(output5);
    std.debug.print("{s}\n", .{output5});
    std.debug.print("Note: Text truncated to 10 chars: {s}\n\n", .{maxLengthInput.getText()});

    // Example 6: Cursor movement demonstration
    std.debug.print("Example 6: Cursor movement\n", .{});
    const cursorDemo = Input.init(allocator, .{
        .width = 25,
        .mode = .single_line,
        .style = .boxed,
        .title = "Cursor Demo",
    }) catch unreachable;
    defer cursorDemo.destroy();

    try cursorDemo.insertSlice("Hello World");
    const output6a = cursorDemo.render() catch unreachable;
    defer allocator.free(output6a);
    std.debug.print("Initial text:\n{s}", .{output6a});
    std.debug.print("Cursor position: {d}\n", .{cursorDemo.getCursor()});

    cursorDemo.moveHome();
    const output6b = cursorDemo.render() catch unreachable;
    defer allocator.free(output6b);
    std.debug.print("After moveHome():\n{s}", .{output6b});
    std.debug.print("Cursor position: {d}\n", .{cursorDemo.getCursor()});

    cursorDemo.moveEnd();
    const output6c = cursorDemo.render() catch unreachable;
    defer allocator.free(output6c);
    std.debug.print("After moveEnd():\n{s}", .{output6c});
    std.debug.print("Cursor position: {d}\n", .{cursorDemo.getCursor()});

    cursorDemo.moveLeft();
    cursorDemo.moveLeft();
    cursorDemo.moveLeft();
    const output6d = cursorDemo.render() catch unreachable;
    defer allocator.free(output6d);
    std.debug.print("After 3x moveLeft():\n{s}", .{output6d});
    std.debug.print("Cursor position: {d}\n\n", .{cursorDemo.getCursor()});

    // Example 7: Editing operations
    std.debug.print("Example 7: Editing operations\n", .{});
    const editDemo = Input.init(allocator, .{
        .width = 30,
        .mode = .single_line,
        .style = .boxed,
        .title = "Edit Demo",
    }) catch unreachable;
    defer editDemo.destroy();

    try editDemo.insertSlice("Hello World");
    const output7a = editDemo.render() catch unreachable;
    defer allocator.free(output7a);
    std.debug.print("Initial: {s}", .{output7a});

    editDemo.moveHome();
    try editDemo.delete();
    const output7b = editDemo.render() catch unreachable;
    defer allocator.free(output7b);
    std.debug.print("After delete at start: {s}", .{output7b});

    editDemo.moveEnd();
    try editDemo.backspace();
    try editDemo.backspace();
    const output7c = editDemo.render() catch unreachable;
    defer allocator.free(output7c);
    std.debug.print("After 2x backspace: {s}", .{output7c});

    editDemo.moveHome();
    try editDemo.insertSlice("Hi ");
    const output7d = editDemo.render() catch unreachable;
    defer allocator.free(output7d);
    std.debug.print("After insert at start: {s}\n", .{output7d});

    // Example 8: Clear and setText
    std.debug.print("Example 8: Clear and setText\n", .{});
    const clearDemo = Input.init(allocator, .{
        .width = 30,
        .mode = .single_line,
        .style = .boxed,
        .title = "Clear Demo",
    }) catch unreachable;
    defer clearDemo.destroy();

    try clearDemo.insertSlice("Temporary text");
    const output8a = clearDemo.render() catch unreachable;
    defer allocator.free(output8a);
    std.debug.print("With text: {s}", .{output8a});

    clearDemo.clear();
    const output8b = clearDemo.render() catch unreachable;
    defer allocator.free(output8b);
    std.debug.print("After clear(): {s}", .{output8b});

    try clearDemo.setText("New text via setText()");
    const output8c = clearDemo.render() catch unreachable;
    defer allocator.free(output8c);
    std.debug.print("After setText(): {s}\n", .{output8c});

    std.debug.print("=== All examples completed! ===\n", .{});
}
