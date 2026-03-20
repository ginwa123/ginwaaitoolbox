const clay = @cImport({
    @cInclude("clay.h");
});

const std = @import("std");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Begin a UI element with config. Children go after, then end().
pub fn begin(id: clay.Clay_ElementId, config: anytype) void {
    clay.Clay__OpenElementWithId(id);
    clay.Clay__ConfigureOpenElement(buildDecl(config));
}

/// Begin without an ID (auto-generated).
pub fn beginAuto(config: anytype) void {
    clay.Clay__OpenElement();
    clay.Clay__ConfigureOpenElement(buildDecl(config));
}

/// End the current element. Use defer end() for RAII-style.
pub fn end() void {
    clay.Clay__CloseElement();
}

// ---------------------------------------------------------------------------
// Config builders
// ---------------------------------------------------------------------------

pub fn elemId(label: [:0]const u8) clay.Clay_ElementId {
    return clay.Clay__HashString(.{
        .isStaticallyAllocated = true,
        .length = @intCast(label.len),
        .chars = label.ptr,
    }, 0);
}

pub const direction = struct {
    pub const top_to_bottom = clay.CLAY_TOP_TO_BOTTOM;
    pub const left_to_right = clay.CLAY_LEFT_TO_RIGHT;
    pub const right_to_left = clay.CLAY_RIGHT_TO_LEFT;
    pub const bottom_to_top = clay.CLAY_BOTTOM_TO_TOP;
};

pub const sizing = struct {
    pub fn fixed(comptime v: f32) clay.Clay_SizingAxis {
        return clay.CLAY_SIZING_FIXED(v);
    }
    pub fn fit(min: f32, max: f32) clay.Clay_SizingAxis {
        return clay.CLAY_SIZING_FIT(min, max);
    }
    pub fn grow(max: f32) clay.Clay_SizingAxis {
        return clay.CLAY_SIZING_FIT(0, max);
    }
    pub fn percent(v: f32) clay.Clay_SizingAxis {
        return clay.CLAY_SIZING_PERCENT(v);
    }
};

pub const padding = struct {
    pub fn all(comptime v: i32) clay.Clay_Padding {
        return clay.CLAY_PADDING_ALL(v);
    }
    pub fn horizontal(v: i32) clay.Clay_Padding {
        return .{ .left = v, .right = v, .top = 0, .bottom = 0 };
    }
    pub fn vertical(v: i32) clay.Clay_Padding {
        return .{ .left = 0, .right = 0, .top = v, .bottom = v };
    }
};

pub const alignment = struct {
    pub const x = struct {
        pub const left = clay.CLAY_ALIGN_X_LEFT;
        pub const center = clay.CLAY_ALIGN_X_CENTER;
        pub const right = clay.CLAY_ALIGN_X_RIGHT;
    };
    pub const y = struct {
        pub const top = clay.CLAY_ALIGN_Y_TOP;
        pub const center = clay.CLAY_ALIGN_Y_CENTER;
        pub const bottom = clay.CLAY_ALIGN_Y_BOTTOM;
    };
};

// ---------------------------------------------------------------------------
// Internal: build Clay_ElementDeclaration from config struct
// ---------------------------------------------------------------------------

fn buildDecl(comptime config: anytype) clay.Clay_ElementDeclaration {
    var decl = std.mem.zeroes(clay.Clay_ElementDeclaration);

    inline for (@typeInfo(@TypeOf(config)).Struct.fields) |field| {
        const name = field.name;
        const value = @field(config, name);

        if (comptime std.mem.eql(u8, name, "layout")) {
            inline for (@typeInfo(@TypeOf(value)).Struct.fields) |lf| {
                const lv = @field(value, lf.name);
                if (comptime std.mem.eql(u8, lf.name, "direction")) {
                    decl.layout.layoutDirection = lv;
                } else if (comptime std.mem.eql(u8, lf.name, "sizing")) {
                    if (comptime hasField(value, "w")) decl.layout.sizing[0] = value.w;
                    if (comptime hasField(value, "h")) decl.layout.sizing[1] = value.h;
                } else if (comptime std.mem.eql(u8, lf.name, "padding")) {
                    decl.layout.padding = lv;
                } else if (comptime std.mem.eql(u8, lf.name, "child_alignment")) {
                    if (comptime hasField(lv, "x")) decl.layout.childAlignment.x = lv.x;
                    if (comptime hasField(lv, "y")) decl.layout.childAlignment.y = lv.y;
                } else if (comptime std.mem.eql(u8, lf.name, "child_gap")) {
                    decl.layout.gap = lv;
                }
            }
        } else if (comptime std.mem.eql(u8, name, "background_color")) {
            decl.backgroundColor = value;
        } else if (comptime std.mem.eql(u8, name, "border")) {
            decl.border = value;
        } else if (comptime std.mem.eql(u8, name, "corner_radius")) {
            decl.cornerRadius = value;
        } else if (comptime std.mem.eql(u8, name, "margin")) {
            decl.layout.margin = value;
        }
    }

    return decl;
}

fn hasField(comptime T: type, comptime name: []const u8) bool {
    return @hasField(T, name);
}
