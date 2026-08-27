const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;
const LlmConfig = config.LlmConfig;

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
        // If file doesn't exist, return an empty profile-only config
        // (plan 2026-08-24-config-simplify-remove-defaults: no top-level
        // LLM defaults on the wire).
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try http_response.makeNalarConfigResponse(allocator, .{}),
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
    const parsed = std.json.parseFromSliceLeaky(ConfigJson, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse config: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON in config" }),
        });
    };

    const cfg = parsed;

    // Build the typed sub_agents response from the typed parse target.
    // `cfg.sub_agents` is borrowed from `parsed` (zero-copy view into
    // `content`); we materialize a `SubAgentResponse` array so the
    // response payload uses our typed struct instead of `std.json.Value`.
    // No explicit `defer allocator.free(...)` here — see the
    // "Custom HTTP server uses per-request arena" memory; the request
    // allocator is freed by `GinwaServer.handle` when the request ends.
    const sub_agents_response: ?[]const http_response.SubAgentResponse = if (cfg.sub_agents) |sas| blk: {
        var out = try allocator.alloc(http_response.SubAgentResponse, sas.len);
        errdefer allocator.free(out);
        for (sas, 0..) |sa, i| {
            out[i] = .{
                .name = sa.name,
                .model = sa.model,
                .base_url = sa.base_url,
                .thinking = sa.thinking,
                .temperature = sa.temperature,
                .url_style = sa.url_style,
                .api_key = sa.api_key,
                .system_prompt = sa.system_prompt,
            };
        }
        break :blk out;
    } else null;

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeNalarConfigResponse(allocator, .{
            // Plan 2026-08-24-config-simplify-remove-defaults: the
            // top-level LLM defaults are no longer on the wire. Profiles
            // + operational settings only.
            .profiles = cfg.profiles_models,
            .active_profile = cfg.active_profile,
            .mcp_servers = cfg.mcp_servers,
            .sub_agents = sub_agents_response,
            .notify_on_complete = cfg.notify_on_complete,
            .notify_on_error = cfg.notify_on_error,
            .model_compaction_size_kb = cfg.model_compaction_size_kb,
            // Top-level compaction defaults — restored in plan
            // 2026-07-07-compaction-inline.
            .max_capacity_token_model = cfg.max_capacity_token_model,
            .compaction_threshold_percent = cfg.compaction_threshold_percent,
            .retry_delay_ms = cfg.retry_delay_ms,
        }),
    });
}

const ConfigJson = struct {
    /// Configured MCP servers (snake_case, matches NALAR.md JSON convention).
    /// Each value is a `{"url": "...", "headers": {...}}` object.
    mcp_servers: ?json.Value = null,
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Top-level sub-agents array (snake_case, matches NALAR.md JSON
    /// convention). Parsed into the typed `LlmConfig.SubAgentJson` shape
    /// so the response can mirror the same field set without falling
    /// back to a generic JSON tree. Borrowed slices from the parsed
    /// JSON — the handler must keep `parsed` alive until the response
    /// is serialized (handled via `defer parsed.deinit()` above).
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
    /// Opt-in OS notification flag (see LlmConfigJson in Config.zig).
    notify_on_complete: bool = false,
    /// Opt-in OS notification flag for the error path (see LlmConfigJson).
    /// Defaults to `false` so a missing-on-disk config is silent on errors.
    notify_on_error: bool = false,
    /// Compaction threshold in KB (see LlmConfigJson in Config.zig).
    model_compaction_size_kb: usize = 100,
    /// Optional top-level context window override (see
    /// LlmConfigJson in Config.zig). Restored in plan
    /// 2026-07-07-compaction-inline.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold (see LlmConfigJson).
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// See `LlmConfig.retry_delay_ms` for semantics.
    retry_delay_ms: u32 = 0,
};

