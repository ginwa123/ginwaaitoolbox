const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const LLMModels = @import("../agent/LLMModels.zig");

pub const LlmConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    model_compaction_size_kb: usize,
    mcpServers_parsed: ?json.Parsed(json.Value),
    /// Typed map of MCP servers. Keys are server names, values are owned
    /// `McpServerConfig` (with their own owned `url` and `headers`).
    /// Populated from the same JSON object as `mcpServers_parsed` so that
    /// both representations stay in sync.
    mcp_servers: McpServersMap,
    /// Parsed profiles from profiles_models
    profiles_models: ProfilesMap,
    /// Top-level sub-agents array. Each entry is a typed `SubAgentConfig`
    /// with its own owned strings.
    sub_agents: SubAgentsList,
    url_style: []const u8,
    /// When true, fire an OS-level notification when an LLM response
    /// finishes with `finish_reason === 'stop'`. Off by default — the
    /// user opts in via the config. Notifications are dispatched from
    /// the backend (notify-send / osascript / PowerShell) so they work
    /// even when the desktop app's browser is closed.
    notify_on_complete: bool = true,
    /// Optional top-level override for the context window (in tokens).
    /// `null` = fall through to the per-profile override
    /// (`LlmProfile.max_capacity_tokens`), then to the built-in
    /// `LLMModels.getModelTokenCount(model)` default. Restored in
    /// plan 2026-07-07-compaction-inline (the user wants defaults
    /// visible in the Defaults tab, not only in a separate Compaction
    /// tab). See `maxCapacityForModel` for the cascade order.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold as a percentage (0-100)
    /// of the model's context window. `null` = fall through to the
    /// per-profile override (`LlmProfile.compaction_threshold_percent`),
    /// then to the built-in default of 80. Range-validated at the
    /// HTTP layer (see `error.InvalidThresholdPercent`).
    compaction_threshold_percent: ?u8 = null,
    /// Owned slice of random sub-agent names that `resolveSubAgent`
    /// generated for the random-fallback case. Each name is allocated
    /// on `self.allocator` and is freed in `deinit`. Slices in the
    /// `ResolvedSubAgent` returned by `resolveSubAgent` borrow from
    /// this slice — callers MUST use them only while `self` is alive
    /// (which is always the case in production because `LlmConfig`
    /// lives in the singleton).
    random_names: [][]u8 = &.{},

    pub const LoadError = error{
        ConfigFileNotFound,
        ConfigFileReadError,
        InvalidJson,
        MissingRequiredField,
        OutOfMemory,
        HomeNotFound,
        ConfigDirNotFound,
        /// `compaction_threshold_percent` outside the 0..100 range.
        /// Surfaced by the HTTP PUT handler at the validation gate
        /// (validates both `LlmProfile.compaction_threshold_percent`
        /// and `SubAgentConfig.compaction_threshold_percent`).
        InvalidThresholdPercent,
    };

    /// Individual profile settings.
    ///
    /// The compaction-related fields (`max_capacity_tokens`,
    /// `compaction_threshold_percent`) cascade down to sub-agents in
    /// the same profile via `resolveCompactionSettings`. Use them when
    /// a profile uses a self-hosted model with a different context
    /// window, or when a profile wants a different compaction aggressiveness
    /// (e.g. dev profile compacts at 50%, prod profile at 90%).
    pub const LlmProfile = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
        url_style: []const u8 = "openai",
        /// Per-profile sub-agents. Owned `[]SubAgentConfig` (default empty).
        /// Each entry's strings are allocated with the parent `LlmConfig.allocator`.
        sub_agents: SubAgentsList = &.{},
        /// Optional override for the context window (in tokens) used
        /// by this profile. `null` = use `LLMModels.getModelTokenCount(model)`
        /// built-in default. Set this when using a self-hosted model with
        /// a non-standard context window, or to under-provision for cost.
        max_capacity_tokens: ?u32 = null,
        /// Compaction threshold as a percentage (0-100) of the model's
        /// context window. `null` = use the built-in 80. Values > 100
        /// are rejected by the HTTP layer with `error.InvalidThresholdPercent`.
        compaction_threshold_percent: ?u8 = null,
    };

    /// Typed configuration for a single sub-agent. Mirrors `LlmProfile`
    /// fields plus an additional `system_prompt` and two
    /// compaction-related overrides that cascade over the parent
    /// profile. All strings are owned slices (allocated with the parent
    /// `LlmConfig.allocator`).
    pub const SubAgentConfig = struct {
        name: []const u8,
        model: []const u8,
        base_url: []const u8,
        thinking: []const u8,
        temperature: []const u8,
        url_style: []const u8,
        api_key: []const u8,
        system_prompt: []const u8,
        /// Optional override for the context window (in tokens) for
        /// this sub-agent. `null` = inherit from the parent profile (or
        /// the built-in default if no profile).
        max_capacity_tokens: ?u32 = null,
        /// Compaction threshold percentage (0-100) for this sub-agent.
        /// `null` = inherit from the parent profile (or 80 if no profile).
        compaction_threshold_percent: ?u8 = null,
    };

    /// Owned slice of `SubAgentConfig` entries. The slice itself (when non-empty)
    /// is allocated with the parent `LlmConfig.allocator`, and each entry's
    /// string fields are individually allocated on the same allocator.
    pub const SubAgentsList = []SubAgentConfig;

    /// Resolved sub-agent configuration — the output of
    /// `resolveSubAgent`. Carries the sub-agent's name, the resolved
    /// LLM endpoint fields, the strongly-typed `thinking` /
    /// `temperature`, and the system prompt to inject.
    ///
    /// All `[]const u8` string fields in the LLM block (model, base_url,
    /// api_key, url_style) are **already overlaid** on the
    /// orchestrator's defaults — an empty field in the matched
    /// `SubAgentConfig` falls through to the orchestrator's value, so
    /// the caller can use these slices directly.
    ///
    /// `is_thinking` and `temperature` are `?bool` / `?f32` (not
    /// strings) so the workflow can use them without parsing.
    /// `null` means "auto — inherit from parent's value at run time".
    ///
    /// `name` is either the matched `SubAgentConfig.name` (when found)
    /// or a generated random name of the form
    /// `"agent-{randomhex}"` (when not found and the caller did
    /// opt in). `is_random_fallback` distinguishes the two.
    pub const ResolvedSubAgent = struct {
        /// Name to record as `agent_name` for the sub-agent's session
        /// and to embed in the session_id suffix.
        name: []const u8,

        /// True iff `agent_name` was provided but not found in any
        /// sub_agents list. False when the name was found.
        is_random_fallback: bool,

        /// The name the LLM originally requested. Useful for
        /// logging. Empty if no `agent_name` was provided.
        requested_name: []const u8,

        /// Resolved LLM endpoint fields (overlay applied).
        model: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        url_style: []const u8,

        /// Resolved `thinking` setting. `null` = "auto" — inherit
        /// from parent's value at run time.
        is_thinking: ?bool,

        /// Resolved `temperature` setting. `null` = "auto" — inherit
        /// from parent's value at run time.
        temperature: ?f32,

        /// System prompt to inject as the sub-agent's
        /// `## Your Active Agent Configuration`. Empty for the
        /// random-fallback case.
        system_prompt: []const u8,

        /// Which sub_agents list supplied this config: the profile
        /// name (e.g. `"profile1"`) or `""` for top-level. Useful
        /// for logging "loaded from profile1's sub_agents" vs
        /// "top-level". Empty for the random-fallback case.
        source: []const u8,
    };

    const ProfileJson = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
        url_style: []const u8 = "openai",
        /// Per-profile sub-agents (typed — defaults to absent). Each entry
        /// is parsed via the existing `SubAgentJson` struct, so unknown
        /// fields are silently ignored and missing fields fall back to
        /// the documented defaults.
        sub_agents: ?[]SubAgentJson = null,
        /// Optional per-profile override for the context window (in tokens).
        /// Null = use LLMModels built-in per-model default.
        max_capacity_tokens: ?u32 = null,
        /// Optional per-profile override for the compaction threshold
        /// percentage (0-100). Null = use built-in 80. Range-validated
        /// at the HTTP layer.
        compaction_threshold_percent: ?u8 = null,
    };

    const LlmConfigJson = struct {
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        url_style: []const u8 = "openai",
        model_compaction_size_kb: usize = 100,
        /// Opt-in: fire an OS notification when an LLM response finishes
        /// with `finish_reason === 'stop'`. Default false (user must
        /// explicitly enable in config to avoid surprise notifications).
        notify_on_complete: bool = false,
        /// Optional top-level override for the context window (in tokens).
        /// Null = fall through to the per-profile override, then built-in.
        max_capacity_token_model: ?u32 = null,
        /// Optional top-level compaction threshold as a percentage (0-100).
        /// Null = fall through to per-profile override, then 80.
        compaction_threshold_percent: ?u8 = null,
        /// Configured MCP servers (snake_case, matches NALAR.md JSON convention).
        mcp_servers: ?std.json.Value = null,
        /// Profiles - parsed as json.Value then converted to map
        profiles_models: ?std.json.Value = null,
        /// Top-level sub-agents array. Raw JSON value parsed via
        /// `parseSubAgentsList` into an owned `[]SubAgentConfig`.
        sub_agents: ?std.json.Value = null,
    };

    /// JSON-side parse struct for a single sub-agent entry. Mirrors
    /// `SubAgentConfig` exactly (borrowed slices from the parsed JSON
    /// blob, vs `SubAgentConfig`'s owned allocator slices). Public so
    /// HTTP handlers can use the same shape for their wire-side parse
    /// targets (`ConfigInput`, `ConfigJson`, etc.).
    pub const SubAgentJson = struct {
        name: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        url_style: []const u8 = "openai",
        api_key: []const u8 = "",
        system_prompt: []const u8 = "",
        /// Optional per-sub-agent override for the context window (in tokens).
        max_capacity_tokens: ?u32 = null,
        /// Optional per-sub-agent override for the compaction threshold
        /// percentage (0-100).
        compaction_threshold_percent: ?u8 = null,
    };

    /// Profiles storage after parsing from JSON
    pub const ProfilesMap = std.StringHashMap(LlmProfile);

    const ProfilesModelsJson = struct {
        profile1: ?ProfileJson = null,
        profile2: ?ProfileJson = null,
        profile3: ?ProfileJson = null,
        profile4: ?ProfileJson = null,
    };

    /// A single header (key/value pair) for an MCP server request.
    pub const McpHeader = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Map of HTTP header name to header value for a single MCP server.
    /// The map owns both the keys and the values (all are allocated strings).
    pub const McpHeadersMap = std.StringHashMap([]const u8);

    /// Typed configuration for a single MCP server.
    ///
    /// `url` and every key/value in `headers` are owned strings
    /// (allocated with the parent `LlmConfig.allocator`).
    pub const McpServerConfig = struct {
        url: []const u8,
        headers: McpHeadersMap,

        /// Returns true when the server is configured and has a non-empty URL.
        pub fn isValid(self: McpServerConfig) bool {
            return self.url.len > 0;
        }
    };

    /// Map of MCP server name (e.g. "context7") to its typed configuration.
    /// The map owns the server-name keys and the `McpServerConfig` payloads.
    pub const McpServersMap = std.StringHashMap(McpServerConfig);

    /// Initialize an `LlmConfig` from disk. When `path` is null (the
    /// default), uses the platform-specific config path returned by
    /// `getDefaultConfigPath` (e.g. `~/.config/nalar/config.json` on
    /// Linux, `~/Library/Application Support/nalar/config.json` on
    /// macOS, `%APPDATA%/nalar/config.json` on Windows).
    ///
    /// **Auto-init on first run**: When `path` is null AND the file at
    /// the resolved default path does not exist, this function creates
    /// a default config with empty placeholder values (via
    /// `writeDefaultConfig`), logs an `info:` message, and proceeds.
    /// The server can then start; downstream LLM calls will fail until
    /// the user edits the placeholder values.
    ///
    /// **Explicit paths are NOT auto-created**: When `path` is non-null
    /// (e.g. `--config /custom/path.json`), a missing file surfaces
    /// `error.ConfigFileNotFound` unchanged — explicit paths are
    /// honored literally.
    ///
    /// **Other errors**: permission denied, invalid JSON, parse errors
    /// surface to the caller unchanged.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8, environment: *std.process.Environ.Map) LoadError!LlmConfig {
        const config_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try getDefaultConfigPath(allocator, environment);
        defer allocator.free(config_path);

        const file = Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // First-run auto-init: only for the default path. An explicit
                // path that doesn't exist is treated as a user error (they
                // asked us to read a specific file and it's missing).
                if (path != null) {
                    std.log.warn("Config file not found at explicit path {s}", .{config_path});
                    return error.ConfigFileNotFound;
                }
                std.log.info(
                    "Config file not found at {s}; auto-creating with empty placeholders. Edit this file to set api_key/model/base_url.",
                    .{config_path},
                );
                writeDefaultConfig(allocator, io, config_path) catch |write_err| {
                    std.log.warn("Failed to auto-create config file {s}: {s}", .{ config_path, @errorName(write_err) });
                    return error.ConfigFileNotFound;
                };
                // Retry the open. If THIS fails (e.g. permission denied on
                // the new file), surface it as ConfigFileNotFound to match
                // the rest of the catch arm's behavior.
                break :blk Io.Dir.openFileAbsolute(io, config_path, .{}) catch |retry_err| {
                    std.log.warn("Failed to open auto-created config file {s}: {s}", .{ config_path, @errorName(retry_err) });
                    return error.ConfigFileNotFound;
                };
            },
            else => {
                std.log.warn("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
                return error.ConfigFileNotFound;
            },
        };
        defer file.close(io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
            std.log.warn("Failed to read config file: {s}", .{@errorName(err)});
            return error.ConfigFileReadError;
        };
        defer allocator.free(content);

        const parsed = json.parseFromSlice(LlmConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.warn("Failed to parse JSON config: {s}", .{@errorName(err)});
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const config_json = parsed.value;

        var config = LlmConfig{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config_json.api_key),
            .model = try allocator.dupe(u8, config_json.model),
            .base_url = try allocator.dupe(u8, config_json.base_url),
            .url_style = try allocator.dupe(u8, config_json.url_style),
            .model_compaction_size_kb = config_json.model_compaction_size_kb,
            .notify_on_complete = config_json.notify_on_complete,
            // Top-level compaction defaults — restored in plan
            // 2026-07-07-compaction-inline. Persisted as raw optional
            // values; cascade logic in `maxCapacityForModel` /
            // `compactionThresholdPercent` honors null = fall through.
            .max_capacity_token_model = config_json.max_capacity_token_model,
            .compaction_threshold_percent = config_json.compaction_threshold_percent,
            .mcpServers_parsed = null,
            .mcp_servers = McpServersMap.init(allocator),
            .profiles_models = ProfilesMap.init(allocator),
            .sub_agents = &.{},
        };
        errdefer {
            allocator.free(config.api_key);
            allocator.free(config.model);
            allocator.free(config.base_url);
            allocator.free(config.url_style);
            freeMcpServersMap(&config.mcp_servers, allocator);
            freeProfilesMap(&config.profiles_models, allocator);
            freeSubAgentsList(config.sub_agents, allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

        if (config_json.mcp_servers) |mcp| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(allocator, mcp, .{}) catch |err| {
                std.log.err("Failed to serialize mcp_servers: {s}", .{@errorName(err)});
                return error.ConfigFileReadError;
            };
            defer allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("Failed to parse mcp_servers: {s}", .{@errorName(err)});
                return error.InvalidJson;
            };
            // Store the full Parsed wrapper so we can call .deinit() on it later
            config.mcpServers_parsed = reparsed;

            // Also populate the typed map. Both representations stay in sync
            // because they are built from the same JSON object.
            const typed = reparsed.value;
            switch (typed) {
                .object => |obj| {
                    config.mcp_servers = parseMcpServersMap(allocator, obj) catch |err| {
                        std.log.err("Failed to parse mcp_servers: {s}", .{@errorName(err)});
                        return error.InvalidJson;
                    };
                },
                else => {},
            }
        }

        // Parse profiles_models into ProfilesMap
        if (config_json.profiles_models) |profiles| {
            const profiles_str = std.json.Stringify.valueAlloc(allocator, profiles, .{}) catch {
                return error.InvalidJson;
            };
            defer allocator.free(profiles_str);

            const profiles_parsed = json.parseFromSlice(ProfilesModelsJson, allocator, profiles_str, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            defer profiles_parsed.deinit();

            const profiles_data = profiles_parsed.value;

            try addProfile(&config.profiles_models, "profile1", profiles_data.profile1, allocator);
            try addProfile(&config.profiles_models, "profile2", profiles_data.profile2, allocator);
            try addProfile(&config.profiles_models, "profile3", profiles_data.profile3, allocator);
            try addProfile(&config.profiles_models, "profile4", profiles_data.profile4, allocator);
        }

        // Parse top-level sub_agents (skip-with-warning on bad entries).
        config.sub_agents = try parseSubAgentsList(allocator, config_json.sub_agents);

        return config;
    }

    /// Free all keys and value strings inside a ProfilesMap, then deinit the map.
    fn freeProfilesMap(map: *ProfilesMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.model);
            allocator.free(entry.value_ptr.base_url);
            allocator.free(entry.value_ptr.thinking);
            allocator.free(entry.value_ptr.temperature);
            allocator.free(entry.value_ptr.api_key);
            allocator.free(entry.value_ptr.url_style);
            freeSubAgentsList(entry.value_ptr.sub_agents, allocator);
        }
        map.deinit();
    }

    /// Add a single profile to the map, duplicating all strings onto the allocator.
    fn addProfile(m: *ProfilesMap, name: []const u8, p: ?ProfileJson, alloc: std.mem.Allocator) !void {
        const profile = p orelse return;

        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);

        const model = try alloc.dupe(u8, profile.model);
        errdefer alloc.free(model);

        const base_url = try alloc.dupe(u8, profile.base_url);
        errdefer alloc.free(base_url);

        const thinking = try alloc.dupe(u8, profile.thinking);
        errdefer alloc.free(thinking);

        const temperature = try alloc.dupe(u8, profile.temperature);
        errdefer alloc.free(temperature);

        const url_style = try alloc.dupe(u8, profile.url_style);
        errdefer alloc.free(url_style);

        const api_key = try alloc.dupe(u8, profile.api_key);
        errdefer alloc.free(api_key);

        const profile_sub_agents = try parseSubAgentsJson(alloc, profile.sub_agents);
        errdefer freeSubAgentsList(profile_sub_agents, alloc);

        try m.put(key, LlmProfile{
            .model = model,
            .base_url = base_url,
            .thinking = thinking,
            .temperature = temperature,
            .api_key = api_key,
            .url_style = url_style,
            .sub_agents = profile_sub_agents,
            // Per-profile compaction overrides — optional, parsed from JSON.
            .max_capacity_tokens = profile.max_capacity_tokens,
            .compaction_threshold_percent = profile.compaction_threshold_percent,
        });
    }

    /// Free all owned memory inside a `SubAgentsList` (per-entry strings
    /// plus the slice header itself). Safe to call with an empty slice.
    fn freeSubAgentsList(slice: SubAgentsList, allocator: std.mem.Allocator) void {
        for (slice) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.model);
            allocator.free(sa.base_url);
            allocator.free(sa.thinking);
            allocator.free(sa.temperature);
            allocator.free(sa.url_style);
            allocator.free(sa.api_key);
            allocator.free(sa.system_prompt);
        }
        if (slice.len > 0) allocator.free(slice);
    }

    /// Parse a `SubAgentsList` from an already-typed `[]SubAgentJson`
    /// (the parse target for `ProfileJson.sub_agents`). Each entry is
    /// required to have a non-empty string `name`; entries with an
    /// empty `name` are skipped with a warning. Returns an empty slice
    /// when `items` is null.
    fn parseSubAgentsJson(allocator: std.mem.Allocator, items: ?[]const SubAgentJson) !SubAgentsList {
        const unwrapped = items orelse return &.{};

        var list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (list.items) |sa| {
                allocator.free(sa.name);
                allocator.free(sa.model);
                allocator.free(sa.base_url);
                allocator.free(sa.thinking);
                allocator.free(sa.temperature);
                allocator.free(sa.url_style);
                allocator.free(sa.api_key);
                allocator.free(sa.system_prompt);
            }
            list.deinit(allocator);
        }

        for (unwrapped) |j| {
            if (j.name.len == 0) {
                std.log.warn("sub_agents entry has empty 'name'; skipping", .{});
                continue;
            }

            const name = try allocator.dupe(u8, j.name);
            errdefer allocator.free(name);
            const model = try allocator.dupe(u8, j.model);
            errdefer allocator.free(model);
            const base_url = try allocator.dupe(u8, j.base_url);
            errdefer allocator.free(base_url);
            const thinking = try allocator.dupe(u8, j.thinking);
            errdefer allocator.free(thinking);
            const temperature = try allocator.dupe(u8, j.temperature);
            errdefer allocator.free(temperature);
            const url_style = try allocator.dupe(u8, j.url_style);
            errdefer allocator.free(url_style);
            const api_key = try allocator.dupe(u8, j.api_key);
            errdefer allocator.free(api_key);
            const system_prompt = try allocator.dupe(u8, j.system_prompt);
            errdefer allocator.free(system_prompt);

            try list.append(allocator, .{
                .name = name,
                .model = model,
                .base_url = base_url,
                .thinking = thinking,
                .temperature = temperature,
                .url_style = url_style,
                .api_key = api_key,
                .system_prompt = system_prompt,
                // Per-sub-agent compaction overrides — optional, parsed from JSON.
                .max_capacity_tokens = j.max_capacity_tokens,
                .compaction_threshold_percent = j.compaction_threshold_percent,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// Parse a `SubAgentsList` from a raw JSON array value. Each entry is
    /// required to have a non-empty string `name`; entries missing that
    /// field (or with malformed JSON) are skipped with a warning. Returns
    /// an empty slice when `value` is null or not an array.
    fn parseSubAgentsList(allocator: std.mem.Allocator, value: ?std.json.Value) !SubAgentsList {
        const unwrapped = value orelse return &.{};
        const arr = switch (unwrapped) {
            .array => |a| a,
            else => return &.{},
        };

        var list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (list.items) |sa| {
                allocator.free(sa.name);
                allocator.free(sa.model);
                allocator.free(sa.base_url);
                allocator.free(sa.thinking);
                allocator.free(sa.temperature);
                allocator.free(sa.url_style);
                allocator.free(sa.api_key);
                allocator.free(sa.system_prompt);
            }
            list.deinit(allocator);
        }

        for (arr.items) |item| {
            const obj = item.object;
            const name_val = obj.get("name") orelse {
                std.log.warn("sub_agents entry missing 'name'; skipping", .{});
                continue;
            };
            if (name_val != .string or name_val.string.len == 0) {
                std.log.warn("sub_agents entry has empty/non-string 'name'; skipping", .{});
                continue;
            }

            const item_str = try std.json.Stringify.valueAlloc(allocator, item, .{});
            defer allocator.free(item_str);
            const parsed = json.parseFromSlice(SubAgentJson, allocator, item_str, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.warn("Failed to parse sub_agents entry: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();

            const j = parsed.value;
            const name = try allocator.dupe(u8, j.name);
            errdefer allocator.free(name);
            const model = try allocator.dupe(u8, j.model);
            errdefer allocator.free(model);
            const base_url = try allocator.dupe(u8, j.base_url);
            errdefer allocator.free(base_url);
            const thinking = try allocator.dupe(u8, j.thinking);
            errdefer allocator.free(thinking);
            const temperature = try allocator.dupe(u8, j.temperature);
            errdefer allocator.free(temperature);
            const url_style = try allocator.dupe(u8, j.url_style);
            errdefer allocator.free(url_style);
            const api_key = try allocator.dupe(u8, j.api_key);
            errdefer allocator.free(api_key);
            const system_prompt = try allocator.dupe(u8, j.system_prompt);
            errdefer allocator.free(system_prompt);

            try list.append(allocator, .{
                .name = name,
                .model = model,
                .base_url = base_url,
                .thinking = thinking,
                .temperature = temperature,
                .url_style = url_style,
                .api_key = api_key,
                .system_prompt = system_prompt,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// Free all owned memory inside a `McpHeadersMap` (header keys + values)
    /// and then deinit the map itself. Safe to call with an empty map.
    fn freeMcpHeadersMap(map: *McpHeadersMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    /// Free all owned memory inside a `McpServersMap`:
    /// the server-name keys, the per-server `url`, and the per-server headers.
    /// Safe to call with an empty map.
    fn freeMcpServersMap(map: *McpServersMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            const server = entry.value_ptr.*;
            allocator.free(server.url);
            freeMcpHeadersMap(&entry.value_ptr.headers, allocator);
        }
        map.deinit();
    }

    /// Parse a `McpHeadersMap` from a JSON object map.
    /// Non-string header values are silently skipped (with a warning).
    fn parseMcpHeadersMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !McpHeadersMap {
        var headers = McpHeadersMap.init(allocator);
        errdefer freeMcpHeadersMap(&headers, allocator);

        var it = obj.iterator();
        while (it.next()) |entry| {
            const header_value: []const u8 = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => {
                    std.log.warn("MCP header '{s}' is not a string; skipping", .{entry.key_ptr.*});
                    continue;
                },
            };
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_dup);

            const value_dup = try allocator.dupe(u8, header_value);
            errdefer allocator.free(value_dup);

            try headers.put(key_dup, value_dup);
        }

        return headers;
    }

    /// Parse a single `McpServerConfig` from a JSON object value.
    /// Returns `null` when `value` is not an object, or when the object
    /// is missing a string `url` field. The `headers` field is optional —
    /// if absent or malformed, the returned config has an empty headers map.
    fn parseMcpServerConfig(allocator: std.mem.Allocator, value: std.json.Value) !?McpServerConfig {
        const obj = switch (value) {
            .object => |o| o,
            else => return null,
        };

        const url_field = obj.get("url") orelse {
            std.log.warn("MCP server config missing 'url'; skipping", .{});
            return null;
        };
        const url_str = switch (url_field) {
            .string => |s| s,
            else => {
                std.log.warn("MCP server 'url' is not a string; skipping", .{});
                return null;
            },
        };
        if (url_str.len == 0) {
            std.log.warn("MCP server 'url' is empty; skipping", .{});
            return null;
        }

        const url_dup = try allocator.dupe(u8, url_str);
        errdefer allocator.free(url_dup);

        var headers = blk: {
            const h = obj.get("headers") orelse break :blk McpHeadersMap.init(allocator);
            break :blk switch (h) {
                .object => |o| try parseMcpHeadersMap(allocator, o),
                else => McpHeadersMap.init(allocator),
            };
        };
        errdefer freeMcpHeadersMap(&headers, allocator);

        return McpServerConfig{
            .url = url_dup,
            .headers = headers,
        };
    }

    /// Parse a full `McpServersMap` from a JSON object map (the body of
    /// `mcp_servers` or `mcpServers`). Malformed entries are skipped with
    /// a warning rather than aborting the whole parse.
    fn parseMcpServersMap(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !McpServersMap {
        var servers = McpServersMap.init(allocator);
        errdefer freeMcpServersMap(&servers, allocator);

        var it = obj.iterator();
        while (it.next()) |entry| {
            const parsed = parseMcpServerConfig(allocator, entry.value_ptr.*) catch |err| {
                std.log.err("Failed to parse MCP server '{s}': {s}", .{ entry.key_ptr.*, @errorName(err) });
                return err;
            };
            const server = parsed orelse continue;

            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_dup);

            try servers.put(key_dup, server);
        }

        return servers;
    }

    pub fn deinit(self: *LlmConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);
        self.allocator.free(self.url_style);

        freeMcpServersMap(&self.mcp_servers, self.allocator);
        freeProfilesMap(&self.profiles_models, self.allocator);
        freeSubAgentsList(self.sub_agents, self.allocator);

        if (self.mcpServers_parsed) |*parsed| {
            parsed.deinit();
        }

        // Free each random sub-agent name that resolveSubAgent
        // generated, then free the tracking slice itself. The
        // names borrow from `self.allocator` and the slice
        // header was grown via `realloc`.
        for (self.random_names) |name| {
            self.allocator.free(name);
        }
        if (self.random_names.len > 0) {
            self.allocator.free(self.random_names);
        }
    }

    pub fn clone(self: *const LlmConfig) LoadError!LlmConfig {
        var config = LlmConfig{
            .allocator = self.allocator,
            .api_key = try self.allocator.dupe(u8, self.api_key),
            .model = try self.allocator.dupe(u8, self.model),
            .base_url = try self.allocator.dupe(u8, self.base_url),
            .url_style = try self.allocator.dupe(u8, self.url_style),
            .model_compaction_size_kb = self.model_compaction_size_kb,
            .notify_on_complete = self.notify_on_complete,
            // Top-level compaction defaults — primitive copies, no
            // allocation needed (they're plain optionals).
            .max_capacity_token_model = self.max_capacity_token_model,
            .compaction_threshold_percent = self.compaction_threshold_percent,
            .mcpServers_parsed = null,
            .mcp_servers = McpServersMap.init(self.allocator),
            .profiles_models = ProfilesMap.init(self.allocator),
            .sub_agents = &.{},
        };
        errdefer {
            self.allocator.free(config.api_key);
            self.allocator.free(config.model);
            self.allocator.free(config.base_url);
            self.allocator.free(config.url_style);
            freeMcpServersMap(&config.mcp_servers, self.allocator);
            freeProfilesMap(&config.profiles_models, self.allocator);
            freeSubAgentsList(config.sub_agents, self.allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

        if (self.mcpServers_parsed) |existing| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(self.allocator, existing.value, .{}) catch {
                return error.InvalidJson;
            };
            defer self.allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, self.allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            config.mcpServers_parsed = reparsed;
        }

        // Deep-copy the typed MCP servers map.
        var mcp_it = self.mcp_servers.iterator();
        while (mcp_it.next()) |entry| {
            const src = entry.value_ptr.*;

            var cloned_headers = McpHeadersMap.init(self.allocator);
            errdefer freeMcpHeadersMap(&cloned_headers, self.allocator);

            var h_it = src.headers.iterator();
            while (h_it.next()) |h| {
                const k = try self.allocator.dupe(u8, h.key_ptr.*);
                errdefer self.allocator.free(k);
                const v = try self.allocator.dupe(u8, h.value_ptr.*);
                errdefer self.allocator.free(v);
                try cloned_headers.put(k, v);
            }

            const url_dup = try self.allocator.dupe(u8, src.url);
            errdefer self.allocator.free(url_dup);

            const key_dup = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_dup);

            try config.mcp_servers.put(key_dup, McpServerConfig{
                .url = url_dup,
                .headers = cloned_headers,
            });
        }

        // Clone all profiles.
        //
        // NOTE: per-profile `sub_agents` is NOT preserved in the clone — we
        // pass `null` to `addProfile` here, accepting this limitation. The
        // top-level `sub_agents` is fully cloned (see below). Preserving
        // per-profile sub_agents through clone would require retaining the
        // original `std.json.Value` of the per-profile array (or another
        // round-trip serialization), which is out of scope for this change.
        // See `sub_agents: per-profile sub_agents are parsed` test for the
        // parse side, which works correctly.
        var it = self.profiles_models.iterator();
        while (it.next()) |entry| {
            try addProfile(
                &config.profiles_models,
                entry.key_ptr.*,
                ProfileJson{
                    .model = entry.value_ptr.model,
                    .base_url = entry.value_ptr.base_url,
                    .thinking = entry.value_ptr.thinking,
                    .temperature = entry.value_ptr.temperature,
                    .api_key = entry.value_ptr.api_key,
                    .url_style = entry.value_ptr.url_style,
                    .sub_agents = null,
                },
                self.allocator,
            );
        }

        // Deep-copy top-level sub_agents into a freshly allocated slice.
        var sub_agents_list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (sub_agents_list.items) |sa| {
                self.allocator.free(sa.name);
                self.allocator.free(sa.model);
                self.allocator.free(sa.base_url);
                self.allocator.free(sa.thinking);
                self.allocator.free(sa.temperature);
                self.allocator.free(sa.url_style);
                self.allocator.free(sa.api_key);
                self.allocator.free(sa.system_prompt);
            }
            sub_agents_list.deinit(self.allocator);
        }
        for (self.sub_agents) |sa| {
            try sub_agents_list.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, sa.name),
                .model = try self.allocator.dupe(u8, sa.model),
                .base_url = try self.allocator.dupe(u8, sa.base_url),
                .thinking = try self.allocator.dupe(u8, sa.thinking),
                .temperature = try self.allocator.dupe(u8, sa.temperature),
                .url_style = try self.allocator.dupe(u8, sa.url_style),
                .api_key = try self.allocator.dupe(u8, sa.api_key),
                .system_prompt = try self.allocator.dupe(u8, sa.system_prompt),
            });
        }
        config.sub_agents = try sub_agents_list.toOwnedSlice(self.allocator);

        return config;
    }

    pub fn validate(self: *const LlmConfig) LoadError!void {
        if (self.api_key.len == 0) {
            std.log.warn("Missing required field: api_key", .{});
            return error.MissingRequiredField;
        }
        if (self.model.len == 0) {
            std.log.warn("Missing required field: model", .{});
            return error.MissingRequiredField;
        }
        if (self.base_url.len == 0) {
            std.log.warn("Missing required field: base_url", .{});
            return error.MissingRequiredField;
        }
    }

    /// Convenience accessor — returns the live json.Value or null.
    pub fn mcpServers(self: *const LlmConfig) ?json.Value {
        return if (self.mcpServers_parsed) |p| p.value else null;
    }

    /// Returns true if any MCP servers are configured.
    pub fn hasMcpServers(self: *const LlmConfig) bool {
        return self.mcp_servers.count() > 0;
    }

    /// Returns true if a server with the given name is configured.
    /// Lookup is by direct hash match on the server name key.
    pub fn hasMcpServer(self: *const LlmConfig, name: []const u8) bool {
        return self.mcp_servers.contains(name);
    }

    /// Get the typed configuration for a single MCP server by name.
    /// Returns null when no server with that name is configured.
    /// The returned `McpServerConfig` borrows from `self` — the lifetime
    /// is tied to this `LlmConfig` (do not outlive the config).
    pub fn mcpServerConfig(self: *const LlmConfig, name: []const u8) ?McpServerConfig {
        const entry = self.mcp_servers.getEntry(name) orelse return null;
        return entry.value_ptr.*;
    }

    /// Get the URL for a single MCP server, or null when not configured.
    /// The returned slice borrows from `self` (do not outlive the config).
    pub fn mcpServerUrl(self: *const LlmConfig, name: []const u8) ?[]const u8 {
        return if (self.mcpServerConfig(name)) |c| c.url else null;
    }

    /// Returns the number of configured MCP servers.
    pub fn mcpServerCount(self: *const LlmConfig) u32 {
        return @intCast(self.mcp_servers.count());
    }

    /// Look up a profile by name (the key in `profiles_models`). Returns null when
    /// not configured. The returned `LlmProfile` borrows from `self` — the lifetime
    /// is tied to this `LlmConfig` (do not outlive the config).
    pub fn getProfile(self: *const LlmConfig, name: []const u8) ?LlmProfile {
        const entry = self.profiles_models.getEntry(name) orelse return null;
        return entry.value_ptr.*;
    }

    /// Returns true if a profile with the given name exists and has a non-empty
    /// `model` field. Use this before calling `getProfile` if you need to know
    /// whether resolution will succeed.
    pub fn hasProfile(self: *const LlmConfig, name: []const u8) bool {
        if (self.profiles_models.getEntry(name)) |entry| {
            return entry.value_ptr.model.len > 0;
        }
        return false;
    }

    /// Look up a top-level sub-agent by name. Returns null when not configured.
    /// The returned `SubAgentConfig` borrows from `self` — its lifetime is
    /// tied to this `LlmConfig` (do not outlive the config).
    pub fn getSubAgent(self: *const LlmConfig, name: []const u8) ?SubAgentConfig {
        for (self.sub_agents) |sa| {
            if (std.mem.eql(u8, sa.name, name)) return sa;
        }
        return null;
    }

    /// Returns true if a top-level sub-agent with the given name is configured.
    pub fn hasSubAgent(self: *const LlmConfig, name: []const u8) bool {
        return self.getSubAgent(name) != null;
    }

    /// Returns the number of top-level sub-agents.
    pub fn subAgentCount(self: *const LlmConfig) u32 {
        return @intCast(self.sub_agents.len);
    }

    /// Resolve a sub-agent by name, applying the v1 lookup rules:
    ///   1. If `profile_name` is non-empty AND a profile with that name
    ///      exists, search `profile.sub_agents` first.
    ///   2. Fall back to `self.sub_agents` (top-level).
    ///
    /// If `agent_name` is empty OR not found in either list, the returned
    /// struct has `is_random_fallback = true`, a generated random `name`
    /// of the form `"agent-{nanoseconds}-{randomhex}"`, and the
    /// orchestrator's default `model` / `api_key` / `base_url` /
    /// `url_style` / empty `system_prompt`.
    ///
    /// The returned struct's LLM fields are *overlays* on the
    /// orchestrator's defaults: any field that's empty in the matched
    /// `SubAgentConfig` falls through to the orchestrator's value
    /// (the caller is expected to apply the overlay against the
    /// parent's already-resolved values — which is what
    /// `RunParamsNew.sub_agent_overrides` does).
    ///
    /// `thinking` and `temperature` are resolved into the strongly-typed
    /// `?bool` / `?f32` shapes the workflow needs. `"auto"` (the
    /// default in `SubAgentConfig`) maps to `null` ("inherit from
    /// parent").
    ///
    /// `is_random_fallback` is true iff `agent_name` was provided but
    /// not found in any sub_agents list. It's `false` when the name
    /// was found. Callers that pass `agent_name = ""` (i.e. did not
    /// opt in) should not call this function — just use the
    /// orchestrator's default values directly.
    pub fn resolveSubAgent(
        self: *LlmConfig,
        profile_name: []const u8,
        agent_name: []const u8,
    ) ResolvedSubAgent {
        // 1. Per-profile lookup (when a profile is selected). The
        // profile's `sub_agents` list is consulted first so a
        // specialized sub-agent (e.g. a code-reviewer model only
        // available on profile1) is preferred over the top-level
        // config's general-purpose list.
        if (profile_name.len > 0) {
            if (self.getProfile(profile_name)) |profile| {
                if (profile.sub_agents.len > 0) {
                    for (profile.sub_agents) |sa| {
                        if (std.mem.eql(u8, sa.name, agent_name)) {
                            return self.buildResolvedFromConfig(sa, agent_name, profile_name);
                        }
                    }
                }
            }
            // Profile not found OR profile has no sub_agents
            // matching the name: fall through to the top-level
            // lookup. (We deliberately do NOT warn here — empty
            // sub_agents on a profile is a normal configuration
            // and per-profile sub_agents are an optional override.
            // The caller can still get `is_random_fallback = true`
            // if the top-level list also lacks the name.)
        }

        // 2. Top-level lookup.
        if (self.getSubAgent(agent_name)) |sa| {
            return self.buildResolvedFromConfig(sa, agent_name, "");
        }

        // 3. Not found — random fallback. The random name is
        // tracked in `self.random_names` so it can be freed in
        // `deinit`. We do this BEFORE returning so the caller can
        // safely use the borrowed `name` slice.
        const random_name = generateRandomAgentName(self.allocator) catch blk: {
            // Last-ditch fallback: empty string. Callers that get
            // an empty name still see `is_random_fallback = true`
            // and can show a degraded UX (the session_id will fall
            // back to the LLM-provided name).
            break :blk "";
        };
        // Track the name for cleanup in deinit (no-op for empty
        // string fallback). We reallocate the tracking slice to
        // grow by one; on failure, we leave `random_names`
        // unchanged (the leaked name is the lesser evil compared
        // to a double-free).
        if (random_name.len > 0) {
            const new_len = self.random_names.len + 1;
            var grown: [][]u8 = self.allocator.realloc(self.random_names, new_len) catch blk: {
                // realloc failed — try a fresh allocation and copy.
                const fresh = self.allocator.alloc([]u8, new_len) catch break :blk &.{};
                if (fresh.len == new_len and self.random_names.len > 0) {
                    @memcpy(fresh[0..self.random_names.len], self.random_names);
                }
                break :blk fresh;
            };
            if (grown.len == new_len) {
                grown[self.random_names.len] = @constCast(random_name);
                self.random_names = grown;
            }
        }
        return ResolvedSubAgent{
            .name = random_name,
            .is_random_fallback = true,
            .requested_name = agent_name,
            .model = self.model,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .url_style = self.url_style,
            .is_thinking = null,
            .temperature = null,
            .system_prompt = "",
            .source = "",
        };
    }

    /// Internal helper — convert a matched `SubAgentConfig` into a
    /// `ResolvedSubAgent` with string→bool/f32 parsing for `thinking` /
    /// `temperature`. Empty string fields in `sa` fall through to the
    /// orchestrator's values (overlay semantics).
    fn buildResolvedFromConfig(
        self: *const LlmConfig,
        sa: SubAgentConfig,
        requested_name: []const u8,
        source: []const u8,
    ) ResolvedSubAgent {
        // thinking: "auto" → null (inherit). "true" → true. "false" → false.
        // Any other value → null (treat as auto).
        const resolved_thinking: ?bool = blk: {
            if (std.mem.eql(u8, sa.thinking, "auto")) break :blk null;
            if (std.mem.eql(u8, sa.thinking, "true")) break :blk true;
            if (std.mem.eql(u8, sa.thinking, "false")) break :blk false;
            break :blk null;
        };

        // temperature: "auto" → null. Numeric → parseFloat. Anything
        // else → null.
        const resolved_temperature: ?f32 = blk: {
            if (std.mem.eql(u8, sa.temperature, "auto")) break :blk null;
            break :blk std.fmt.parseFloat(f32, sa.temperature) catch null;
        };

        return ResolvedSubAgent{
            .name = sa.name,
            .is_random_fallback = false,
            .requested_name = requested_name,
            // Overlay: empty field in SubAgentConfig → orchestrator default.
            .model = if (sa.model.len > 0) sa.model else self.model,
            .base_url = if (sa.base_url.len > 0) sa.base_url else self.base_url,
            .api_key = if (sa.api_key.len > 0) sa.api_key else self.api_key,
            .url_style = if (sa.url_style.len > 0) sa.url_style else self.url_style,
            .is_thinking = resolved_thinking,
            .temperature = resolved_temperature,
            .system_prompt = sa.system_prompt,
            .source = source,
        };
    }

    /// Resolve the effective max-context-window in tokens for a given
    /// model under the optional profile + sub-agent scope. Cascade order:
    ///   1. `sub_agent.max_capacity_tokens` (if `sub_agent` is non-null
    ///      and the field is set)
    ///   2. `profile.max_capacity_tokens` (if `profile` is non-null and
    ///      the field is set)
    ///   3. `defaults.max_capacity_token_model` (top-level override;
    ///      `null` falls through to step 4). Restored in plan
    ///      2026-07-07-compaction-inline so the Defaults tab's value
    ///      flows through to chats that don't set a per-profile override.
    ///   4. `LLMModels.getModelTokenCount(model_name)` (built-in default)
///
/// `defaults` should be `*const LlmConfig` — typically the orchestrator's
/// own config (the same `self` that's calling this function). Pass `null`
/// to skip step 3 and fall straight through to the built-in default.
///
/// Use this everywhere a "what's the effective context window for
/// THIS chat?" answer is needed instead of calling
/// `LLMModels.getModelTokenCount` directly.
    pub fn maxCapacityForModel(
        self: *const LlmConfig,
        profile: ?*const LlmProfile,
        sub_agent: ?*const SubAgentConfig,
        defaults: ?*const LlmConfig,
        model_name: []const u8,
    ) u32 {
        _ = self;
        if (sub_agent) |sa| if (sa.max_capacity_tokens) |override| return override;
        if (profile) |p| if (p.max_capacity_tokens) |override| return override;
        if (defaults) |d| if (d.max_capacity_token_model) |override| return override;
        return LLMModels.getModelTokenCount(model_name);
    }

    /// Resolve the compaction threshold as a percentage (0-100). Cascade
    /// order (same shape as `maxCapacityForModel`):
    ///   1. `sub_agent.compaction_threshold_percent` (if non-null and set)
    ///   2. `profile.compaction_threshold_percent` (if non-null and set)
    ///   3. `defaults.compaction_threshold_percent` (top-level override;
    ///      `null` falls through to step 4). Restored in plan
    ///      2026-07-07-compaction-inline.
    ///   4. `80` (the historical hardcoded value in `LLMModels.isDoCompact`)
    pub fn compactionThresholdPercent(
        self: *const LlmConfig,
        profile: ?*const LlmProfile,
        sub_agent: ?*const SubAgentConfig,
        defaults: ?*const LlmConfig,
    ) u8 {
        _ = self;
        if (sub_agent) |sa| if (sa.compaction_threshold_percent) |override| return override;
        if (profile) |p| if (p.compaction_threshold_percent) |override| return override;
        if (defaults) |d| if (d.compaction_threshold_percent) |override| return override;
        return 80;
    }

    /// The default `config.json` content written on first run (when no
    /// config file exists at the platform-default path). All required
    /// fields are present as empty strings — the user MUST edit this
    /// file and add `api_key`, `model`, and `base_url` before LLM calls
    /// will succeed. Optional fields are populated with their documented
    /// defaults so a subsequent `LlmConfig.init` re-parse yields a
    /// well-formed `LlmConfig`.
    pub const defaultConfigJson: []const u8 =
        \\{
        \\  "api_key": "",
        \\  "model": "",
        \\  "base_url": "",
        \\  "url_style": "openai",
        \\  "model_compaction_size_kb": 100,
        \\  "notify_on_complete": false,
        \\  "max_capacity_token_model": null,
        \\  "compaction_threshold_percent": null
        \\}
    ;

    /// Write `defaultConfigJson` to `path`, creating any missing parent
    /// directories (mkdir -p semantics). Overwrites any existing file at
    /// the path (the caller is expected to NOT call this on an
    /// already-existing config — see `LlmConfig.init` for the auto-init
    /// flow that gates the call on `error.ConfigFileNotFound`).
    ///
    /// Returns `error.ConfigDirNotFound` when the parent directory
    /// cannot be created (e.g. permission denied, invalid path) or
    /// `error.ConfigFileReadError` on a write failure. The caller is
    /// expected to log the error and surface it as appropriate.
    pub fn writeDefaultConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!void {
        _ = allocator; // unused in current implementation, kept for future use

        // Ensure the parent directory exists (mkdir -p semantics).
        // std.Io.Dir.cwd().createDirPath is the project-wide pattern for
        // "create nested dirs relative to cwd" (see Logger.zig:136,
        // add_skill.zig:108). It handles both "dir already exists" and
        // "dir does not exist" without error. It does NOT assert the
        // path is absolute (unlike createDirAbsolute), so both absolute
        // and relative parent paths work. If `dirname` returns null
        // (e.g. `path = "config.json"` or `/config.json`), we skip this
        // step — the file goes in the cwd (or the root, for absolute
        // paths with no parent) directly. Note: Zig 0.16's
        // `std.fs.path.dirname` returns either null OR a slice of
        // length >= 1, so no inner length check is needed.
        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(io, parent) catch |err| {
                std.log.warn("Failed to create config dir {s}: {s}", .{ parent, @errorName(err) });
                return error.ConfigDirNotFound;
            };
        }

        // Write the default config. .truncate = true means any stale
        // file at `path` is replaced atomically by the kernel.
        const file = Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch |err| {
            std.log.warn("Failed to create config file {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
        defer file.close(io);

        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        writer.interface.writeAll(defaultConfigJson) catch |err| {
            std.log.warn("Failed to write default config to {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
        writer.interface.flush() catch |err| {
            std.log.warn("Failed to flush default config to {s}: {s}", .{ path, @errorName(err) });
            return error.ConfigFileReadError;
        };
    }
};

/// Generate a random sub-agent name of the form
/// `"agent-{randomhex}"` for the random-fallback case when a
/// requested `agent_name` is not found in any sub_agents list.
///
/// Allocates the formatted name on `allocator`. The caller MUST
/// store the returned slice in `LlmConfig.random_names` (via
/// `resolveSubAgent`) so it can be freed in `deinit` — otherwise
/// the memory leaks.
///
/// The 16 hex characters come from a mix of entropy sources
/// available in this codebase: the process ID and stack/heap
/// pointer addresses. This mirrors the pattern in
/// `src/helpers/random.zig` for `generateSessionId` — avoids the
/// `std.crypto.random` API (which doesn't exist in this Zig 0.16
/// build) while still producing effectively-unique names across
/// parallel sub-agents.
fn generateRandomAgentName(allocator: std.mem.Allocator) ![]u8 {
    // 8 bytes of pseudo-random entropy → 16 hex chars.
    var entropy_bytes: [8]u8 = undefined;
    const pid: u64 = switch (builtin.os.tag) {
        .linux, .macos => @intCast(std.c.getpid()),
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => 0,
    };
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy_bytes));
    const alloc_addr: u64 = @intCast(@intFromPtr(allocator.ptr));
    const entropy: u64 = pid ^ (stack_addr << 17) ^ (alloc_addr << 33);
    @as(*u64, @ptrCast(@alignCast(&entropy_bytes))).* = entropy;

    var out_buf: [22]u8 = undefined;
    @memcpy(out_buf[0..6], "agent-");
    const hex_chars = "0123456789abcdef";
    for (entropy_bytes, 0..) |b, i| {
        out_buf[6 + i * 2] = hex_chars[b >> 4];
        out_buf[6 + i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return allocator.dupe(u8, &out_buf);
}

pub fn getDefaultConfigDir(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const app_name = "nalar";

    switch (builtin.os.tag) {
        .windows => {
            const appdata = environment.get("APPDATA") orelse {
                std.log.warn("APPDATA environment variable not set", .{});
                return error.ConfigDirNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, app_name });
        },
        .macos => {
            const home = environment.get("HOME") orelse {
                std.log.warn("HOME environment variable not set", .{});
                return error.HomeNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{
                home, "Library", "Application Support", app_name,
            });
        },
        else => {
            if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
                return std.fs.path.join(allocator, &[_][]const u8{ xdg_config, app_name });
            }
            const home = environment.get("HOME") orelse {
                std.log.warn("HOME environment variable not set", .{});
                return error.MissingRequiredField;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", app_name });
        },
    }
}

pub fn getDefaultConfigPath(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const config_dir = try getDefaultConfigDir(allocator, environment);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
}

pub fn loadDefault(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError!LlmConfig {
    return LlmConfig.init(allocator, null, environment);
}

test {
    _ = @import("config_test.zig");
}
