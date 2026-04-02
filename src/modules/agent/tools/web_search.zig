const std = @import("std");
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const WebSearchInput = schemas.WebSearchInput;
const WebSearchResult = schemas.WebSearchResult;
const AgentTool = schemas.AgentTool;

pub fn executeWebSearch(allocator: std.mem.Allocator, input: WebSearchInput) !WebSearchResult {
    // Build the agent-browser command
    var command = std.ArrayList(u8).empty;
    defer command.deinit(allocator);

    try command.appendSlice(allocator, "agent-browser ");

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

    const bashInput = BashInput{
        .command = try command.toOwnedSlice(allocator),
        .cwd = input.cwd,
        .max_output = 1024 * 1024, // 1MB for page content
    };

    const result = try bashMod.executeBash(allocator, bashInput);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
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
        \\Browse the web using agent-browser CLI.
        \\- `action`: Command to execute (open, snapshot, get, click, etc.)
        \\- `url`: URL for open action or page context
        \\- `selector`: Optional CSS selector for element operations
        \\- `args`: Optional additional arguments
        \\
        \\Examples:
        \\- Open a URL: {"url": "https://example.com", "action": "open"}
        \\- Get page snapshot: {"url": "https://example.com", "action": "snapshot"}
        \\- Get element text: {"url": "https://example.com", "action": "get", "selector": "h1"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "url",
                    .type = "string",
                    .description = "URL to navigate to (for open action) or page context.",
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
            .required = &.{ "url", "action" },
        },
    },
};

test {
    _ = @import("web_search_test.zig");
}
