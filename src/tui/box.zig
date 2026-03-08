const std = @import("std");

// ============================================================================
// Types
// ============================================================================

/// Padding configuration for Box interior
pub const Padding = union(enum) {
    /// Same padding on all sides
    all: u16,
    /// Different horizontal vs vertical padding
    sides: struct {
        horizontal: u16,
        vertical: u16,
    },
    /// Individual padding for each side (top, right, bottom, left)
    individual: struct {
        top: u16,
        right: u16,
        bottom: u16,
        left: u16,
    },

    /// Default padding: 1 on all sides
    pub fn default() Padding {
        return .{ .all = 1 };
    }

    /// Get top padding value
    pub fn top(self: Padding) u16 {
        switch (self) {
            .all => |v| return v,
            .sides => |v| return v.vertical,
            .individual => |v| return v.top,
        }
    }

    /// Get right padding value
    pub fn right(self: Padding) u16 {
        switch (self) {
            .all => |v| return v,
            .sides => |v| return v.horizontal,
            .individual => |v| return v.right,
        }
    }

    /// Get bottom padding value
    pub fn bottom(self: Padding) u16 {
        switch (self) {
            .all => |v| return v,
            .sides => |v| return v.vertical,
            .individual => |v| return v.bottom,
        }
    }

    /// Get left padding value
    pub fn left(self: Padding) u16 {
        switch (self) {
            .all => |v| return v,
            .sides => |v| return v.horizontal,
            .individual => |v| return v.left,
        }
    }
};

/// Dimension configuration
pub const Dim = union(enum) {
    /// Auto-size based on content
    auto: void,
    /// Fixed size in characters
    fixed: u16,

    /// Default: auto
    pub fn default() Dim {
        return .{ .auto = {} };
    }
};

/// Flex direction for children layout
pub const Direction = enum {
    column, // Children stack vertically
    row, // Children placed horizontally

    pub fn default() Direction {
        return .column;
    }
};

/// Horizontal alignment (justify-content)
pub const JustifyContent = enum {
    start,
    center,
    end,
    stretch,
    space_between,
    space_around,
    space_evenly,

    pub fn default() JustifyContent {
        return .start;
    }
};

/// Vertical alignment (align-items)
pub const AlignItems = enum {
    start,
    center,
    end,
    stretch,

    pub fn default() AlignItems {
        return .start;
    }
};

/// Overflow handling
pub const Overflow = enum {
    expand, // Auto-expand to fit content
    scroll_h, // Horizontal scroll only
    scroll_v, // Vertical scroll only
    scroll_both, // Both directions
    truncate, // Cut off excess

    pub fn default() Overflow {
        return .expand;
    }
};

/// Rendered content that can be placed inside a Box
pub const RenderedContent = union(enum) {
    text: []const u8,
    box: *Box,
    list: []const RenderedContent,

    /// Check if content is empty
    pub fn isEmpty(self: RenderedContent) bool {
        switch (self) {
            .text => |t| return t.len == 0,
            .box => return false,
            .list => |l| return l.len == 0,
        }
    }
};

/// Size result after calculation
pub const Size = struct {
    width: u16,
    height: u16,
};

/// Position within the Box
pub const Position = struct {
    x: u16,
    y: u16,
};

// ============================================================================
// Unicode Box-Drawing Characters
// ============================================================================

pub const BoxChars = struct {
    top_left: []const u8 = "┌",
    top_right: []const u8 = "┐",
    bottom_left: []const u8 = "└",
    bottom_right: []const u8 = "┘",
    horizontal: []const u8 = "─",
    vertical: []const u8 = "│",
    top_t: []const u8 = "┬",
    bottom_t: []const u8 = "┴",
    left_t: []const u8 = "├",
    right_t: []const u8 = "┤",
    cross: []const u8 = "┼",
};

/// Options for configuring a Box
pub const BoxOptions = struct {
    /// Whether to draw border (default: true)
    border: bool = true,
    /// Optional title text in top border
    title: ?[]const u8 = null,
    /// Internal padding (default: 1 all sides)
    padding: Padding = .default(),
    /// Width dimension (default: auto)
    width: Dim = .default(),
    /// Height dimension (default: auto)
    height: Dim = .default(),
    /// Background fill (null = transparent)
    background: ?[]const u8 = null,
    /// Flex direction (default: column)
    direction: Direction = .default(),
    /// Horizontal alignment (default: start)
    justify_content: JustifyContent = .default(),
    /// Vertical alignment (default: start)
    align_items: AlignItems = .default(),
    /// Overflow handling (default: expand)
    overflow: Overflow = .default(),
};

/// A Box is like a div in HTML - a container that can hold content and render borders
pub const Box = struct {
    allocator: std.mem.Allocator,
    options: BoxOptions,
    /// Render function that returns the content to display inside this Box
    children: *const fn () RenderedContent,
    /// Computed inner dimensions (after border and padding)
    inner_width: u16 = 0,
    /// Computed inner dimensions (after border and padding)
    inner_height: u16 = 0,
    /// Current scroll offset for overflow handling
    scroll_x: u16 = 0,
    /// Current scroll offset for overflow handling
    scroll_y: u16 = 0,

    /// Create a new Box with the given options and children render function
    pub fn init(allocator: std.mem.Allocator, options: BoxOptions, children: *const fn () RenderedContent) !*Box {
        const box = try allocator.create(Box);
        box.* = .{
            .allocator = allocator,
            .options = options,
            .children = children,
        };
        return box;
    }

    /// Destroy a Box and free its memory
    pub fn destroy(box: *Box) void {
        box.allocator.destroy(box);
    }

    /// Get the title string, or empty if no title
    pub fn getTitle(box: *Box) []const u8 {
        return box.options.title orelse "";
    }

    /// Check if this Box has a title
    pub fn hasTitle(box: *Box) bool {
        return box.options.title != null;
    }

    /// Get the border width (1 if border enabled, 0 otherwise)
    pub fn borderWidth(box: *Box) u16 {
        return if (box.options.border) 1 else 0;
    }

    /// Get total horizontal padding
    pub fn paddingHorizontal(box: *Box) u16 {
        return box.options.padding.left() + box.options.padding.right();
    }

    /// Get total vertical padding
    pub fn paddingVertical(box: *Box) u16 {
        return box.options.padding.top() + box.options.padding.bottom();
    }

    /// Calculate the rendered size of content
    fn measureContent(box: *Box, content: RenderedContent) Size {
        switch (content) {
            .text => |t| {
                // Calculate width as longest line, height as line count
                var max_width: u16 = 0;
                var height: u16 = 1;
                var line_start: usize = 0;
                var i: usize = 0;
                while (i <= t.len) : (i += 1) {
                    if (i == t.len or t[i] == '\n') {
                        const line_len = i - line_start;
                        if (line_len > max_width) max_width = @truncate(line_len);
                        if (i < t.len) height += 1;
                        line_start = i + 1;
                    }
                }
                return Size{ .width = max_width, .height = height };
            },
            .box => |b| {
                return box.calculateSize(b);
            },
            .list => |list| {
                if (list.len == 0) {
                    return Size{ .width = 0, .height = 0 };
                }
                switch (box.options.direction) {
                    .column => {
                        var total_width: u16 = 0;
                        var total_height: u16 = 0;
                        for (list) |item| {
                            const item_size = box.measureContent(item);
                            total_width = @max(total_width, item_size.width);
                            total_height += item_size.height;
                        }
                        return Size{ .width = total_width, .height = total_height };
                    },
                    .row => {
                        var total_width: u16 = 0;
                        var total_height: u16 = 0;
                        for (list) |item| {
                            const item_size = box.measureContent(item);
                            total_width += item_size.width;
                            total_height = @max(total_height, item_size.height);
                        }
                        return Size{ .width = total_width, .height = total_height };
                    },
                }
            },
        }
    }

    /// Calculate the Box's size based on options and content
    pub fn calculateSize(box: *Box, child: ?*Box) Size {
        _ = child; // Reserved for future nested box calculation
        const content = box.children();
        const content_size = box.measureContent(content);

        const border_w = box.borderWidth();
        const pad_h = box.paddingHorizontal();
        const pad_v = box.paddingVertical();

        // Calculate required size from content
        const required_width = content_size.width + pad_h + (border_w * 2);
        const required_height = content_size.height + pad_v + (border_w * 2);

        // Apply dimension settings
        const width: u16 = switch (box.options.width) {
            .auto => required_width,
            .fixed => |w| w,
        };
        const height: u16 = switch (box.options.height) {
            .auto => required_height,
            .fixed => |h| h,
        };

        // Store inner dimensions
        box.inner_width = if (width > border_w * 2 + pad_h) width - border_w * 2 - pad_h else 0;
        box.inner_height = if (height > border_w * 2 + pad_v) height - border_w * 2 - pad_v else 0;

        return Size{ .width = width, .height = height };
    }

    /// Calculate horizontal position for content based on justify_content
    fn calcX(box: *Box, content_width: u16, available_width: u16) u16 {
        const pad_left = box.options.padding.left();
        const border_w = box.borderWidth();

        switch (box.options.justify_content) {
            .start => return border_w + pad_left,
            .center => {
                const remaining = available_width - content_width;
                return border_w + pad_left + (remaining / 2);
            },
            .end => {
                return available_width - border_w - pad_left - content_width;
            },
            .stretch, .space_between, .space_around, .space_evenly => {
                return border_w + pad_left;
            },
        }
    }

    /// Calculate vertical position for content based on align_items
    fn calcY(box: *Box, content_height: u16, available_height: u16) u16 {
        const pad_top = box.options.padding.top();
        const border_w = box.borderWidth();

        switch (box.options.align_items) {
            .start => return border_w + pad_top,
            .center => {
                const remaining = available_height - content_height;
                return border_w + pad_top + (remaining / 2);
            },
            .end => {
                return available_height - border_w - pad_top - content_height;
            },
            .stretch => {
                return border_w + pad_top;
            },
        }
    }

    /// Render the box to an output buffer and return lines
    /// Caller owns the returned array list
    pub fn render(box: *Box, out: *std.ArrayList([]u8)) !void {
        const size = box.calculateSize(null);
        const width = size.width;
        const height = size.height;

        // Create buffer for each line
        const border_w = box.borderWidth();

        // Draw top border
        if (box.options.border) {
            try box.renderTopBorder(width, out);
        }

        // Draw content area
        const content = box.children();
        const content_size = box.measureContent(content);

        const inner_start_y = border_w + box.options.padding.top();
        const pad_h = box.paddingHorizontal();
        const pad_v = box.paddingVertical();
        const inner_width = if (width > border_w * 2 + pad_h) width - border_w * 2 - pad_h else 0;
        const inner_height = if (height > border_w * 2 + pad_v) height - border_w * 2 - pad_v else 0;

        const chars = BoxChars{};
        // Render each line
        var y: u16 = 0;
        while (y < height) : (y += 1) {
            var line = std.ArrayList(u8){};
            errdefer line.deinit(box.allocator);

            // Left border
            if (box.options.border) {
                try line.appendSlice(box.allocator, chars.vertical);
            }

            // Padding (need both left and right for calculations below)
            const pad_left = box.options.padding.left();
            const pad_right = box.options.padding.right();
            
            if (pad_left > 0) {
                try line.appendNTimes(box.allocator, ' ', pad_left);
            }

            // Fill or render content
            if (y >= inner_start_y and y < inner_start_y + inner_height) {
                const content_y = y - inner_start_y;
                const is_content_line = content_y < content_size.height;

                // Pad to inner width
                const fill_width = inner_width;

                if (is_content_line) {
                    // Render the content line
                    try box.renderContentLine(content, content_y, fill_width, box.allocator, &line);
                } else {
                    // Empty padding area
                    try line.appendNTimes(box.allocator, ' ', fill_width);
                }
            } else {
                // Fill the space between left padding and right border
                const border_adjustment: u16 = if (box.options.border) 1 else 0; const middle_space = width - pad_left - pad_right - border_w - border_adjustment;
                try line.appendNTimes(box.allocator, ' ', middle_space);
            }

            // Right padding
            if (pad_right > 0) {
                try line.appendNTimes(box.allocator, ' ', pad_right);
            }

            // Right border
            if (box.options.border) {
                try line.appendSlice(box.allocator, chars.vertical);
            }

            try out.append(box.allocator, try line.toOwnedSlice(box.allocator));
        }

        // Draw bottom border
        if (box.options.border) {
            try box.renderBottomBorder(width, out);
        }
    }

    /// Render top border line with optional title
    fn renderTopBorder(box: *Box, width: u16, out: *std.ArrayList([]u8)) !void {
        var line = std.ArrayList(u8){};
        errdefer line.deinit(box.allocator);

        const chars = BoxChars{};

        // Top-left corner
        try line.appendSlice(box.allocator, chars.top_left);

        if (box.options.title) |title| {
            // Title takes position after top-left corner
            const title_len: u16 = @truncate(title.len);
            const remaining = if (width > 2 + title_len) width - 2 - title_len else 0;
            const left_half = remaining / 2;
            const right_half = remaining - left_half;

            // Left horizontal
            for (0..left_half) |_| {
                try line.appendSlice(box.allocator, chars.horizontal);
            }

            // Title
            try line.appendSlice(box.allocator, title);

            // Right horizontal
            for (0..right_half) |_| {
                try line.appendSlice(box.allocator, chars.horizontal);
            }
        } else {
            // Full horizontal line
            if (width > 2) {
                for (0..width - 2) |_| {
                    try line.appendSlice(box.allocator, chars.horizontal);
                }
            }
        }

        // Top-right corner
        try line.appendSlice(box.allocator, chars.top_right);

        try out.append(box.allocator, try line.toOwnedSlice(box.allocator));
    }

    /// Render bottom border line
    fn renderBottomBorder(box: *Box, width: u16, out: *std.ArrayList([]u8)) !void {
        var line = std.ArrayList(u8){};
        errdefer line.deinit(box.allocator);

        const chars = BoxChars{};

        try line.appendSlice(box.allocator, chars.bottom_left);
        if (width > 2) {
            for (0..width - 2) |_| {
                try line.appendSlice(box.allocator, chars.horizontal);
            }
        }
        try line.appendSlice(box.allocator, chars.bottom_right);

        try out.append(box.allocator, try line.toOwnedSlice(box.allocator));
    }

    /// Render a single line of content within the available width
    fn renderContentLine(box: *Box, content: RenderedContent, line_idx: u16, available_width: u16, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (content) {
            .text => |text| {
                // Find the specific line in the text
                var current_line: u16 = 0;
                var line_start: usize = 0;
                var i: usize = 0;

                while (i <= text.len) : (i += 1) {
                    if (i == text.len or text[i] == '\n') {
                        if (current_line == line_idx) {
                            const line_len = i - line_start;
                            const copy_len = @min(line_len, available_width);
                            if (copy_len > 0) {
                                try out.appendSlice(allocator, text[line_start..line_start + copy_len]);
                            }
                            // Pad remaining space
                            if (copy_len < available_width) {
                                try out.appendNTimes(allocator, ' ', available_width - copy_len);
                            }
                            return;
                        }
                        current_line += 1;
                        line_start = i + 1;
                    }
                }
                // Line not found, fill with spaces
                try out.appendNTimes(allocator, ' ', available_width);
            },
            .box => |child_box| {
                // Render child box (simplified - just render its content)
                _ = child_box;
                try out.appendNTimes(allocator, ' ', available_width);
            },
            .list => |list| {
                // Render list of items
                var x_offset: u16 = 0;
                for (list) |item| {
                    const item_size = box.measureContent(item);
                    if (line_idx < item_size.height) {
                        try box.renderContentLine(item, line_idx, @min(item_size.width, available_width - x_offset), box.allocator, out);
                    }
                    x_offset += item_size.width;
                    if (x_offset >= available_width) break;
                }
                // Fill remaining
                if (x_offset < available_width) {
                    try out.appendNTimes(allocator, ' ', available_width - x_offset);
                }
            },
        }
    }

    /// Quick helper to render a box and get the output string
    pub fn renderToString(box: *Box) ![]u8 {
        var lines = std.ArrayList([]u8){};
        errdefer {
            for (lines.items) |line| {
                box.allocator.free(line);
            }
            lines.deinit(box.allocator);
        }

        try box.render(&lines);

        // Join lines with newlines
        var total_len: usize = 0;
        for (lines.items) |line| {
            total_len += line.len + 1; // +1 for newline
        }

        var result = try box.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (lines.items) |line| {
            @memcpy(result[pos..pos + line.len], line);
            pos += line.len;
            result[pos] = '\n';
            pos += 1;
        }

        // Free the lines array after building result
        for (lines.items) |line| {
            box.allocator.free(line);
        }
        lines.deinit(box.allocator);

        return result;
    }
};
