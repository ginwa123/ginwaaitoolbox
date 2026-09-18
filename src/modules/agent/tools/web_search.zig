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

const sanitize = @import("helpers").sanitize_control_chars;

/// Convert result to a JSON string for agent response
pub fn web_search_result_to_json(allocator: std.mem.Allocator, result: WebSearchResult) ![]u8 {
    const clean_content = try sanitize(allocator, result.content);
    defer allocator.free(clean_content);
    if (result.error_msg) |m| {
        const clean_err = try sanitize(allocator, m);
        defer allocator.free(clean_err);
        return std.json.Stringify.valueAlloc(allocator, .{
            .success = result.success,
            .content = clean_content,
            .exit_code = result.exit_code,
            .error_msg = clean_err,
        }, .{});
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .success = result.success,
        .content = clean_content,
        .exit_code = result.exit_code,
        .error_msg = @as(?[]const u8, null),
    }, .{});
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
