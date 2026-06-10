const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;
const LlmConfig = config.LlmConfig;

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

    // Handle profiles - add, update, or delete
    if (input.value.profiles) |profiles| {
        // Create new profiles object
        var profiles_obj = try json.ObjectMap.init(allocator, &.{}, &.{});

        // Copy existing profiles first (deep copy to avoid freed memory from parsed deinit)
        if (config_json.profiles_models) |existing| {
            var iter = existing.object.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                // Deep copy the value to avoid freed memory
                const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                try profiles_obj.put(allocator, key, copied_value);
            }
        }

        // Apply profile changes
        for (profiles) |profile_change| {
            const action = profile_change.action;
            if (action.len > 0) {
                if (std.mem.eql(u8, action, "delete")) {
                    _ = profiles_obj.swapRemove(profile_change.name);
                } else if (std.mem.eql(u8, action, "add") or std.mem.eql(u8, action, "update")) {
                    var profile_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                    try profile_obj.put(allocator, "model", if (profile_change.model.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.model) } else json.Value{ .string = "" });
                    try profile_obj.put(allocator, "base_url", if (profile_change.base_url.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.base_url) } else json.Value{ .string = "" });
                    try profile_obj.put(allocator, "thinking", json.Value{ .string = try allocator.dupe(u8, profile_change.thinking) });
                    try profile_obj.put(allocator, "temperature", json.Value{ .string = try allocator.dupe(u8, profile_change.temperature) });
                    try profile_obj.put(allocator, "url_style", json.Value{ .string = try allocator.dupe(u8, profile_change.url_style) });
                    try profile_obj.put(allocator, "api_key", if (profile_change.api_key.len > 0) json.Value{ .string = try allocator.dupe(u8, profile_change.api_key) } else json.Value{ .string = "" });
                    const profile_value = json.Value{ .object = profile_obj };
                    try profiles_obj.put(allocator, try allocator.dupe(u8, profile_change.name), profile_value);
                }
            }
        }
        config_json.profiles_models = json.Value{ .object = profiles_obj };
    }

    // Handle active profile
    if (input.value.active_profile) |ap| {
        if (ap.len > 0) {
            config_json.active_profile = try allocator.dupe(u8, ap);
        } else {
            config_json.active_profile = null;
        }
    }

    // Handle MCP servers: if the input provides an `mcp_servers` map, replace
    // the existing list wholesale (whole-list replace matches the UI's
    // add/edit/delete workflow). The input map is deep-copied so the parsed
    // struct can safely go out of scope.
    if (input.value.mcp_servers) |servers_value| {
        switch (servers_value) {
            .object => |obj| {
                var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer new_obj.deinit(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                    try new_obj.put(allocator, key, copied_value);
                }
                config_json.mcp_servers = json.Value{ .object = new_obj };
            },
            else => {
                // Non-object value: silently drop (e.g. user sent `null`).
                config_json.mcp_servers = null;
            },
        }
    }

    // Handle top-level sub_agents: if the input provides a `sub_agents`
    // array, replace the existing list wholesale (whole-list replace matches
    // the UI's add/edit/delete workflow). Each entry's 8 string fields are
    // duped onto the allocator so the new array is independent of the
    // parsed input slice (which goes out of scope after this function).
    if (input.value.sub_agents) |sas| {
        const owned = try allocator.alloc(LlmConfig.SubAgentJson, sas.len);
        errdefer allocator.free(owned);
        for (sas, 0..) |sa, i| {
            owned[i] = .{
                .name = try allocator.dupe(u8, sa.name),
                .model = try allocator.dupe(u8, sa.model),
                .base_url = try allocator.dupe(u8, sa.base_url),
                .thinking = try allocator.dupe(u8, sa.thinking),
                .temperature = try allocator.dupe(u8, sa.temperature),
                .url_style = try allocator.dupe(u8, sa.url_style),
                .api_key = try allocator.dupe(u8, sa.api_key),
                .system_prompt = try allocator.dupe(u8, sa.system_prompt),
            };
        }
        config_json.sub_agents = owned;
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
    try writer.flush();

    // === Live-reload ContextIPCTui.llm_config ===
    // Reload from disk so the running workflow picks up the new API key,
    // model, base_url, mcp_servers, and profiles without a server restart.
    // On any failure we still respond 200 (disk is already authoritative)
    // but log the error and skip the swap so the running config is stable.
    {
        const env_for_reload: *std.process.Environ.Map = @constCast(@ptrCast(di.environment orelse environment));

        var new_cfg = config.LlmConfig.init(di.allocator, io, null, env_for_reload) catch |err| {
            std.log.err("PUT /api/config/nalar: live reload parse failed: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved to disk but live reload parse failed" }),
            });
        };

        new_cfg.validate() catch |err| {
            std.log.err("PUT /api/config/nalar: live reload validation failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved to disk but failed validation" }),
            });
        };

        const new_ptr = di.allocator.create(config.LlmConfig) catch |err| {
            std.log.err("PUT /api/config/nalar: alloc failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        new_ptr.* = new_cfg;

        // Atomically swap. Previous-pointer free happens inside setLlmConfig.
        nalarcore.setLlmConfig(di, new_ptr);
        std.log.info("PUT /api/config/nalar: live-reloaded llm_config (model={s}, base_url={s})", .{ new_ptr.model, new_ptr.base_url });
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Config saved successfully" }),
    });
}

const ConfigInput = struct {
    api_endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    url_style: []const u8 = "openai",
    temperature: f64 = 0.7,
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles: ?[]const ProfileChange = null,
    active_profile: ?[]const u8 = null,
    /// Whole-list replace for the `mcp_servers` map (snake_case).
    /// When present, replaces the existing MCP servers entirely.
    /// When absent, existing MCP servers are preserved.
    mcp_servers: ?json.Value = null,
    /// When true, fire an OS-level notification when an LLM response
    /// finishes with `finish_reason == "stop"`. Absent = preserve
    /// existing on-disk value. Mirrors the `LlmConfigJson` default
    /// (`false`) so a brand-new config has notifications off.
    notify_on_complete: ?bool = null,
    /// Threshold (in KB) above which the session compactor is invoked
    /// to shrink the LLM context. Absent = preserve existing on-disk
    /// value. Mirrors the `LlmConfigJson` default (`100`).
    model_compaction_size_kb: ?usize = null,
    /// Whole-list replace for the top-level `sub_agents` array.
    /// When present, replaces the existing sub-agents entirely.
    /// When absent, existing sub-agents are preserved. Borrowed slices
    /// from the request body — the handler dupes each entry's strings
    /// before assigning to `config_json.sub_agents`.
    sub_agents: ?[]const LlmConfig.SubAgentJson = null,
};

const ProfileChange = struct {
    name: []const u8,
    action: []const u8, // "add", "update", "delete"
    model: []const u8 = "",
    base_url: []const u8 = "",
    thinking: []const u8 = "auto",
    temperature: []const u8 = "auto",
    url_style: []const u8 = "openai",
    api_key: []const u8 = "",
};

const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Configured MCP servers (snake_case, matches NALAR.md JSON convention).
    mcp_servers: ?json.Value = null,
    /// Opt-in OS notification flag. Default `false` matches
    /// `LlmConfigJson` (Config.zig:96); a brand-new config has
    /// notifications off.
    notify_on_complete: bool = false,
    /// Compaction threshold in KB. Default `100` matches
    /// `LlmConfigJson` (Config.zig:92).
    model_compaction_size_kb: usize = 100,
    /// Top-level sub-agents array (snake_case, matches NALAR.md JSON
    /// convention). Parsed into the typed `LlmConfig.SubAgentJson` shape
    /// (borrowed from the parsed file content), or replaced by an
    /// owned copy (duped from the request body) when the input provides
    /// a new list.
    sub_agents: ?[]LlmConfig.SubAgentJson = null,
};

/// Deep copy a json.Value to avoid use-after-free from parsed.deinit()
fn deepCopyJsonValue(allocator: std.mem.Allocator, value: json.Value) error{OutOfMemory}!json.Value {
    switch (value) {
        .null => return json.Value{ .null = {} },
        .bool => |b| return json.Value{ .bool = b },
        .integer => |i| return json.Value{ .integer = i },
        .float => |f| return json.Value{ .float = f },
        .number_string => |s| return json.Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return json.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try deepCopyJsonValue(allocator, item));
            }
            return json.Value{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key, copied_value);
            }
            return json.Value{ .object = new_obj };
        },
    }
}
