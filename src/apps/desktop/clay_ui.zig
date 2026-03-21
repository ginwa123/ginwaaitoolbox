const c = @import("c.zig");

pub const clay = c.clay;
pub const raylib = c.raylib;

pub const ClayUI = struct {
    pub const Modifier = struct {
        id: []const u8,
        props: clay.Clay_ElementDeclaration,
        children: ?fn () void,
    };

    pub fn Build(comptime modifier: Modifier) void {
        const id = modifier.id;
        const clay_string = clay.Clay_String{
            .length = @intCast(id.len),
            .chars = id.ptr,
        };

        const element_id = clay.Clay_GetElementId(clay_string);
        clay.Clay__OpenElementWithId(element_id);
        clay.Clay__ConfigureOpenElement(modifier.props);

        if (modifier.children) |child| {
            child();
        }

        clay.Clay__CloseElement();
    }

    pub fn CloseElement() void {
        clay.Clay__CloseElement();
    }
};

pub fn CLAY_SIZING_GROW(min: f32, max: f32) clay.Clay_SizingAxis {
    return .{
        .type = 1,
        .size = .{ .minMax = .{ .min = min, .max = max } },
    };
}

pub fn ClayText(text: []const u8, config: clay.Clay_TextElementConfig) void {
    const clay_string = clay.Clay_String{
        .length = @intCast(text.len),
        .chars = text.ptr,
    };
    clay.Clay__OpenTextElement(clay_string, @constCast(&config));
}

