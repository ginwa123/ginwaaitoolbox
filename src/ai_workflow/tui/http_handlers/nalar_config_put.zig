const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;
const parse_thinking_mod = nalarcore.parse_thinking;
const LlmConfig = config.LlmConfig;

/// Parse the PUT body into a `ConfigInput`.
///
/// Public so the test file can exercise the same parse path the HTTP
/// handler uses — important because the handler's wire format has
/// evolved (array-of-changes → object-map-and-array, see
/// plan 2026-07-07) and tests are the only way to lock in the
/// parser's tolerance of the on-disk shape that `NalarSettings.vue`
/// actually sends.
pub fn parseConfigInput(
    allocator: std.mem.Allocator,
    body: []const u8,
) !ConfigInput {
    return std.json.parseFromSliceLeaky(ConfigInput, allocator, body, .{
        .ignore_unknown_fields = true,
    });
}

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

    // Parse input — delegate to the shared pub helper so the test
    // file can exercise the same parse path with the user's exact
    // body shape. The helper returns a tagged-union error set so
    // the test can assert the specific failure mode (e.g. JSON
    // syntax error vs wire-format mismatch) without coupling to the
    // HTTP response shape.
    const input = parseConfigInput(allocator, body) catch |err| {
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
        const parsed = try std.json.parseFromSliceLeaky(ConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        });
        config_json = parsed;
    }

    // Update with new values
    if (input.api_endpoint.len > 0) {
        config_json.base_url = try allocator.dupe(u8, input.api_endpoint);
    }
    if (input.api_key.len > 0) {
        config_json.api_key = try allocator.dupe(u8, input.api_key);
    }
    if (input.model.len > 0) {
        config_json.model = try allocator.dupe(u8, input.model);
    }
    if (input.url_style.len > 0) {
        config_json.url_style = try allocator.dupe(u8, input.url_style);
    }
    if (input.max_tokens) |mt| {
        // Frontend sends `max_tokens` as a string (often "" or a number
        // string). Accept the string shape as-is — `config_json.max_tokens`
        // is `?[]const u8` and the on-disk loader parses it back to usize
        // via `LlmConfig.init`. Empty / non-numeric strings are coerced to
        // null (= "no change") so a malformed value doesn't poison the
        // saved config.
        if (mt.len > 0) {
            // Reject purely-non-numeric content (e.g. "abc") but allow the
            // legitimate empty-after-trim case. parseInt is a strict
            // format check that catches the "abc" case without rejecting
            // leading zeros / quoted-numbers the frontend may send.
            if (std.fmt.parseInt(usize, mt, 10)) |_| {
                config_json.max_tokens = try allocator.dupe(u8, mt);
            } else |_| {
                config_json.max_tokens = null;
            }
        } else {
            config_json.max_tokens = null;
        }
    }
    if (input.system_prompt.len > 0) {
        config_json.system_prompt = try allocator.dupe(u8, input.system_prompt);
    }
    if (input.notify_on_complete) |n| {
        config_json.notify_on_complete = n;
    }
    if (input.model_compaction_size_kb) |kb| {
        config_json.model_compaction_size_kb = kb;
    }
    // Top-level compaction defaults — restored in plan
    // 2026-07-07-compaction-inline. `null` is a legitimate value (the
    // cascade wildcard); clients opt out of the top-level override by
    // sending null.
    if (input.max_capacity_token_model) |mc| {
        config_json.max_capacity_token_model = mc;
    }
    if (input.compaction_threshold_percent) |tp| {
        if (tp > 100) return error.InvalidThresholdPercent;
        config_json.compaction_threshold_percent = tp;
    }
    // retry_delay_ms: clamp to [0, 60_000]. Values > 60_000 would let a
    // user lock themselves out of cancelable recovery (one cancellation
    // attempt would have to wait the full delay). Values < 0 are
    // impossible at the type level (u32). `null` means "no change" so
    // an omit-from-PUT doesn't reset the existing value.
    if (input.retry_delay_ms) |ms| {
        config_json.retry_delay_ms = if (ms > 60_000) 60_000 else ms;
    }

    // Handle profiles - accept BOTH the on-disk shape (object map) and the
    // granular change-list shape (array of ProfileChange). The frontend's
    // main settings panel sends the on-disk shape (Record<name, profile>);
    // the sub-agent add/edit/delete UIs send the array shape. Plan
    // 2026-07-07 inline-compaction + PUT 400 bug fix: previously the
    // handler only accepted the array shape, causing the main settings
    // save to 400 with "Invalid JSON input" because parseFromSliceLeaky
    // rejected the on-disk object map.
    if (input.profiles) |profiles_value| {
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

        switch (profiles_value) {
            // Granular change-list shape: array of ProfileChange entries.
            .array => |arr| {
                for (arr.items) |item| {
                    const profile_change = try json.parseFromSliceLeaky(
                        ProfileChange,
                        allocator,
                        std.mem.asBytes(&item),
                        .{ .ignore_unknown_fields = true },
                    );
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
                            // Per-profile compaction overrides (Chunk 7). When
                            // the input omits them, we omit the JSON key so an
                            // "update" doesn't clobber the existing on-disk
                            // value. When present, validate the threshold range.
                            if (profile_change.max_capacity_tokens) |mct| {
                                try profile_obj.put(allocator, "max_capacity_tokens", json.Value{ .integer = mct });
                            }
                            if (profile_change.compaction_threshold_percent) |tp| {
                                if (tp > 100) return error.InvalidThresholdPercent;
                                try profile_obj.put(allocator, "compaction_threshold_percent", json.Value{ .integer = tp });
                            }
                            // === Model-thinking knobs (plan 2026-08-23-model-thinking) ===
                            // Validate inline (NOT at JSON-parse time) so a
                            // single error path serves both the granular
                            // change-list shape (this branch) and the
                            // on-disk object-map shape (validated via
                            // validateModelThinkingOnDiskProfileMap
                            // below). We return early with a 400 + a
                            // structured body so the caller sees a
                            // descriptive message (the gserverz error
                            // path returns a generic "Handler error" 500).
                            if (profile_change.thinking_budget_tokens) |t| {
                                if (t == 0 or t > 2_000_000) {
                                    return res.jsonResponse(.{
                                        .status_code = 400,
                                        .data = try http_response.makeErrorResponse(
                                            allocator,
                                            .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                                        ),
                                    });
                                }
                                try profile_obj.put(allocator, "thinking_budget_tokens", json.Value{ .integer = t });
                            }
                            if (profile_change.reasoning_effort) |re| {
                                _ = parse_thinking_mod.parseReasoningEffort(re) catch {
                                    return res.jsonResponse(.{
                                        .status_code = 400,
                                        .data = try http_response.makeErrorResponse(
                                            allocator,
                                            .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                                        ),
                                    });
                                };
                                try profile_obj.put(allocator, "reasoning_effort", json.Value{ .string = try allocator.dupe(u8, re) });
                            }
                            const profile_value_obj = json.Value{ .object = profile_obj };
                            try profiles_obj.put(allocator, try allocator.dupe(u8, profile_change.name), profile_value_obj);
                        }
                    }
                }
            },
            // On-disk shape: object map. Each entry is the full profile
            // metadata for a single profile. Deep-copy each entry so
            // the borrowed slice from the parsed request stays valid
            // across the `parsed.deinit()` at scope exit.
            .object => |obj| {
                // Validate model-thinking fields before copying. The
                // validation must reject bad values BEFORE we write
                // anything to disk. Plan 2026-08-23-model-thinking.
                // We translate the error variant into a 400 + a
                // structured body inline so the caller sees a
                // descriptive message (the gserverz error path returns
                // a generic "Handler error" 500).
                validateModelThinkingOnDiskProfileMap(obj) catch |err| switch (err) {
                    error.InvalidThinkingBudgetTokens => {
                        return res.jsonResponse(.{
                            .status_code = 400,
                            .data = try http_response.makeErrorResponse(
                                allocator,
                                .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                            ),
                        });
                    },
                    error.InvalidReasoningEffort => {
                        return res.jsonResponse(.{
                            .status_code = 400,
                            .data = try http_response.makeErrorResponse(
                                allocator,
                                .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                            ),
                        });
                    },
                };

                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const copied_value = try deepCopyJsonValue(allocator, entry.value_ptr.*);
                    try profiles_obj.put(allocator, key, copied_value);
                }
            },
            else => return error.InvalidJson,
        }

        config_json.profiles_models = json.Value{ .object = profiles_obj };
    }

    // Handle active profile
    if (input.active_profile) |ap| {
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
    if (input.mcp_servers) |servers_value| {
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
    if (input.sub_agents) |sas| {
        // === Model-thinking validation (plan 2026-08-23-model-thinking) ===
        // Validate each sub-agent's `thinking_budget_tokens` and
        // `reasoning_effort` BEFORE any dup'ing so a bad value is
        // rejected at the HTTP layer rather than silently written
        // to disk. Translate the error into a 400 + structured body
        // inline so the caller sees a descriptive message.
        for (sas) |sa| {
            if (sa.thinking_budget_tokens) |t| {
                if (t == 0 or t > 2_000_000) {
                    return res.jsonResponse(.{
                        .status_code = 400,
                        .data = try http_response.makeErrorResponse(
                            allocator,
                            .{ .@"error" = "InvalidThinkingBudgetTokens: thinking_budget_tokens must be in (0, 2_000_000]" },
                        ),
                    });
                }
            }
            if (sa.reasoning_effort) |re| {
                _ = parse_thinking_mod.parseReasoningEffort(re) catch {
                    return res.jsonResponse(.{
                        .status_code = 400,
                        .data = try http_response.makeErrorResponse(
                            allocator,
                            .{ .@"error" = "InvalidReasoningEffort: reasoning_effort must be one of low/medium/high/auto" },
                        ),
                    });
                };
            }
        }
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
                // Model-thinking knobs (plan 2026-08-23-model-thinking).
                // Already range-validated above; thread through as-is.
                .thinking_budget_tokens = sa.thinking_budget_tokens,
                .reasoning_effort = if (sa.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
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

/// Wire format for the PUT body. Public so the test file
/// (`nalar_config_put_test.zig`) can re-parse the same body the
/// HTTP handler would parse and assert the wire format matches the
/// frontend's actual `NalarSettings.vue` shape.
pub const ConfigInput = struct {
    api_endpoint: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    url_style: []const u8 = "openai",
    temperature: f64 = 0.7,
    /// Frontend sends `max_tokens` as a string (often `""` or a number
    /// string like "4096"). Pre-fix this was typed as `?usize` and
    /// the parser rejected empty / non-numeric strings with
    /// `error.InvalidCharacter` — turning the whole PUT into a 400.
    /// Accept the string shape; the apply block coerces to usize
    /// with a safe fallback.
    max_tokens: ?[]const u8 = null,
    system_prompt: []const u8 = "",
    // Two accepted wire formats (plan 2026-07-07 + bug fix for PUT 400):
//   - ARRAY: `[{"name":"...", "action":"update|add|delete", ...}, ...]`
//     (the granular per-profile change list — used by sub-agent add/edit/delete UIs)
//   - OBJECT: `{"profile1": {"model":...}, "profile2": {...}}`
//     (the on-disk shape, sent by the main settings panel's full-form PUT)
// We accept both via `?json.Value` and branch at the apply site. Each
// shape is validated + deep-copied into the new `config_json.profiles_models`
// so the same downstream code works for both.
profiles: ?json.Value = null,
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
    /// Optional top-level override for the context window (in tokens).
    /// Restored in plan 2026-07-07-compaction-inline. `null` = fall
    /// through to per-profile override, then built-in default. Per-profile
    /// overrides (`ProfileChange.max_capacity_tokens`) coexist independently.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold percentage (0-100).
    /// Restored in plan 2026-07-07-compaction-inline. `null` = fall
    /// through to per-profile override, then built-in 80. Values > 100
    /// are rejected with `error.InvalidThresholdPercent`.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// Range-validated at apply time: 0 ≤ value ≤ 60_000. `null` means
    /// "no change" so an omit-from-PUT doesn't reset the existing
    /// value. Matches `LlmConfig.retry_delay_ms` (Config.zig) and the
    /// GET handler's `ConfigJson` shape.
    retry_delay_ms: ?u32 = null,
    // Note: per-profile compaction overrides (max_capacity_tokens,
    // compaction_threshold_percent) live on `ProfileChange` below.
    // Both layers coexist: top-level for Defaults tab, per-profile for
    // profile-specific overrides.
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
    /// Optional override for the per-profile context window (in tokens).
    /// Mirrors `LlmProfile.max_capacity_tokens` in Config.zig. When
    /// non-null, the JSON write below sets the `max_capacity_tokens`
    /// key on the profile object. When null, the key is omitted
    /// (preserves existing on-disk value if the action is "update").
    max_capacity_tokens: ?u32 = null,
    /// Optional per-profile compaction threshold percentage (0-100).
    /// Mirrors `LlmProfile.compaction_threshold_percent`. Values > 100
    /// are rejected with `error.InvalidThresholdPercent` at the apply
    /// block above (per-profile validation is layered on top of the
    /// top-level model_compaction_size_kb check).
    compaction_threshold_percent: ?u8 = null,
    /// Anthropic-only override for `thinking.budget_tokens`. Plan
    /// 2026-08-23-model-thinking. Must be in (0, 2_000_000] when
    /// present — values outside that range are rejected with
    /// `error.InvalidThinkingBudgetTokens`.
    thinking_budget_tokens: ?u32 = null,
    /// OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1).
    /// One of "low" | "medium" | "high" | "auto". Invalid values
    /// are rejected with `error.InvalidReasoningEffort` via the
    /// parse_thinking helper (so the validation logic lives in
    /// exactly one place — see parse_thinking.zig).
    reasoning_effort: ?[]const u8 = null,
};

const ConfigJson = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?[]const u8 = null,
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
    /// Top-level context window override. Restored in plan
    /// 2026-07-07-compaction-inline. `null` is the cascade wildcard
    /// (falls through to per-profile override, then built-in).
    max_capacity_token_model: ?u32 = null,
    /// Top-level compaction threshold. Restored in plan
    /// 2026-07-07-compaction-inline. `null` is the cascade wildcard.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before retrying a failed workflow call.
    /// Mirrors `LlmConfig.retry_delay_ms` (Config.zig). Clamped to
    /// [0, 60_000] by the apply block. Default 0 = no delay.
    retry_delay_ms: u32 = 0,
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

/// Validate every profile in the on-disk object-map shape for the
/// model-thinking fields (`thinking_budget_tokens`,
/// `reasoning_effort`). The granular change-list shape (array of
/// `ProfileChange`) is validated inline at its apply block above;
/// this helper covers the on-disk shape because that path deep-
/// copies the raw `json.Value` directly to disk without parsing
/// through `ProfileChange`.
///
/// Returns `error.InvalidThinkingBudgetTokens` /
/// `error.InvalidReasoningEffort` for any bad value, mirroring the
/// change-list validation's error contract.
fn validateModelThinkingOnDiskProfileMap(obj: json.ObjectMap) !void {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const profile_value = entry.value_ptr.*;
        if (profile_value != .object) continue; // malformed entry, but the parser will catch it
        const profile_obj = profile_value.object;

        // thinking_budget_tokens: must be a positive integer in
        // (0, 2_000_000]. Type-check the raw JSON value because the
        // on-disk shape bypasses the `ProfileChange` parse struct.
        // JSON `.null` is the legitimate "no override" sentinel
        // (matches `LlmProfile.thinking_budget_tokens: ?u32 = null`
        // in Config.zig) — must be accepted, not rejected.
        if (profile_obj.get("thinking_budget_tokens")) |tbt| {
            switch (tbt) {
                .null => {},
                .integer => |i| {
                    if (i <= 0 or i > 2_000_000) return error.InvalidThinkingBudgetTokens;
                },
                else => return error.InvalidThinkingBudgetTokens,
            }
        }

        // reasoning_effort: must be one of low / medium / high / auto,
        // or `.null` for "no override" (matches
        // `LlmProfile.reasoning_effort: ?[]const u8 = null`).
        if (profile_obj.get("reasoning_effort")) |re| {
            switch (re) {
                .null => {},
                .string => |s| {
                    _ = parse_thinking_mod.parseReasoningEffort(s) catch return error.InvalidReasoningEffort;
                },
                else => return error.InvalidReasoningEffort,
            }
        }
    }
}
