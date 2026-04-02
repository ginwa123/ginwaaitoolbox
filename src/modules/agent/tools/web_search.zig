const std = @import("std");
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const WebSearchInput = schemas.WebSearchInput;
const WebSearchResult = schemas.WebSearchResult;
const AgentTool = schemas.AgentTool;

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

pub fn executeWebSearch(allocator: std.mem.Allocator, input: WebSearchInput) !WebSearchResult {
    // Build the agent-browser command
    var command = std.ArrayList(u8).empty;
    errdefer command.deinit(allocator);

    try command.appendSlice(allocator, "agent-browser ");

    // Handle search query mode
    if (input.query) |query| {
        // Encode the query for URL
        const encoded_query = try urlEncode(allocator, query);
        defer allocator.free(encoded_query);

        // Build Bing search URL
        const bing_url = try std.fmt.allocPrint(allocator, "https://www.bing.com/search?q={s}", .{encoded_query});
        defer allocator.free(bing_url);

        // Open Bing search
        try command.appendSlice(allocator, "open ");
        try command.appendSlice(allocator, bing_url);
    } else {
        // Handle special "help" action
        if (std.mem.eql(u8, input.action, "help")) {
            try command.appendSlice(allocator, "--help");
        } else {
            // Add action
            try command.appendSlice(allocator, input.action);

            // Add URL for open action
            if (std.mem.eql(u8, input.action, "open") and input.url.len > 0) {
                try command.append(allocator, ' ');
                try command.appendSlice(allocator, input.url);
            }

            // Add selector if provided
            if (input.selector) |sel| {
                try command.append(allocator, ' ');
                try command.appendSlice(allocator, sel);
            }

            // Add additional args if provided
            if (input.args) |args| {
                try command.append(allocator, ' ');
                try command.appendSlice(allocator, args);
            }
        }
    }

    const cmd_str = try command.toOwnedSlice(allocator);
    defer allocator.free(cmd_str);

    const bashInput = BashInput{
        .command = cmd_str,
        .cwd = input.cwd,
        .max_output = 1024 * 1024, // 1MB for page content
    };

    const result = try bashMod.executeBash(allocator, bashInput);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    // For search query mode, also get the page snapshot
    if (input.query != null and result.exit_code == 0) {
        // Get page content via snapshot
        const snapshot_cmd = "agent-browser snapshot";

        const snapshotInput = BashInput{
            .command = snapshot_cmd,
            .cwd = input.cwd,
            .max_output = 1024 * 1024,
        };

        const snapshotResult = try bashMod.executeBash(allocator, snapshotInput);
        defer {
            allocator.free(snapshotResult.stdout);
            allocator.free(snapshotResult.stderr);
            allocator.free(snapshotResult.command);
        }

        if (snapshotResult.exit_code == 0 and snapshotResult.stdout.len > 0) {
            // Return the snapshot content instead
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

pub fn webSearchResultToString(allocator: std.mem.Allocator, result: WebSearchResult) ![]const u8 {
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

pub const web_search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search",
        .description =
        \\Search the web using Bing search and agent-browser.\n
        \\ \n
        \\ **Use `query` for web search (recommended)**\n
        \\ - Takes a search query and automatically searches Bing\n
        \\ - Returns the search results page\n
        \\ - Example: query: "Zig programming language news 2025"\n
        \\ \n
        \\ **Parameters:**\n
        \\ - `query`: Search query string (e.g., "TypeScript features")\n
        \\ - `url`: Direct URL to navigate to (advanced)\n
        \\ - `action`: Browser action for direct URL (open, snapshot, etc.)\n
        \\ - `selector`: CSS selector for element operations\n
        \\ \n
        \\ **Examples:**\n
        \\ - Search: {query: "Rust programming language news"}\n
        \\ - Browse URL: {url: "https://ziglang.org/news/", action: "open"}\n
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Search query (e.g., 'Zig programming language news'). Searches Bing and returns results.",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "URL to navigate to (for direct browser commands).",
                },
                .{
                    .name = "action",
                    .type = "string",
                    .description = "Action to perform: open, snapshot, get, click, fill, press, etc.",
                },
                .{
                    .name = "selector",
                    .type = "string",
                    .description = "Optional CSS selector for element operations.",
                },
                .{
                    .name = "args",
                    .type = "string",
                    .description = "Optional additional arguments for the action.",
                },
            },
            .required = &.{"query"},
        },
    },
};

test {
    _ = @import("web_search_test.zig");
}
