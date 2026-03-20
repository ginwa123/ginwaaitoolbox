const std = @import("std");
const raylib = @cImport({
    @cInclude("raylib.h");
});

const clay = @cImport({
    @cInclude("clay.h");
});

const clay_ui = @import("clay_ui.zig");

pub fn AppBar() void {
    clay_ui.begin(clay_ui.elemId("AppBar"), .{
        .layout = .{
            .direction = clay_ui.direction.top_to_bottom,
            .sizing = .{ .w = clay_ui.sizing.fixed(100), .h = clay_ui.sizing.fixed(50) },
            .padding = clay_ui.padding.all(10),
            .child_alignment = .{
                .x = clay.CLAY_ALIGN_X_CENTER,
                .y = clay.CLAY_ALIGN_Y_TOP,
            },
            .child_gap = 0,
        },
        .background_color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .border = clay.CLAY_BORDER_ALL(1),
        .corner_radius = clay.CLAY_CORNER_RADIUS(10),
    });
    defer clay_ui.end();
    // children here
}

pub fn main() void {
    const totalMemorySize: u32 = clay.Clay_MinMemorySize();
    const memory = std.heap.page_allocator.alloc(u8, totalMemorySize) catch @panic("Out of memory");
    defer std.heap.page_allocator.free(memory);

    const screenWidth: c_int = 1024;
    const screenHeight: c_int = 768;

    raylib.SetConfigFlags(raylib.FLAG_WINDOW_RESIZABLE);

    raylib.InitWindow(screenWidth, screenHeight, "Clay + Raylib App");
    defer raylib.CloseWindow();

    const arena = clay.Clay_CreateArenaWithCapacityAndMemory(totalMemorySize, memory.ptr);
    const context = clay.Clay_Initialize(arena, .{ .width = @floatFromInt(screenWidth), .height = @floatFromInt(screenHeight) }, .{ .errorHandlerFunction = null, .userData = null });
    _ = context;

    while (!raylib.WindowShouldClose()) {
        raylib.BeginDrawing();
        raylib.ClearBackground(raylib.RAYWHITE);
        AppBar();
        raylib.DrawText("Hello, world!", 100, 100, 20, raylib.BLACK);
        raylib.EndDrawing();
    }
}
