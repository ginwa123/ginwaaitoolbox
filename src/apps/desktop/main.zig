const std = @import("std");
const clayUI = @import("clay_ui.zig");

pub fn AppBarNew() void {
    clayUI.ClayUI.Build(.{
        .id = "AppBar",
        .props = .{
            .layout = .{
                .sizing = .{
                    .width = clayUI.CLAY_SIZING_GROW(0, 0),
                    .height = .{
                        .type = 3,
                        .size = .{ .minMax = .{ .min = 100, .max = 100 } },
                    },
                },
            },
            .backgroundColor = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        },
        .children = struct {
            fn run() void {
                const config = clayUI.clay.Clay_TextElementConfig{
                    .fontSize = 20,
                    .textColor = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    .fontId = 0,
                };
                clayUI.ClayText("Hello, world!", config);
            }
        }.run,
    });
}

// C renderer
extern fn Clay_Raylib_Render(
    renderCommands: clayUI.clay.Clay_RenderCommandArray,
    fonts: [*c]clayUI.raylib.Font,
) void;

pub fn main() void {
    const totalMemorySize: u32 = clayUI.clay.Clay_MinMemorySize();
    const memory = std.heap.page_allocator.alloc(u8, totalMemorySize) catch @panic("Out of memory");
    defer std.heap.page_allocator.free(memory);

    const screenWidth: c_int = 1024;
    const screenHeight: c_int = 768;

    // Init window FIRST
    clayUI.raylib.SetConfigFlags(clayUI.raylib.FLAG_WINDOW_RESIZABLE);
    clayUI.raylib.InitWindow(screenWidth, screenHeight, "Clay + Raylib App");
    defer clayUI.raylib.CloseWindow();

    // Load font AFTER InitWindow
    var fonts: [10]clayUI.raylib.Font = undefined;
    fonts[0] = clayUI.raylib.LoadFontEx(
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        48,
        null,
        0,
    );

    clayUI.raylib.SetTextureFilter(
        fonts[0].texture,
        clayUI.raylib.TEXTURE_FILTER_BILINEAR,
    );

    std.debug.print("font texture id: {}\n", .{fonts[0].texture.id});

    // Init Clay
    const arena = clayUI.clay.Clay_CreateArenaWithCapacityAndMemory(
        totalMemorySize,
        memory.ptr,
    );

    _ = clayUI.clay.Clay_Initialize(
        arena,
        .{
            .width = @floatFromInt(screenWidth),
            .height = @floatFromInt(screenHeight),
        },
        .{
            .errorHandlerFunction = null,
            .userData = null,
        },
    );

    // Main loop
    while (!clayUI.raylib.WindowShouldClose()) {
        clayUI.clay.Clay_BeginLayout();

        clayUI.raylib.ClearBackground(clayUI.raylib.RAYWHITE);

        // drawing ui starts here
        clayUI.raylib.BeginDrawing();

        defer clayUI.raylib.EndDrawing();
        AppBarNew();
        // drawing ui ends here

        const renderCommands = clayUI.clay.Clay_EndLayout();
        Clay_Raylib_Render(renderCommands, fonts[0..].ptr);
    }
}
