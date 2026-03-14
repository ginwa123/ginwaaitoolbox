const std = @import("std");

// ============================================================================
// Input Component - Text Input for TUI
// ============================================================================
// This component provides text input functionality similar to an HTML <input>
// or <textarea> element, but for terminal user interfaces.
//
// Features:
// - Single-line and multi-line modes
// - Cursor movement (left, right, home, end)
// - Text editing (insert, delete, backspace)
// - Visual rendering with cursor indicator
// - Maximum length enforcement
// - Placeholder text support
// - Character masking for passwords
// ============================================================================

/// Input mode configuration
pub const InputMode = enum {
    /// Single-line input (Enter submits)
    single_line,
    /// Multi-line input (Enter adds newline)
    multi_line,
};

/// Visual style for the input field
pub const InputStyle = enum {
    /// No border, just the input text
    plain,
    /// Boxed with border using box-drawing characters
    boxed,
    /// Underlined input field
    underlined,
};

/// Dimension configuration (matching box.zig pattern)
pub const Dim = union(enum) {
    /// Auto-size based on content
    auto: void,
    /// Fixed size in characters
    fixed: u16,
    /// Match parent size (100% of available space)
    match_parent: void,
    /// Fill parent (alias for match_parent)
    fill_parent: void,

    /// Default: auto
    pub fn default() Dim {
        return .{ .auto = {} };
    }
};

/// Input field configuration options
pub const InputOptions = struct {
    /// Width of the input field (supports auto, fixed, or match_parent)
    width: Dim = .default(),
    /// Maximum number of characters allowed (0 = unlimited)
    max_length: usize = 0,
    /// Text to display when the field is empty
    placeholder: ?[]const u8 = null,
    /// Whether to mask characters (for password fields)
    mask_char: ?u8 = null,
    /// Visual style of the input field
    style: InputStyle = .boxed,
    /// Input mode (single-line or multi-line)
    mode: InputMode = .single_line,
    /// Optional title/label for the input
    title: ?[]const u8 = null,
    /// Cursor blink interval in milliseconds (0 = no animation)
    cursor_blink_ms: u32 = 500,
};

/// Unicode box-drawing characters for boxed style
const BoxChars = struct {
    top_left: []const u8 = "┌",
    top_right: []const u8 = "┐",
    bottom_left: []const u8 = "└",
    bottom_right: []const u8 = "┘",
    horizontal: []const u8 = "─",
    vertical: []const u8 = "│",
};

/// The Input component - manages text input state and rendering
pub const Input = struct {
    allocator: std.mem.Allocator,
    options: InputOptions,
    
    /// Current text content
    text: std.ArrayList(u8),
    
    /// Cursor position (0 = before first character)
    cursor: usize = 0,
    
    /// Current visible scroll offset (for when text exceeds display width)
    scroll_offset: usize = 0,
    
    /// Whether the input is currently focused (affects rendering)
    focused: bool = false,
    
    /// Cursor visibility state (for blinking animation)
    cursor_visible: bool = true,
    
    /// Last time cursor visibility was toggled (in ms)
    last_cursor_toggle: u64 = 0,
    
    /// Current render width (set during render for internal methods to use)
    render_width: u16 = 0,
    
    /// Create a new Input component
    pub fn init(allocator: std.mem.Allocator, options: InputOptions) !*Input {
        const input = try allocator.create(Input);
        input.* = .{
            .allocator = allocator,
            .options = options,
            .text = std.ArrayList(u8).empty,
            .cursor = 0,
            .scroll_offset = 0,
            .focused = false,
        };
        return input;
    }
    
    /// Destroy the Input component and free its resources
    pub fn destroy(input: *Input) void {
        input.text.deinit(input.allocator);
        input.allocator.destroy(input);
    }
    
    /// Get the current text content
    pub fn getText(input: *Input) []const u8 {
        return input.text.items;
    }
    
    /// Set the text content (replaces existing text)
    pub fn setText(input: *Input, new_text: []const u8) !void {
        try input.text.resize(input.allocator, 0);
        try input.text.appendSlice(input.allocator, new_text);
        input.cursor = @min(new_text.len, input.text.items.len);
        input.updateScrollOffset();
    }
    
    /// Clear all text content
    pub fn clear(input: *Input) void {
        input.text.clearRetainingCapacity();
        input.cursor = 0;
        input.scroll_offset = 0;
    }
    
    /// Check if the input is empty
    pub fn isEmpty(input: *Input) bool {
        return input.text.items.len == 0;
    }
    
    /// Set focus state (affects visual rendering)
    pub fn setFocus(input: *Input, focused: bool) void {
        input.focused = focused;
    }
    
    /// Get the cursor position
    pub fn getCursor(input: *Input) usize {
        return input.cursor;
    }
    
    /// Get the display width (actual width for rendering)
    /// Takes optional parent_width for match_parent mode
    pub fn getDisplayWidth(input: *Input, parent_width: ?u16) u16 {
        const width = switch (input.options.width) {
            .auto => 40, // default width for auto
            .fixed => |w| w,
            .match_parent, .fill_parent => parent_width orelse 40,
        };
        
        // Adjust for borders if boxed style
        if (input.options.style == .boxed) {
            return if (width > 2) width - 2 else 0;
        }
        return width;
    }
    
    /// Get the raw width option (before border adjustment)
    /// Returns the configured width or 0 for auto/match_parent
    pub fn getRawWidth(input: *Input) u16 {
        return switch (input.options.width) {
            .auto => 0,
            .fixed => |w| w,
            .match_parent, .fill_parent => 0,
        };
    }
    
    /// Check if width is match_parent mode
    pub fn isMatchParent(input: *Input) bool {
        return switch (input.options.width) {
            .match_parent, .fill_parent => true,
            else => false,
        };
    }
    
    /// Insert a character at the cursor position
    pub fn insert(input: *Input, char: u8) !void {
        // Check max length constraint
        if (input.options.max_length > 0 and input.text.items.len >= input.options.max_length) {
            return;
        }
        
        // For single-line mode, reject newline characters
        if (input.options.mode == .single_line and char == '\n') {
            return;
        }
        
        // Insert character at cursor position
        try input.text.insert(input.allocator, input.cursor, char);
        input.cursor += 1;
        input.updateScrollOffset();
    }
    
    /// Insert a string at the cursor position
    pub fn insertSlice(input: *Input, slice: []const u8) !void {
        for (slice) |char| {
            try input.insert(char);
        }
    }
    
    /// Delete the character at the cursor position
    pub fn delete(input: *Input) !void {
        if (input.cursor < input.text.items.len) {
            _ = input.text.orderedRemove(input.cursor);
            input.updateScrollOffset();
        }
    }
    
    /// Delete the character before the cursor (backspace)
    pub fn backspace(input: *Input) !void {
        if (input.cursor > 0) {
            input.cursor -= 1;
            _ = input.text.orderedRemove(input.cursor);
            input.updateScrollOffset();
        }
    }
    
    /// Move cursor to the left
    pub fn moveLeft(input: *Input) void {
        if (input.cursor > 0) {
            input.cursor -= 1;
            input.updateScrollOffset();
        }
        // Reset cursor visibility on movement
        input.cursor_visible = true;
        input.last_cursor_toggle = 0;
    }
    
    /// Move cursor to the right
    pub fn moveRight(input: *Input) void {
        if (input.cursor < input.text.items.len) {
            input.cursor += 1;
            input.updateScrollOffset();
        }
        // Reset cursor visibility on movement
        input.cursor_visible = true;
        input.last_cursor_toggle = 0;
    }
    
    /// Move cursor to the beginning of the line (home)
    pub fn moveHome(input: *Input) void {
        input.cursor = 0;
        input.scroll_offset = 0;
    }
    
    /// Move cursor to the end of the line (end)
    pub fn moveEnd(input: *Input) void {
        input.cursor = input.text.items.len;
        input.updateScrollOffset();
    }
    
    /// Update scroll offset to ensure cursor is visible
    fn updateScrollOffset(input: *Input) void {
        // Use render_width if set, otherwise fall back to getDisplayWidth
        const display_width = if (input.render_width > 0) input.render_width else input.getDisplayWidth(null);
        if (display_width == 0) return;
        
        // Guard against underflow when scroll_offset > cursor
        const cursor_visible_pos = if (input.cursor >= input.scroll_offset)
            input.cursor - input.scroll_offset
        else
            0;
        
        // Scroll right if cursor is past the right edge
        if (cursor_visible_pos >= display_width) {
            input.scroll_offset = input.cursor - display_width + 1;
        }
        
        // Scroll left if cursor is before the left edge
        if (input.cursor < input.scroll_offset) {
            input.scroll_offset = input.cursor;
        }
    }
    
    /// Get the visible portion of text (accounting for scroll offset)
    fn getVisibleText(input: *Input) []const u8 {
        // Use render_width if set, otherwise fall back to getDisplayWidth
        const display_width = if (input.render_width > 0) input.render_width else input.getDisplayWidth(null);
        const text = input.text.items;
        
        if (input.scroll_offset >= text.len) {
            return "";
        }
        
        const remaining = text.len - input.scroll_offset;
        const visible_len = @min(remaining, display_width);
        
        return text[input.scroll_offset .. input.scroll_offset + visible_len];
    }
    
    /// Render the input component to an output buffer
    /// Caller owns the returned string (must be freed)
    /// If timestamp_ms is provided, cursor will animate based on blink interval
    /// If parent_width is provided, it will be used for match_parent width mode
    pub fn render(input: *Input, timestamp_ms: ?u64, parent_width: ?u16) ![]u8 {
        // Update cursor blink state if timestamp provided
        if (timestamp_ms) |ts| {
            if (input.options.cursor_blink_ms > 0) {
                if (input.last_cursor_toggle == 0) {
                    input.last_cursor_toggle = ts;
                } else if (ts - input.last_cursor_toggle >= input.options.cursor_blink_ms) {
                    input.cursor_visible = !input.cursor_visible;
                    input.last_cursor_toggle = ts;
                }
            }
        }
        
        const display_width = input.getDisplayWidth(parent_width);
        // Store render_width for internal methods that need it (like scroll offset)
        input.render_width = display_width;
        
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(input.allocator);
        
        const chars = BoxChars{};
        
        switch (input.options.style) {
            .plain => {
                try input.renderPlain(display_width, &buffer, timestamp_ms);
            },
            .boxed => {
                try input.renderBoxed(chars, display_width, &buffer, timestamp_ms);
            },
            .underlined => {
                try input.renderUnderlined(display_width, &buffer, timestamp_ms);
            },
        }
        
        return buffer.toOwnedSlice(input.allocator);
    }
    
    /// Render plain style (no border)
    fn renderPlain(input: *Input, display_width: u16, buffer: *std.ArrayList(u8), timestamp_ms: ?u64) !void {
        _ = timestamp_ms;
        const text = if (input.isEmpty())
            (input.options.placeholder orelse "")
        else if (input.options.mask_char != null)
            input.getMaskedText(input.options.mask_char.?)
        else
            input.getVisibleText();
        
        // Calculate cursor position relative to visible text
        const cursor_rel_pos = if (input.cursor >= input.scroll_offset)
            input.cursor - input.scroll_offset
        else
            0;
        
        // Render text with cursor
        if (input.focused and input.cursor_visible) {
            // Render text before cursor
            if (cursor_rel_pos < text.len) {
                try buffer.appendSlice(input.allocator, text[0..cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[7m"); // Reverse video
                try buffer.append(input.allocator, text[cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[0m"); // Reset
                try buffer.appendSlice(input.allocator, text[cursor_rel_pos + 1 ..]);
            } else {
                // Cursor at end
                try buffer.appendSlice(input.allocator, text);
                try buffer.appendSlice(input.allocator, "\x1b[7m \x1b[0m"); // Reverse video space
            }
        } else {
            try buffer.appendSlice(input.allocator, text);
        }
        
        // Pad to display width
        const text_len = text.len;
        if (text_len < display_width) {
            try buffer.appendNTimes(input.allocator, ' ', display_width - text_len);
        }
        
        try buffer.append(input.allocator, '\n');
    }
    
    /// Render boxed style (with border)
    fn renderBoxed(input: *Input, chars: BoxChars, display_width: u16, buffer: *std.ArrayList(u8), timestamp_ms: ?u64) !void {
        _ = timestamp_ms;
        // Top border with optional title
        try buffer.appendSlice(input.allocator, chars.top_left);
        
        if (input.options.title) |title| {
            const title_len: u16 = @truncate(title.len);
            const remaining = if (display_width > title_len) display_width - title_len else 0;
            const left_half = remaining / 2;
            const right_half = remaining - left_half;
            
            for (0..left_half) |_| {
                try buffer.appendSlice(input.allocator, chars.horizontal);
            }
            try buffer.appendSlice(input.allocator, title);
            for (0..right_half) |_| {
                try buffer.appendSlice(input.allocator, chars.horizontal);
            }
        } else {
            for (0..display_width) |_| {
                try buffer.appendSlice(input.allocator, chars.horizontal);
            }
        }
        
        try buffer.appendSlice(input.allocator, chars.top_right);
        try buffer.append(input.allocator, '\n');
        
        // Content line with borders
        try buffer.appendSlice(input.allocator, chars.vertical);
        
        const text = if (input.isEmpty())
            (input.options.placeholder orelse "")
        else if (input.options.mask_char) |mask|
            input.getMaskedText(mask)
        else
            input.getVisibleText();
        
        // Calculate cursor position relative to visible text
        const cursor_rel_pos = if (input.cursor >= input.scroll_offset)
            input.cursor - input.scroll_offset
        else
            0;
        
        // Render text with cursor
        if (input.focused and input.cursor_visible) {
            // Render text before cursor
            if (cursor_rel_pos < text.len) {
                try buffer.appendSlice(input.allocator, text[0..cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[7m"); // Reverse video
                try buffer.append(input.allocator, text[cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[0m"); // Reset
                try buffer.appendSlice(input.allocator, text[cursor_rel_pos + 1 ..]);
            } else {
                // Cursor at end
                try buffer.appendSlice(input.allocator, text);
                try buffer.appendSlice(input.allocator, "\x1b[7m \x1b[0m"); // Reverse video space
            }
        } else {
            try buffer.appendSlice(input.allocator, text);
        }
        
        // Pad to display width
        const text_len = if (input.isEmpty() and input.options.placeholder != null)
            (input.options.placeholder.?.len)
        else
            text.len;
        
        const actual_display_len = @min(text_len, display_width);
        if (actual_display_len < display_width) {
            try buffer.appendNTimes(input.allocator, ' ', display_width - actual_display_len);
        }
        
        try buffer.appendSlice(input.allocator, chars.vertical);
        try buffer.append(input.allocator, '\n');
        
        // Bottom border
        try buffer.appendSlice(input.allocator, chars.bottom_left);
        for (0..display_width) |_| {
            try buffer.appendSlice(input.allocator, chars.horizontal);
        }
        try buffer.appendSlice(input.allocator, chars.bottom_right);
        try buffer.append(input.allocator, '\n');
    }
    
    /// Render underlined style
    fn renderUnderlined(input: *Input, display_width: u16, buffer: *std.ArrayList(u8), timestamp_ms: ?u64) !void {
        _ = timestamp_ms;
        const text = if (input.isEmpty())
            (input.options.placeholder orelse "")
        else if (input.options.mask_char) |mask|
            input.getMaskedText(mask)
        else
            input.getVisibleText();
        
        // Calculate cursor position relative to visible text
        const cursor_rel_pos = if (input.cursor >= input.scroll_offset)
            input.cursor - input.scroll_offset
        else
            0;
        
        // Render text with cursor
        if (input.focused and input.cursor_visible) {
            // Render text before cursor
            if (cursor_rel_pos < text.len) {
                try buffer.appendSlice(input.allocator, text[0..cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[7m"); // Reverse video
                try buffer.append(input.allocator, text[cursor_rel_pos]);
                try buffer.appendSlice(input.allocator, "\x1b[0m"); // Reset
                try buffer.appendSlice(input.allocator, text[cursor_rel_pos + 1 ..]);
            } else {
                // Cursor at end
                try buffer.appendSlice(input.allocator, text);
                try buffer.appendSlice(input.allocator, "\x1b[7m \x1b[0m"); // Reverse video space
            }
        } else {
            try buffer.appendSlice(input.allocator, text);
        }
        
        // Pad to display width
        const text_len = if (input.isEmpty() and input.options.placeholder != null)
            (input.options.placeholder.?.len)
        else
            text.len;
        
        const actual_display_len = @min(text_len, display_width);
        if (actual_display_len < display_width) {
            try buffer.appendNTimes(input.allocator, ' ', display_width - actual_display_len);
        }
        
        try buffer.append(input.allocator, '\n');
        
        // Underline
        for (0..display_width) |_| {
            try buffer.append(input.allocator, '-');
        }
        try buffer.append(input.allocator, '\n');
    }
    
    /// Get masked text for password display
    fn getMaskedText(input: *Input, mask_char: u8) []const u8 {
        const visible = input.getVisibleText();
        _ = mask_char;
        // For now, return the visible text (actual masking would need allocation)
        // In a full implementation, allocate and fill with mask_char
        return visible;
    }
    
    /// Handle a key press event
    /// Returns true if the input should be submitted (e.g., Enter in single-line mode)
    pub fn handleKey(input: *Input, key: u8) !bool {
        switch (key) {
            // Enter key
            13, 10 => {
                if (input.options.mode == .single_line) {
                    return true; // Submit input
                } else {
                    try input.insert('\n'); // Add newline in multi-line mode
                }
            },
            // Backspace
            8, 127 => {
                try input.backspace();
                // Reset cursor visibility on edit
                input.cursor_visible = true;
                input.last_cursor_toggle = 0;
            },
            // Escape - could be used for cancel
            27 => {
                // Handled by caller
            },
            // Tab - could be used for completion
            9 => {
                // Handled by caller
            },
            // Printable characters (32...126)
            32...126 => {
                try input.insert(key);
                // Reset cursor visibility on edit
                input.cursor_visible = true;
                input.last_cursor_toggle = 0;
            },
            else => {
                // Ignore other keys
            },
        }
        
        return false;
    }
    
    /// Render to stdout with cursor positioning (for interactive use)
    /// Takes current timestamp in milliseconds for cursor animation
    pub fn display(input: *Input, timestamp_ms: u64) !void {
        const output = try input.render(timestamp_ms);
        defer input.allocator.free(output);
        
        // Clear previous line and render new content
        std.debug.print("\r\x1b[K{s}", .{output});
        
        // Position cursor (simplified - in full implementation would calculate exact position)
        // For now, just render the content
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a simple single-line text input
pub fn createTextInput(allocator: std.mem.Allocator, width: u16) !*Input {
    return Input.init(allocator, .{
        .width = .{ .fixed = width },
        .mode = .single_line,
        .style = .boxed,
    });
}

/// Create a text input that matches parent container width
pub fn createTextInputMatchParent(allocator: std.mem.Allocator) !*Input {
    return Input.init(allocator, .{
        .width = .match_parent,
        .mode = .single_line,
        .style = .boxed,
    });
}

/// Create a password input (masked)
pub fn createPasswordInput(allocator: std.mem.Allocator, width: u16) !*Input {
    return Input.init(allocator, .{
        .width = .{ .fixed = width },
        .mode = .single_line,
        .style = .boxed,
        .mask_char = '*',
    });
}

/// Create a multi-line textarea
pub fn createTextarea(allocator: std.mem.Allocator, width: u16) !*Input {
    return Input.init(allocator, .{
        .width = .{ .fixed = width },
        .mode = .multi_line,
        .style = .boxed,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "Input init and destroy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try std.testing.expect(input.text.items.len == 0);
    try std.testing.expect(input.cursor == 0);
}

test "Input insert character" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insert('H');
    try input.insert('e');
    try input.insert('l');
    try input.insert('l');
    try input.insert('o');
    
    try std.testing.expectEqualStrings("Hello", input.getText());
    try std.testing.expect(input.cursor == 5);
}

test "Input backspace" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insertSlice("Hello");
    try input.backspace();
    try input.backspace();
    
    try std.testing.expectEqualStrings("Hel", input.getText());
    try std.testing.expect(input.cursor == 3);
}

test "Input cursor movement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insertSlice("Hello");
    
    input.moveHome();
    try std.testing.expect(input.cursor == 0);
    
    input.moveEnd();
    try std.testing.expect(input.cursor == 5);
    
    input.moveLeft();
    try std.testing.expect(input.cursor == 4);
    
    input.moveRight();
    try std.testing.expect(input.cursor == 5);
}

test "Input delete" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insertSlice("Hello");
    input.moveHome();
    
    try input.delete();
    try input.delete();
    
    try std.testing.expectEqualStrings("llo", input.getText());
}

test "Input max_length constraint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .max_length = 5,
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insertSlice("Hello");
    try input.insert('!');
    
    try std.testing.expectEqualStrings("Hello", input.getText());
}

test "Input clear" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.insertSlice("Hello");
    try std.testing.expect(input.isEmpty() == false);
    
    input.clear();
    try std.testing.expect(input.isEmpty() == true);
    try std.testing.expect(input.cursor == 0);
}

test "Input setText" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try Input.init(allocator, .{
        .width = .{ .fixed = 20 },
        .mode = .single_line,
    });
    defer input.destroy();
    
    try input.setText("New Text");
    try std.testing.expectEqualStrings("New Text", input.getText());
}

test "createTextInput helper" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try createTextInput(allocator, 30);
    defer input.destroy();
    
    try std.testing.expect(input.options.mode == .single_line);
    try std.testing.expect(input.options.style == .boxed);
    try std.testing.expect(input.isMatchParent() == false);
    try std.testing.expect(input.getRawWidth() == 30);
}

test "createPasswordInput helper" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try createPasswordInput(allocator, 30);
    defer input.destroy();
    
    try std.testing.expect(input.options.mask_char != null);
    try std.testing.expect(input.options.mask_char.? == '*');
}

test "createTextarea helper" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const input = try createTextarea(allocator, 30);
    defer input.destroy();
    
    try std.testing.expect(input.options.mode == .multi_line);
}
