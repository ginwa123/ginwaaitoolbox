const std = @import("std");
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const WebSearchInput = schemas.WebSearchInput;
const WebSearchResult = schemas.WebSearchResult;
const AgentTool = schemas.AgentTool;

/// Simple web browser - just takes a URL and returns page content
pub fn execute_web_search(allocator: std.mem.Allocator, io: std.Io, input: WebSearchInput) !WebSearchResult {
    const command = try std.fmt.allocPrint(allocator, "agent-browser snapshot {s}", .{input.url});
    defer allocator.free(command);

    const bashInput = BashInput{
        .command = command,
        .cwd = input.cwd orelse "/tmp",
        .mandatory_timeout = 60, // snapshot can be slow on heavy SPAs; kill at 60 s
        .max_output = 1024 * 1024,
    };

    const result = bashMod.execute_bash(allocator, io, bashInput) catch |err| {
        return WebSearchResult{
            .success = false,
            .content = try allocator.dupe(u8, ""),
            .exit_code = 1,
            .error_msg = try std.fmt.allocPrint(allocator, "Failed: {s}", .{@errorName(err)}),
        };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    return WebSearchResult{
        .success = result.exit_code == 0,
        .content = try allocator.dupe(u8, result.stdout),
        .exit_code = result.exit_code,
        .error_msg = if (result.stderr.len > 0 and !std.mem.eql(u8, result.stderr, "No errors."))
            try allocator.dupe(u8, result.stderr)
        else
            null,
    };
}

/// Convert result to XML string for agent response
pub fn web_search_result_to_string(allocator: std.mem.Allocator, result: WebSearchResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<success>{any}</success>
        \\<content>{s}</content>
        \\<exit_code>{d}</exit_code>
    , .{
        result.success,
        result.content,
        result.exit_code,
    });
}

pub const web_search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search",
        .description = "Simple web browser - enter a URL and get the page content.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "url",
                    .type = "string",
                    .description = "URL to browse. Example: 'https://ziglang.org/'",
                },
            },
            .required = &.{"url"},
        },
    },
};
