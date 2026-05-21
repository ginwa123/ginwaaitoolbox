const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;

/// PUT /api/config/nalar - Save nalar.json configuration
pub fn nalarConfigPutHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    // Cast const away since getDefaultConfigDir doesn't actually modify environment
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(environment_ptr));

    // Get the default config path
    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("Failed to get config dir: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config directory" }),
        });
    };

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("Failed to build config path: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build config path" }),
        });
    };

    // Create config directory if it doesn't exist
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("Failed to create config dir: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create config directory" }),
        });
    };

    // Read request body
    const body = req.body;

    // Parse input
    const input = std.json.parseFromSlice(ConfigInput, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse input: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON input" }),
        });
    };

    // Read existing config if it exists
    var existing_content: ?[]u8 = null;
    defer if (existing_content) |c| allocator.free(c);

    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch null;
    if (file) |f| {
        defer f.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = f.reader(io, &read_buffer);
        existing_content = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }

    // Build new config
    var config_json: ConfigJson = ConfigJson{};
    if (existing_content) |content| {
        const parsed = try std.json.parseFromSlice(ConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        config_json = parsed.value;
    }

    // Update with new values
    if (input.value.api_endpoint.len > 0) {
        config_json.base_url = try allocator.dupe(u8, input.value.api_endpoint);
    }
    if (input.value.api_key.len > 0) {
        config_json.api_key = try allocator.dupe(u8, input.value.api_key);
    }
    if (input.value.model.len > 0) {
        config_json.model = try allocator.dupe(u8, input.value.model);
    }
    if (input.value.max_tokens) |mt| {
        config_json.max_tokens = mt;
    }
    if (input.value.system_prompt.len > 0) {
        config_json.system_prompt = try allocator.dupe(u8, input.value.system_prompt);
    }

    // Write config
    const config_str = try std.json.Stringify.valueAlloc(allocator, config_json, .{
        .whitespace = .indent_tab,
    });

    var write_file = try std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    });
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    try writer.interface.writeAll(config_str);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved successfully" }),
    });
}

const ConfigInput = struct {
    api_endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    temperature: f64 = 0.7,
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
};

const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
};
