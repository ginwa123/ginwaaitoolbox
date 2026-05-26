const std = @import("std");

/// Sanitizes UTF-8 input by replacing invalid byte sequences with replacement characters.
pub fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const b = input[i];

        // ASCII (0x00-0x7F) - valid
        if (b < 0x80) {
            try result.append(allocator, b);
            i += 1;
            continue;
        }

        // Determine expected sequence length and validate
        const seq_len: usize = if (b & 0xE0 == 0xC0) 2 // 0x80-0xBF follow bytes
            else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else {
                // Invalid start byte - replacement character U+FFFD (EF BF BD)
                try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
                i += 1;
                continue;
            };

        // Check if we have enough bytes
        if (i + seq_len > input.len) {
            // Incomplete sequence - replacement character U+FFFD (EF BF BD)
            try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
            i += 1;
            continue;
        }

        // Validate all continuation bytes (0x80-0xBF)
        var valid = true;
        for (1..seq_len) |j| {
            if (input[i + j] & 0xC0 != 0x80) {
                valid = false;
                break;
            }
        }

        if (valid) {
            // Valid UTF-8 sequence
            try result.appendSlice(allocator, input[i .. i + seq_len]);
        } else {
            // Invalid sequence - replacement character U+FFFD (EF BF BD)
            try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
        }

        i += seq_len;
    }

    return result.toOwnedSlice(allocator);
}

/// Sanitize a JSON string by escaping problematic characters
/// Returns allocated slice — caller must free
pub fn sanitizeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => {
                // Already escaped? peek ahead
                if (i + 1 < input.len and (input[i + 1] == 'n' or
                    input[i + 1] == 'r' or
                    input[i + 1] == 't' or
                    input[i + 1] == '"' or
                    input[i + 1] == '\\'))
                {
                    // Valid escape sequence — keep as-is
                    try out.append(allocator, '\\');
                    try out.append(allocator, input[i + 1]);
                    i += 1;
                } else {
                    // Bare backslash — escape it
                    try out.appendSlice(allocator, "\\\\");
                }
            },
            else => try out.append(allocator, input[i]),
        }
    }

    return out.toOwnedSlice(allocator);
}

test "sanitizeUtf8 valid ASCII" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "sanitizeUtf8 valid UTF-8" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "こんにちは世界");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("こんにちは世界", result);
}

test "sanitizeUtf8 invalid start byte" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xFFworld");
    defer allocator.free(result);
    // \xFF is invalid, replaced with U+FFFD (EF BF BD)
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDworld", result);
}

test "sanitizeUtf8 incomplete sequence" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xE4world");
    defer allocator.free(result);
    // \xE4 starts a 3-byte seq but only 1 continuation byte (w=0x77, not 0x80-0xBF)
    // Invalid, replaced with U+FFFD (EF BF BD), then 'rld' remains
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDrld", result);
}

test "sanitizeUtf8 invalid continuation byte" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xE4\x90world");
    defer allocator.free(result);
    // \xE4\x90 is invalid (0x90 is not valid continuation 0x80-0xBF)
    // Replaced with U+FFFD (EF BF BD), then 'orld' remains
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDorld", result);
}
