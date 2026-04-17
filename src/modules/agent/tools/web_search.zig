const std = @import("std");
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const WebSearchInput = schemas.WebSearchInput;
const WebSearchResult = schemas.WebSearchResult;
const AgentTool = schemas.AgentTool;

/// Execute a web browser action using agent-browser CLI
pub fn execute_web_search(allocator: std.mem.Allocator, input: WebSearchInput) !WebSearchResult {
    var command = std.ArrayList(u8).empty;
    errdefer command.deinit(allocator);

    try command.appendSlice(allocator, "agent-browser ");

    // Determine action - default to "open" if no action specified
    const action = if (input.action.len > 0) input.action else "open";
    try command.appendSlice(allocator, action);

    // Handle query-based search (search engine lookup)
    if (input.query) |query| {
        try command.append(allocator, ' ');

        // Encode the query for URL
        const encoded_query = try urlEncode(allocator, query);
        defer allocator.free(encoded_query);

        // Build Google search URL and open it
        const google_url = try std.fmt.allocPrint(allocator, "https://www.google.com/search?q={s}", .{encoded_query});
        defer allocator.free(google_url);
        try command.appendSlice(allocator, google_url);
    }
    // Handle direct URL navigation
    else if (input.url.len > 0) {
        try command.append(allocator, ' ');
        try command.appendSlice(allocator, input.url);

        // Add selector for element-specific actions (click, fill, etc.)
        if (input.selector) |sel| {
            try command.append(allocator, ' ');
            try command.appendSlice(allocator, sel);
        }

        // Add additional arguments for specialized actions
        if (input.args) |args| {
            try command.append(allocator, ' ');
            try command.appendSlice(allocator, args);
        }
    }
    // No query or URL - just return help/info
    else if (std.mem.eql(u8, action, "help") or std.mem.eql(u8, action, "--help")) {
        // Just return help text
        return WebSearchResult{
            .success = true,
            .content = try allocator.dupe(u8, "Use web_search with query or url parameter"),
            .exit_code = 0,
            .error_msg = null,
        };
    }

    const cmd_str = try command.toOwnedSlice(allocator);
    defer allocator.free(cmd_str);

    const bashInput = BashInput{
        .command = cmd_str,
        .cwd = input.cwd orelse "/tmp",
        .max_output = 1024 * 1024, // 1MB for page content
    };

    const result = try bashMod.execute_bash(allocator, bashInput);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    // For "open" action with query, also get the page snapshot
    if (input.query != null and std.mem.eql(u8, action, "open") and result.exit_code == 0) {
        const snapshot_cmd = "agent-browser snapshot";

        const snapshotInput = BashInput{
            .command = snapshot_cmd,
            .cwd = input.cwd orelse "/tmp",
            .max_output = 1024 * 1024,
        };

        const snapshotResult = bashMod.execute_bash(allocator, snapshotInput) catch {
            // If snapshot fails, return the open result
            return WebSearchResult{
                .success = result.exit_code == 0,
                .content = try allocator.dupe(u8, result.stdout),
                .exit_code = result.exit_code,
                .error_msg = if (result.stderr.len > 0 and !std.mem.eql(u8, result.stderr, "No errors."))
                    try allocator.dupe(u8, result.stderr)
                else
                    null,
            };
        };
        defer {
            allocator.free(snapshotResult.stdout);
            allocator.free(snapshotResult.stderr);
            allocator.free(snapshotResult.command);
        }

        if (snapshotResult.exit_code == 0 and snapshotResult.stdout.len > 0) {
            return WebSearchResult{
                .success = true,
                .content = try allocator.dupe(u8, snapshotResult.stdout),
                .exit_code = 0,
                .error_msg = null,
            };
        }
    }

    // Determine success based on exit code
    const success = result.exit_code == 0;

    var error_msg: ?[]const u8 = null;
    if (!success and result.stderr.len > 0 and !std.mem.eql(u8, result.stderr, "No errors.")) {
        error_msg = try allocator.dupe(u8, result.stderr);
    }

    return WebSearchResult{
        .success = success,
        .content = try allocator.dupe(u8, result.stdout),
        .exit_code = result.exit_code,
        .error_msg = error_msg,
    };
}

/// Convert result to XML string for agent response
pub fn web_search_result_to_string(allocator: std.mem.Allocator, result: WebSearchResult) ![]const u8 {
    if (result.success) {
        return try std.fmt.allocPrint(allocator,
            \\<success>true</success>
            \\<content>{s}</content>
            \\<exit_code>{d}</exit_code>
        , .{
            result.content,
            result.exit_code,
        });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\<success>false</success>
            \\<content>{s}</content>
            \\<exit_code>{d}</exit_code>
            \\<error>{s}</error>
        , .{
            result.content,
            result.exit_code,
            result.error_msg orelse "Unknown error",
        });
    }
}

/// Encode a string for URL usage (percent encoding)
fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try result.append(allocator, c);
            },
            ' ' => {
                try result.appendSlice(allocator, "%20");
            },
            else => {
                var buf: [4]u8 = undefined;
                const encoded = std.fmt.bufPrint(&buf, "%{X}", .{@as(u8, c)}) catch unreachable;
                try result.appendSlice(allocator, encoded);
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}

pub const web_search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search",
        .description =
        \\A generic web browser tool using agent-browser CLI.\n
        \\ \n
        \\ **Primary Usage:**\n
        \\ - `query`: Search the web via Google (recommended for general searches)\n
        \\ - `url`: Navigate directly to any URL\n
        \\ \n
        \\ **Browser Actions:**\n
        \\ - `open`: Navigate to URL or open search results (default)\n
        \\ - `snapshot`: Get current page content\n
        \\ - `get`: Get element content by selector\n
        \\ - `click`: Click an element by CSS selector\n
        \\ - `fill`: Fill an input field by selector\n
        \\ - `press`: Press a key (e.g., 'Enter', 'Escape')\n
        \\ - `scroll`: Scroll the page (up/down/element)\n
        \\ - `back`: Go back in browser history\n
        \\ - `forward`: Go forward in browser history\n
        \\ - `refresh`: Refresh the current page\n
        \\ - `help`: Show agent-browser CLI help\n
        \\ \n
        \\ **Examples:**\n
        \\ - Search Google: {query: "Zig programming language news"}\n
        \\ - Browse URL: {url: "https://ziglang.org/", action: "open"}\n
        \\ - Get page content: {url: "https://example.com", action: "snapshot"}\n
        \\ - Click button: {url: "https://example.com", action: "click", selector: "#submit-btn"}\n
        \\ - Fill form: {url: "https://example.com", action: "fill", selector: "input[name=email]", args: "test@example.com"}\n
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Search query to search via Google. Example: 'Zig programming language news 2025'",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "Direct URL to navigate to. Example: 'https://ziglang.org/'",
                },
                .{
                    .name = "action",
                    .type = "string",
                    .description = "Browser action: open, snapshot, get, click, fill, press, scroll, back, forward, refresh, help. Default: open",
                },
                .{
                    .name = "selector",
                    .type = "string",
                    .description = "CSS selector for element operations (click, fill, get, scroll-into-view).",
                },
                .{
                    .name = "args",
                    .type = "string",
                    .description = "Additional arguments for the action (e.g., key name for 'press', text for 'fill').",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Working directory for command execution. Default: /tmp",
                },
            },
            .required = &.{},
        },
    },
};

test {
    _ = @import("web_search_test.zig");
}
