const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;

/// GET /api/config/nalar - Get nalar.json configuration
pub fn nalarConfigGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    // Cast const away since getDefaultConfigPath doesn't actually modify environment
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(environment_ptr));

    // Get the default config path
    const config_path = config.getDefaultConfigPath(allocator, environment) catch |err| {
        std.log.err("Failed to get config path: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config path" }),
        });
    };

    // Try to read the config file
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch {
        // If file doesn't exist, return empty config
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try http_response.makeNalarConfigResponse(allocator, .{
                .api_endpoint = "",
                .api_key = "",
                .model = "",
                .temperature = 0.7,
                .max_tokens = null,
                .system_prompt = "",
            }),
        });
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("Failed to read config: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read config" }),
        });
    };

    // Parse and return the config
    const parsed = std.json.parseFromSlice(ConfigJson, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse config: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON in config" }),
        });
    };

    const cfg = parsed.value;
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeNalarConfigResponse(allocator, .{
            .api_endpoint = cfg.base_url,
            .api_key = cfg.api_key,
            .model = cfg.model,
            .temperature = parseTemperatureOrAuto(cfg.temperature),
            .max_tokens = cfg.max_tokens,
            .system_prompt = cfg.system_prompt,
            .profiles = cfg.profiles_models,
            .active_profile = cfg.active_profile,
        }),
    });
}

const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    temperature: json.Value = .null,
    thinking: json.Value = .null,
    mcpServers: ?json.Value = null,
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
};

fn parseTemperatureOrAuto(value: json.Value) f64 {
    switch (value) {
        .float => |v| return v,
        .integer => |v| return @floatFromInt(v),
        .string => |v| {
            if (std.mem.eql(u8, v, "auto") or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "0.0")) {
                return 0.0;
            }
            return std.fmt.parseFloat(f64, v) catch 0.0;
        },
        else => return 0.0,
    }
}
