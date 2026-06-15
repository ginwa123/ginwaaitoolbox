const std = @import("std");
const xmlEscape = @import("xml_escape.zig").xmlEscape;


/// Recursive helper for `jsonArgsToXml`. Serializes one key-value pair as
/// `<key>value</key>` (or `<key/>` for null) into the buffer.
pub fn jsonValueToXml(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), key: []const u8, value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const escaped_val = try xmlEscape(allocator, s);
            defer allocator.free(escaped_val);
            const formatted = try std.fmt.allocPrint(allocator, "<{s}>{s}</{s}>", .{ escaped_key, escaped_val, escaped_key });
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
        .integer => |i| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const formatted = try std.fmt.allocPrint(allocator, "<{s}>{d}</{s}>", .{ escaped_key, i, escaped_key });
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
        .float => |f| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const formatted = try std.fmt.allocPrint(allocator, "<{s}>{d}</{s}>", .{ escaped_key, f, escaped_key });
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
        .bool => |b| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const bool_str = if (b) "true" else "false";
            const formatted = try std.fmt.allocPrint(allocator, "<{s}>{s}</{s}>", .{ escaped_key, bool_str, escaped_key });
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
        .null => {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const formatted = try std.fmt.allocPrint(allocator, "<{s}/>", .{escaped_key});
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
        .array => |arr| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            try buffer.appendSlice(allocator, "<");
            try buffer.appendSlice(allocator, escaped_key);
            try buffer.append(allocator, '>');
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        const escaped_val = try xmlEscape(allocator, s);
                        defer allocator.free(escaped_val);
                        const formatted = try std.fmt.allocPrint(allocator, "<item>{s}</item>", .{escaped_val});
                        defer allocator.free(formatted);
                        try buffer.appendSlice(allocator, formatted);
                    },
                    .integer => |i| {
                        const formatted = try std.fmt.allocPrint(allocator, "<item>{d}</item>", .{i});
                        defer allocator.free(formatted);
                        try buffer.appendSlice(allocator, formatted);
                    },
                    .float => |f| {
                        const formatted = try std.fmt.allocPrint(allocator, "<item>{d}</item>", .{f});
                        defer allocator.free(formatted);
                        try buffer.appendSlice(allocator, formatted);
                    },
                    .bool => |b| {
                        const bool_str = if (b) "true" else "false";
                        const formatted = try std.fmt.allocPrint(allocator, "<item>{s}</item>", .{bool_str});
                        defer allocator.free(formatted);
                        try buffer.appendSlice(allocator, formatted);
                    },
                    .null => try buffer.appendSlice(allocator, "<item/>"),
                    .object => |obj| {
                        try buffer.appendSlice(allocator, "<item>");
                        var it = obj.iterator();
                        while (it.next()) |entry| {
                            try jsonValueToXml(allocator, buffer, entry.key_ptr.*, entry.value_ptr.*);
                        }
                        try buffer.appendSlice(allocator, "</item>");
                    },
                    .array => {
                        // Nested arrays: flatten to <item/> for now.
                        try buffer.appendSlice(allocator, "<item/>");
                    },
                    else => {
                        // Defensive for any unhandled variant (e.g. .number_string)
                        try buffer.appendSlice(allocator, "<item/>");
                    },
                }
            }
            try buffer.appendSlice(allocator, "</");
            try buffer.appendSlice(allocator, escaped_key);
            try buffer.append(allocator, '>');
        },
        .object => |obj| {
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            try buffer.appendSlice(allocator, "<");
            try buffer.appendSlice(allocator, escaped_key);
            try buffer.append(allocator, '>');
            var it = obj.iterator();
            while (it.next()) |entry| {
                try jsonValueToXml(allocator, buffer, entry.key_ptr.*, entry.value_ptr.*);
            }
            try buffer.appendSlice(allocator, "</");
            try buffer.appendSlice(allocator, escaped_key);
            try buffer.append(allocator, '>');
        },
        else => {
            // Defensive: any future std.json.Value variant (e.g. .number)
            // falls back to an empty self-closing element so the wrapper
            // never crashes on unexpected input.
            const escaped_key = try xmlEscape(allocator, key);
            defer allocator.free(escaped_key);
            const formatted = try std.fmt.allocPrint(allocator, "<{s}/>", .{escaped_key});
            defer allocator.free(formatted);
            try buffer.appendSlice(allocator, formatted);
        },
    }
}

