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
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

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

    // Plan 2026-09-04-subagents-per-profile: the top-level `sub_agents`
    // response block was removed. Per-profile lists ride inside
    // `profiles` as raw JSON passthrough — no typed materialization
    // needed here. (`cfg.sub_agents` stays parsed for compat but is
    // never sent; prefix with underscore to mark intentionally unused.)
    _ = cfg.sub_agents;

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeNalarConfigResponse(allocator, .{
            // Plan 2026-08-24-config-simplify-remove-defaults: the
            // top-level LLM defaults are no longer on the wire. Profiles
            // + operational settings only.
            .profiles = cfg.profiles_models,
            .active_profile = cfg.active_profile,
            .mcp_servers = cfg.mcp_servers,
            // Plan 2026-09-04-subagents-per-profile: top-level
            // subagents are removed from the wire. Each profile
            // carries its own `sub_agents` inside `profiles` (raw
            // JSON passthrough above). The on-disk key is still
            // parsed (compat) but never sent.
            .sub_agents = null,
            .notify_on_complete = cfg.notify_on_complete,
            .notify_on_error = cfg.notify_on_error,
            .web_launch_enabled = cfg.web_launch_enabled,
            .model_compaction_size_kb = cfg.model_compaction_size_kb,
            // Top-level compaction defaults — restored in plan
            // 2026-07-07-compaction-inline.
            .max_capacity_token_model = cfg.max_capacity_token_model,
            .compaction_threshold_percent = cfg.compaction_threshold_percent,
            .retry_delay_ms = cfg.retry_delay_ms,
            .tools = cfg.tools,
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
    /// Opt-in web-launch flag (see LlmConfigJson in Config.zig).
    /// Defaults to `false` so a missing-on-disk config has web launch off.
    web_launch_enabled: bool = false,
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
    /// Default tool checklist (Tools tab, plan
    /// 2026-09-22-tools-menu-config-default-tools). Emitted as JSON
    /// `null` when the on-disk key is absent (mirrors `mcp_servers`).
    tools: ?[]const []const u8 = null,
};

// ===== Tests merged from nalar_config_get_test.zig (2026-09-11 flatten) =====
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const RESP_PATH = "src/http_handlers/http_response.zig";
const GET_PATH = "src/http_handlers/nalar_config_get.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "GET /api/config/nalar response includes retry_delay_ms" {
    const allocator = testing.allocator;

    // 1) NalarConfigResponse declares retry_delay_ms: u32 = 0
    const response_src = try readSource(allocator, RESP_PATH);
    defer allocator.free(response_src);
    if (std.mem.indexOf(u8, response_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! NalarConfigResponse missing retry_delay_ms !!\n", .{});
        return error.RetryDelayMissingFromResponse;
    }

    // 2) ConfigJson declares retry_delay_ms: u32 = 0 (so the parsed
    //    JSON gets the field).
    const get_src = try readSource(allocator, GET_PATH);
    defer allocator.free(get_src);
    if (std.mem.indexOf(u8, get_src, "retry_delay_ms: u32 = 0") == null) {
        std.debug.print("!! nalar_config_get.zig ConfigJson missing retry_delay_ms field !!\n", .{});
        return error.RetryDelayMissingFromConfigJson;
    }

    // 3) The GET handler pipes cfg.retry_delay_ms into the response
    //    (i.e. the makeNalarConfigResponse call references the new
    //    field sourced from cfg).
    if (std.mem.indexOf(u8, get_src, ".retry_delay_ms = cfg.retry_delay_ms") == null) {
        std.debug.print("!! nalar_config_get.zig does not pipe retry_delay_ms !!\n", .{});
        return error.RetryDelayNotWiredIntoGet;
    }
}

test "GET /api/config/nalar response includes notify_on_error (task_1787671269086_0)" {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // error-notification toggle is a NEW field added to the wire
    // shape. Like `notify_on_complete`, it must appear in BOTH
    // `NalarConfigResponse` (response shape) AND `ConfigJson` (parse
    // shape) AND the GET handler must pipe `cfg.notify_on_error`
    // into the response. Lock all three sites so a future refactor
    // that drops one of them surfaces immediately at `zig build test`.
    const allocator = testing.allocator;

    // 1) NalarConfigResponse declares notify_on_error: bool = false.
    const response_src = try readSource(allocator, RESP_PATH);
    defer allocator.free(response_src);
    if (std.mem.indexOf(u8, response_src, "notify_on_error: bool = false") == null) {
        std.debug.print("!! NalarConfigResponse missing notify_on_error !!\n", .{});
        return error.NotifyOnErrorMissingFromResponse;
    }

    // 2) ConfigJson declares notify_on_error: bool = false (so the
    //    parsed JSON gets the field).
    const get_src = try readSource(allocator, GET_PATH);
    defer allocator.free(get_src);
    if (std.mem.indexOf(u8, get_src, "notify_on_error: bool = false") == null) {
        std.debug.print("!! nalar_config_get.zig ConfigJson missing notify_on_error field !!\n", .{});
        return error.NotifyOnErrorMissingFromConfigJson;
    }

    // 3) The GET handler pipes cfg.notify_on_error into the response
    //    (i.e. the makeNalarConfigResponse call references the new
    //    field sourced from cfg).
    if (std.mem.indexOf(u8, get_src, ".notify_on_error = cfg.notify_on_error") == null) {
        std.debug.print("!! nalar_config_get.zig does not pipe notify_on_error !!\n", .{});
        return error.NotifyOnErrorNotWiredIntoGet;
    }
}

test "NalarConfigResponse serializes tools: null when absent, array when set" {
    // D2 wire contract: the frontend must be able to tell "key absent"
    // (`tools: null` → legacy defaults) from an explicit `[]` (zero
    // tools). Both keys must be PRESENT on the wire in both states —
    // an omitted key would be indistinguishable from a backend that
    // never shipped the field.
    const allocator = testing.allocator;

    const absent = try http_response.makeNalarConfigResponse(allocator, .{});
    defer allocator.free(absent);
    if (std.mem.indexOf(u8, absent, "\"tools\":null") == null) {
        std.debug.print("!! default NalarConfigResponse omits tools or does not emit null !!\n", .{});
        return error.ToolsNullNotSerialized;
    }

    const names = [_][]const u8{ "command", "read_file" };
    const present = try http_response.makeNalarConfigResponse(allocator, .{ .tools = &names });
    defer allocator.free(present);
    if (std.mem.indexOf(u8, present, "\"tools\":[\"command\",\"read_file\"]") == null) {
        std.debug.print("!! NalarConfigResponse does not serialize the tools array !!\n", .{});
        return error.ToolsArrayNotSerialized;
    }

    const empty = [_][]const u8{};
    const empty_resp = try http_response.makeNalarConfigResponse(allocator, .{ .tools = &empty });
    defer allocator.free(empty_resp);
    if (std.mem.indexOf(u8, empty_resp, "\"tools\":[]") == null) {
        std.debug.print("!! explicit [] does not serialize as an empty array !!\n", .{});
        return error.ToolsEmptyNotSerialized;
    }
}
