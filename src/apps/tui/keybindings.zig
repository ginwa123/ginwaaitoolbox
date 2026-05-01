const std = @import("std");

/// Runtime-configurable keybindings loaded from JSON config file.
/// Falls back to sensible defaults if config is missing or invalid.
pub const Keybindings = struct {
    exit: u8,
    submit: u8,
    submit_alt: u8,
    backspace: u8,
    backspace_alt: u8,
    escape: u8,
    paste_start: []const u8,
    paste_end: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Keybindings) void {
        self.allocator.free(self.paste_start);
        self.allocator.free(self.paste_end);
    }
};

/// Default keybindings used when config file is missing or invalid
pub const default_keybindings = struct {
    pub const exit: u8 = 3; // Ctrl+C
    pub const submit: u8 = 13; // Enter (Carriage Return)
    pub const submit_alt: u8 = 10; // LineFeed
    pub const backspace: u8 = 8; // Backspace
    pub const backspace_alt: u8 = 127; // Delete
    pub const escape: u8 = 27; // Escape
    pub const paste_start: []const u8 = "\x1b[200~";
    pub const paste_end: []const u8 = "\x1b[201~";
};

/// Convert a human-readable key name to its byte value.
/// Returns null if the key name is not recognized.
pub fn parseKeyName(name: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, name, " \t\"");

    // Ctrl+A through Ctrl+Z (1-26) - case insensitive
    if (std.ascii.startsWithIgnoreCase(trimmed, "Ctrl+")) {
        const letter = trimmed[5..];
        if (letter.len == 1) {
            const c = std.ascii.toUpper(letter[0]);
            if (c >= 'A' and c <= 'Z') {
                return @as(u8, c - 'A' + 1);
            }
        }
        return null;
    }

    // Named keys - case insensitive
    const upper = std.mem.trim(u8, name, " \t\"");
    var upper_buf: [32]u8 = undefined;
    if (upper.len <= upper_buf.len) {
        const upper_name = std.ascii.upperString(&upper_buf, upper);
        
        if (std.mem.eql(u8, upper_name, "ENTER") or std.mem.eql(u8, upper_name, "RETURN") or std.mem.eql(u8, upper_name, "CR")) {
            return 13; // Carriage Return
        }
        if (std.mem.eql(u8, upper_name, "LINEFEED") or std.mem.eql(u8, upper_name, "LF") or std.mem.eql(u8, upper_name, "NEWLINE")) {
            return 10;
        }
        if (std.mem.eql(u8, upper_name, "BACKSPACE") or std.mem.eql(u8, upper_name, "BS")) {
            return 8;
        }
        if (std.mem.eql(u8, upper_name, "DELETE") or std.mem.eql(u8, upper_name, "DEL")) {
            return 127;
        }
        if (std.mem.eql(u8, upper_name, "ESCAPE") or std.mem.eql(u8, upper_name, "ESC")) {
            return 27;
        }
        if (std.mem.eql(u8, upper_name, "TAB")) {
            return 9;
        }
        if (std.mem.eql(u8, upper_name, "SPACE")) {
            return 32;
        }
    }

    // Numeric literal (e.g., "13")
    if (std.fmt.parseInt(u8, trimmed, 10)) |val| {
        return val;
    } else |_| {}

    return null;
}

/// Parse an escape sequence string like "\\x1b[200~" into actual bytes.
/// Handles \xNN hex escapes and literal characters.
pub fn parseEscapeSequence(allocator: std.mem.Allocator, seq: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, seq, " \t\"");
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            const next = trimmed[i + 1];
            if (next == 'x' and i + 3 < trimmed.len) {
                // \xNN hex escape
                const hex_str = trimmed[i + 2 .. i + 4];
                const val = std.fmt.parseInt(u8, hex_str, 16) catch {
                    // Invalid hex, treat as literal
                    try result.append(allocator, trimmed[i]);
                    i += 1;
                    continue;
                };
                try result.append(allocator, val);
                i += 4;
            } else if (next == 'n') {
                try result.append(allocator, '\n');
                i += 2;
            } else if (next == 'r') {
                try result.append(allocator, '\r');
                i += 2;
            } else if (next == 't') {
                try result.append(allocator, '\t');
                i += 2;
            } else if (next == '\\') {
                try result.append(allocator, '\\');
                i += 2;
            } else {
                // Unknown escape, treat as literal
                try result.append(allocator, trimmed[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, trimmed[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// JSON structure for keybindings config file
const KeybindingsConfig = struct {
    exit: ?[]const u8 = null,
    submit: ?[]const u8 = null,
    submit_alt: ?[]const u8 = null,
    backspace: ?[]const u8 = null,
    backspace_alt: ?[]const u8 = null,
    escape: ?[]const u8 = null,
    paste_start: ?[]const u8 = null,
    paste_end: ?[]const u8 = null,
};

/// Get the config file path following XDG standards: ~/.config/ginwaaitoolbox/keybindings.json
/// Caller owns the returned memory.
fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{
        "/tmp",
        ".config",
        "ginwaaitoolbox",
        "keybindings.json",
    });
}

/// Load keybindings from config file, falling back to defaults if missing or invalid.
/// Caller owns the returned Keybindings and must call deinit().
pub fn loadKeybindings(allocator: std.mem.Allocator) !Keybindings {
    const config_path = getConfigPath(allocator) catch {
        return getDefaultKeybindings(allocator);
    };
    defer allocator.free(config_path);

    // Try to read config file
    const file_content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, config_path, allocator, .limited(4096)) catch {
        return getDefaultKeybindings(allocator);
    };
    defer allocator.free(file_content);

    // Parse JSON
    var json_parsed = std.json.parseFromSlice(
        KeybindingsConfig,
        allocator,
        file_content,
        .{ .ignore_unknown_fields = true },
    ) catch {
        std.log.warn("Invalid keybindings config JSON, using defaults", .{});
        return getDefaultKeybindings(allocator);
    };
    defer json_parsed.deinit();

    const config = json_parsed.value;

    // Build keybindings from config with fallbacks to defaults
    var kb = Keybindings{
        .exit = default_keybindings.exit,
        .submit = default_keybindings.submit,
        .submit_alt = default_keybindings.submit_alt,
        .backspace = default_keybindings.backspace,
        .backspace_alt = default_keybindings.backspace_alt,
        .escape = default_keybindings.escape,
        .paste_start = try allocator.dupe(u8, default_keybindings.paste_start),
        .paste_end = try allocator.dupe(u8, default_keybindings.paste_end),
        .allocator = allocator,
    };
    errdefer kb.deinit();

    // Apply config values
    if (config.exit) |val| {
        if (parseKeyName(val)) |byte_val| kb.exit = byte_val;
    }
    if (config.submit) |val| {
        if (parseKeyName(val)) |byte_val| kb.submit = byte_val;
    }
    if (config.submit_alt) |val| {
        if (parseKeyName(val)) |byte_val| kb.submit_alt = byte_val;
    }
    if (config.backspace) |val| {
        if (parseKeyName(val)) |byte_val| kb.backspace = byte_val;
    }
    if (config.backspace_alt) |val| {
        if (parseKeyName(val)) |byte_val| kb.backspace_alt = byte_val;
    }
    if (config.escape) |val| {
        if (parseKeyName(val)) |byte_val| kb.escape = byte_val;
    }
    if (config.paste_start) |val| {
        allocator.free(kb.paste_start);
        kb.paste_start = parseEscapeSequence(allocator, val) catch default_keybindings.paste_start;
    }
    if (config.paste_end) |val| {
        allocator.free(kb.paste_end);
        kb.paste_end = parseEscapeSequence(allocator, val) catch default_keybindings.paste_end;
    }

    return kb;
}

/// Get default keybindings (used when config is missing or invalid)
fn getDefaultKeybindings(allocator: std.mem.Allocator) !Keybindings {
    return Keybindings{
        .exit = default_keybindings.exit,
        .submit = default_keybindings.submit,
        .submit_alt = default_keybindings.submit_alt,
        .backspace = default_keybindings.backspace,
        .backspace_alt = default_keybindings.backspace_alt,
        .escape = default_keybindings.escape,
        .paste_start = try allocator.dupe(u8, default_keybindings.paste_start),
        .paste_end = try allocator.dupe(u8, default_keybindings.paste_end),
        .allocator = allocator,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parseKeyName - Ctrl combinations" {
    try std.testing.expectEqual(@as(u8, 1), parseKeyName("Ctrl+A").?);
    try std.testing.expectEqual(@as(u8, 3), parseKeyName("Ctrl+C").?);
    try std.testing.expectEqual(@as(u8, 26), parseKeyName("Ctrl+Z").?);
    try std.testing.expectEqual(@as(u8, 1), parseKeyName("ctrl+a").?); // case insensitive
    try std.testing.expectEqual(@as(u8, 3), parseKeyName("CTRL+C").?); // case insensitive
}

test "parseKeyName - named keys" {
    try std.testing.expectEqual(@as(u8, 13), parseKeyName("Enter").?);
    try std.testing.expectEqual(@as(u8, 10), parseKeyName("LineFeed").?);
    try std.testing.expectEqual(@as(u8, 8), parseKeyName("Backspace").?);
    try std.testing.expectEqual(@as(u8, 127), parseKeyName("Delete").?);
    try std.testing.expectEqual(@as(u8, 27), parseKeyName("Escape").?);
    try std.testing.expectEqual(@as(u8, 9), parseKeyName("Tab").?);
    try std.testing.expectEqual(@as(u8, 32), parseKeyName("Space").?);
}

test "parseKeyName - case insensitive" {
    try std.testing.expectEqual(@as(u8, 13), parseKeyName("enter").?);
    try std.testing.expectEqual(@as(u8, 13), parseKeyName("ENTER").?);
    try std.testing.expectEqual(@as(u8, 127), parseKeyName("delete").?);
    try std.testing.expectEqual(@as(u8, 127), parseKeyName("DEL").?);
}

test "parseKeyName - numeric" {
    try std.testing.expectEqual(@as(u8, 13), parseKeyName("13").?);
    try std.testing.expectEqual(@as(u8, 27), parseKeyName("27").?);
}

test "parseKeyName - invalid" {
    try std.testing.expect(parseKeyName("InvalidKey") == null);
    try std.testing.expect(parseKeyName("Ctrl+") == null);
}

test "parseEscapeSequence" {
    const allocator = std.testing.allocator;

    const seq1 = try parseEscapeSequence(allocator, "\\x1b[200~");
    defer allocator.free(seq1);
    try std.testing.expectEqualSlices(u8, "\x1b[200~", seq1);

    const seq2 = try parseEscapeSequence(allocator, "\\x1b[201~");
    defer allocator.free(seq2);
    try std.testing.expectEqualSlices(u8, "\x1b[201~", seq2);
}

test "loadKeybindings - defaults when no config" {
    const allocator = std.testing.allocator;
    var kb = try loadKeybindings(allocator);
    defer kb.deinit();

    try std.testing.expectEqual(@as(u8, 3), kb.exit);
    try std.testing.expectEqual(@as(u8, 13), kb.submit);
    try std.testing.expectEqual(@as(u8, 10), kb.submit_alt);
    try std.testing.expectEqualSlices(u8, "\x1b[200~", kb.paste_start);
    try std.testing.expectEqualSlices(u8, "\x1b[201~", kb.paste_end);
}
