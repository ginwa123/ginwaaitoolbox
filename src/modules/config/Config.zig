const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const LLMModels = @import("../agent/LLMModels.zig");
const helpers = @import("helpers");
const parse_thinking = @import("parse_thinking.zig");

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
    /// When true, fire an OS-level notification when the LLM workflow
    /// hits a transport error, retries exhaust (TooManyRetries), or
    /// the outer agentic loop catches an unrecoverable error. Mirrors
    /// `notify_on_complete` (off by default — the user opts in).
    /// Fired from `workflow.zig` at three sites: (1) the
    /// `callDynamicAgentNew` catch, (2) the TooManyRetries hard bail,
    /// (3) the outer `runAgenticMultiStepnew` catch. Body is the
    /// captured `reason_error` + server detail, truncated to 200 chars.
    notify_on_error: bool = false,
    /// Delay in milliseconds that the workflow sleeps before retrying a
    /// failed `callDynamicAgentNew` call. 0 = no delay (current behavior,
    /// the retry fires immediately on the next loop iteration). Upper
    /// bound is 60 000 ms (1 min) — beyond that, the user should cancel
    /// and start a new session. Range-validated at the HTTP layer.
    /// Plan 2026-07-15-retry-delay.
    retry_delay_ms: u32 = 0,
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
    /// Plan 2026-08-06-set-active-profile-default — optional name of
    /// a profile in `profiles_models` that the workflow uses as the
    /// default when neither the session's `selected_profile_model`
    /// nor the POST body's `selected_profile_model` is set. Set by
    /// the user via NalarSettings → "Set as active profile"; falls
    /// through to top-level config when the named profile is missing
    /// or when the field itself is `null`. Empty string is normalized
    /// to `null` on load (the PUT handler also coerces `""` → null).
    active_profile: ?[]const u8 = null,
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
        /// `thinking_budget_tokens` outside the (0, 2_000_000] range.
        /// Surfaced by the HTTP PUT handler (plan 2026-08-23-model-thinking).
        /// The Anthropic API rejects budgets that violate the 1024 floor
        /// and the strict-less-than-max_tokens ceiling; we pre-clamp at the
        /// request-build site, so the only way a bad value reaches here is
        /// a hand-edited config or a malformed PUT body.
        InvalidThinkingBudgetTokens,
        /// `reasoning_effort` outside the {low, medium, high, auto} set.
        /// Surfaced by the HTTP PUT handler via the `parse_thinking`
        /// helper.
        InvalidReasoningEffort,
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
        /// Anthropic-only: override for `thinking.budget_tokens`. When
        /// set, used directly by `buildJsonAnthropicRequest` (clamped
        /// to >=1024 and <max_tokens). When null AND `thinking == "on"`,
        /// the agent falls back to the 50%-of-max heuristic; when
        /// `thinking == "auto"`, the agent emits Anthropic's
        /// `type: "adaptive"` mode and lets the model pick its own
        /// budget (Sonnet 4.5+ recommendation). OpenAI-style URLs
        /// ignore this field — they use `reasoning_effort` instead.
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
        /// One of "low" | "medium" | "high" | "auto". Validated by
        /// `parse_thinking.parseReasoningEffort`. `null` = omit from
        /// the request body (model-default reasoning). Anthropic-style
        /// URLs ignore this field entirely.
        reasoning_effort: ?[]const u8 = null,
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
        /// Anthropic-only override for `thinking.budget_tokens`. See
        /// `LlmProfile.thinking_budget_tokens` for full semantics.
        /// `null` = inherit from the parent profile.
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
        /// See `LlmProfile.reasoning_effort` for full semantics.
        /// `null` = inherit from the parent profile.
        reasoning_effort: ?[]const u8 = null,
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

        /// Resolved Anthropic `thinking.budget_tokens` override. `null`
        /// = inherit from the parent profile. Range-validated upstream
        /// (HTTP layer rejects 0 or > 2_000_000).
        thinking_budget_tokens: ?u32,

        /// Resolved OpenAI `reasoning_effort` value (already validated
        /// to one of "low" | "medium" | "high" | "auto"). `null` =
        /// inherit from the parent profile.
        reasoning_effort: ?[]const u8,

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
        /// Anthropic-only override for `thinking.budget_tokens`. Range-
        /// validated upstream (HTTP layer rejects 0 or > 2_000_000).
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
        /// Parsed via `parse_thinking.parseReasoningEffort`; a bad
        /// value here surfaces at HTTP layer as `InvalidReasoningEffort`.
        reasoning_effort: ?[]const u8 = null,
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
        /// Opt-in: fire an OS notification when the LLM workflow hits an
        /// error (transport failure, TooManyRetries, outer catch). Default
        /// false. Mirrors `notify_on_complete`; default off so a brand-new
        /// install is silent on errors too.
        notify_on_error: bool = false,
        /// Delay in milliseconds before retrying a failed workflow call.
        /// See `LlmConfig.retry_delay_ms` for semantics. Plan
        /// 2026-07-15-retry-delay.
        retry_delay_ms: u32 = 0,
        /// Optional top-level override for the context window (in tokens).
        /// Null = fall through to the per-profile override, then built-in.
        max_capacity_token_model: ?u32 = null,
        /// Optional top-level compaction threshold as a percentage (0-100).
        /// Null = fall through to per-profile override, then 80.
        compaction_threshold_percent: ?u8 = null,
        /// Plan 2026-08-06-set-active-profile-default — name of the
        /// profile to use as the default when no other selection is
        /// set. Round-tripped as a top-level config key so the
        /// NalarSettings "Set as active profile" UI persists across
        /// reloads. The PUT handler in `nalar_config_put.zig` coerces
        /// empty string → null so a manual JSON edit of `""` is
        /// equivalent to deleting the key.
        active_profile: ?[]const u8 = null,
        /// Configured MCP servers (snake_case, matches NALAR.md JSON convention).
        mcp_servers: ?std.json.Value = null,
        /// Profiles - parsed as json.Value then converted to map
        profiles_models: ?std.json.Value = null,
        /// Top-level sub-agents array. Raw JSON value parsed via
        /// `parseSubAgentsList` into an owned `[]SubAgentConfig`.
        sub_agents: ?std.json.Value = null,
        /// Stable per-install UUID used as the LLM-API end-user identifier.
        /// Empty string when missing from the parsed JSON (legacy configs).
        /// `LlmConfig.init` auto-migrates empty values by generating a fresh
        /// UUID and rewriting the config file atomically.
        user_identifier: []const u8 = "",
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
        /// Anthropic-only override for `thinking.budget_tokens`. See
        /// `LlmProfile.thinking_budget_tokens`.
        thinking_budget_tokens: ?u32 = null,
        /// OpenAI-style `reasoning_effort`. See `LlmProfile.reasoning_effort`.
        reasoning_effort: ?[]const u8 = null,
    };

    /// Profiles storage after parsing from JSON
    pub const ProfilesMap = std.StringHashMap(LlmProfile);

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
    /// Each entry is EITHER an HTTP server (with `url` + optional
    /// `headers`) OR a stdio server (with `command` + optional `args`
    /// + optional `cwd`). Exactly one transport must be present —
    /// entries with both, neither, or empty discriminators are skipped
    /// at parse time with a warning.
    ///
    /// All string fields are owned (allocated with the parent
    /// `LlmConfig.allocator`). `args` is an owned slice of owned
    /// strings — freed in `freeMcpServersMap`.
    pub const McpServerConfig = struct {
        /// HTTP transport: the URL of the MCP server. Null for stdio entries.
        url: ?[]const u8,
        /// HTTP transport: optional request headers (e.g. `Authorization`).
        headers: McpHeadersMap,
        /// stdio transport: the command to spawn. Null for HTTP entries.
        command: ?[]const u8,
        /// stdio transport: command-line args. Null when not specified.
        args: ?[]const []const u8,
        /// stdio transport: working directory. Null = inherit from parent.
        cwd: ?[]const u8,

        pub const Transport = enum { http, stdio };

        /// Returns the transport discriminator — derived from which
        /// field is set. `command` takes precedence over `url` (so a
        /// future "hybrid" entry would default to stdio).
        pub fn transport(self: McpServerConfig) Transport {
            if (self.command) |c| if (c.len > 0) return .stdio;
            return .http;
        }

        /// Returns true when the server is configured with exactly one
        /// non-empty transport (HTTP url OR stdio command, but not both,
        /// not neither, not either empty).
        pub fn isValid(self: McpServerConfig) bool {
            const has_url = if (self.url) |u| u.len > 0 else false;
            const has_cmd = if (self.command) |c| c.len > 0 else false;
            return has_url != has_cmd; // exactly one
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
            .notify_on_error = config_json.notify_on_error,
            .retry_delay_ms = config_json.retry_delay_ms,
            // Top-level compaction defaults — restored in plan
            // 2026-07-07-compaction-inline. Persisted as raw optional
            // values; cascade logic in `maxCapacityForModel` /
            // `compactionThresholdPercent` honors null = fall through.
            .max_capacity_token_model = config_json.max_capacity_token_model,
            .compaction_threshold_percent = config_json.compaction_threshold_percent,
            // Plan 2026-08-06-set-active-profile-default — load the
            // user-chosen default profile from JSON. Coerce empty
            // string to null so manual `""` edits don't survive the
            // round-trip (matches `nalar_config_put.zig` PUT coercion).
            .active_profile = blk: {
                const raw = config_json.active_profile orelse break :blk null;
                if (raw.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, raw);
            },
            .mcpServers_parsed = null,
            .mcp_servers = LlmConfig.McpServersMap.init(allocator),
            .profiles_models = LlmConfig.ProfilesMap.init(allocator),
            .sub_agents = &.{},
        };
        errdefer {
            allocator.free(config.api_key);
            allocator.free(config.model);
            allocator.free(config.base_url);
            allocator.free(config.url_style);
            if (config.active_profile) |ap| allocator.free(ap);
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

        // Parse profiles_models into ProfilesMap.
        //
        // 2026-08-06-config-profiles-arbitrary-keys: the previous
        // implementation parsed `profiles_models` against a hardcoded
        // 4-field schema (profile1..profile4); every other profile
        // name — including the user's "900ribu" — was silently dropped
        // by `parseFromSlice` with `ignore_unknown_fields = true`,
        // causing the workflow to fall through to top-level config
        // when the user picked a profile via the chatview picker.
        //
        // Now we re-stringify the JSON object and reparse it as a
        // generic `json.Value`, then iterate over its keys to feed
        // each entry to `addProfile` under its original key. Same
        // pattern as the existing `mcp_servers` parser above; the
        // extra alloc + parse per profile is negligible (typical
        // configs have 1-5 profiles).
        if (config_json.profiles_models) |profiles| {
            const profiles_str = std.json.Stringify.valueAlloc(allocator, profiles, .{}) catch {
                return error.InvalidJson;
            };
            defer allocator.free(profiles_str);

            const profiles_parsed = json.parseFromSlice(json.Value, allocator, profiles_str, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            defer profiles_parsed.deinit();

            switch (profiles_parsed.value) {
                .object => |obj| {
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        // entry.key_ptr.* is the user-chosen profile
                        // name (e.g. "900ribu"). entry.value_ptr is a
                        // json.Value for the profile object.
                        const profile_json_str = std.json.Stringify.valueAlloc(
                            allocator,
                            entry.value_ptr,
                            .{},
                        ) catch continue;
                        defer allocator.free(profile_json_str);

                        const profile_parsed = json.parseFromSlice(
                            ProfileJson,
                            allocator,
                            profile_json_str,
                            .{ .ignore_unknown_fields = true },
                        ) catch continue;
                        defer profile_parsed.deinit();

                        try addProfile(
                            &config.profiles_models,
                            entry.key_ptr.*,
                            profile_parsed.value,
                            allocator,
                        );
                    }
                },
                else => {},
            }
        }

        // Parse top-level sub_agents (skip-with-warning on bad entries).
        config.sub_agents = try parseSubAgentsList(allocator, config_json.sub_agents);

        // Plan 2026-08-24-config-simplify-remove-defaults: config.json no
        // longer carries top-level api_key/model/base_url/url_style. When
        // absent/empty, derive them from the active profile so every
        // downstream consumer of cfg.model etc. keeps working unchanged.
        // Present keys always win (backward compat with old configs).
        try backfillTopLevelFromProfiles(&config);

        return config;
    }

    /// Derive empty top-level LLM fields from the resolved profile.
    ///
    /// Cascade: `active_profile` → first profile entry (HashMap iteration
    /// order — nondeterministic with multiple profiles; documented as
    /// unspecified. Deterministic-path tests use single-profile fixtures).
    ///
    /// url_style note: `LlmConfigJson.url_style` defaults to "openai", so
    /// an ABSENT key is indistinguishable from explicit-openai post-parse.
    /// Rule: whenever ANY field is backfilled, a non-empty profile
    /// url_style also wins over the parse default (the profile defines the
    /// wire format). An explicitly-set top-level url_style is preserved by
    /// the same rule only when it differs... no — simpler: profile wins for
    /// url_style whenever the other fields needed backfilling AND the
    /// profile's url_style is non-empty. Explicit top-level configs that
    /// set all four keys never enter this path at all.
    fn backfillTopLevelFromProfiles(config: *LlmConfig) LoadError!void {
        const needs_backfill =
            config.model.len == 0 or
            config.base_url.len == 0 or
            config.api_key.len == 0;
        if (!needs_backfill) return;

        // resolveSessionProfileCompat walks selected→active; here there is
        // no session context, so selection is just active_profile.
        var p: ?LlmProfile = config.resolveSessionProfileCompat("");
        if (p == null) {
            // No active profile (or it names a missing entry): fall back to
            // the first profile with a non-empty model.
            var it = config.profiles_models.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.model.len > 0) {
                    p = entry.value_ptr.*;
                    break;
                }
            }
        }
        const prof = p orelse return; // no usable profile → leave as-is

        if (config.model.len == 0) {
            config.model = try config.allocator.dupe(u8, prof.model);
        }
        if (config.base_url.len == 0) {
            config.base_url = try config.allocator.dupe(u8, prof.base_url);
        }
        if (config.api_key.len == 0) {
            config.api_key = try config.allocator.dupe(u8, prof.api_key);
        }
        // url_style: profile-wins rule (see doc comment above). Only when
        // we actually backfilled something AND the profile's style is set.
        if (prof.url_style.len > 0 and !std.mem.eql(u8, config.url_style, prof.url_style)) {
            // Free the old owned slice before replacing (url_style is
            // always heap-owned: duped in init/clone).
            config.allocator.free(config.url_style);
            config.url_style = try config.allocator.dupe(u8, prof.url_style);
        }
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
            if (entry.value_ptr.reasoning_effort) |re| allocator.free(re);
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
            // Model-thinking knobs — Anthropic budget + OpenAI effort.
            .thinking_budget_tokens = profile.thinking_budget_tokens,
            .reasoning_effort = if (profile.reasoning_effort) |re| try alloc.dupe(u8, re) else null,
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
            if (sa.reasoning_effort) |re| allocator.free(re);
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
                // Model-thinking knobs — Anthropic budget + OpenAI effort.
                .thinking_budget_tokens = j.thinking_budget_tokens,
                .reasoning_effort = if (j.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
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
                if (sa.reasoning_effort) |re| allocator.free(re);
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
                // Model-thinking knobs — Anthropic budget + OpenAI effort.
                // Range validation is the HTTP layer's job; this site
                // just threads the JSON-parsed values through.
                .thinking_budget_tokens = j.thinking_budget_tokens,
                .reasoning_effort = if (j.reasoning_effort) |re| try allocator.dupe(u8, re) else null,
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
            freeMcpServerConfig(entry.value_ptr, allocator);
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
    /// has neither a non-empty `url` (HTTP) nor a non-empty `command`
    /// (stdio). The `headers` field is HTTP-only and optional — if
    /// absent or malformed, the returned config has an empty headers map.
    /// The `args` and `cwd` fields are stdio-only and optional.
    fn parseMcpServerConfig(allocator: std.mem.Allocator, value: std.json.Value) !?McpServerConfig {
        const obj = switch (value) {
            .object => |o| o,
            else => return null,
        };

        var config: McpServerConfig = .{
            .url = null,
            .headers = McpHeadersMap.init(allocator),
            .command = null,
            .args = null,
            .cwd = null,
        };
        errdefer freeMcpServerConfig(&config, allocator);

        // ── HTTP branch: `url` field ──────────────────────────────────
        if (obj.get("url")) |url_field| {
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
            config.url = try allocator.dupe(u8, url_str);

            // Headers (HTTP-only).
            if (obj.get("headers")) |h| {
                if (h == .object) {
                    freeMcpHeadersMap(&config.headers, allocator);
                    config.headers = try parseMcpHeadersMap(allocator, h.object);
                }
            }
        }

        // ── stdio branch: `command` field ─────────────────────────────
        if (obj.get("command")) |cmd_field| {
            const cmd_str = switch (cmd_field) {
                .string => |s| s,
                else => {
                    std.log.warn("MCP server 'command' is not a string; skipping", .{});
                    return null;
                },
            };
            if (cmd_str.len == 0) {
                std.log.warn("MCP server 'command' is empty; skipping", .{});
                return null;
            }
            config.command = try allocator.dupe(u8, cmd_str);

            // Args (stdio-only, optional).
            if (obj.get("args")) |args_value| {
                const args_arr = switch (args_value) {
                    .array => |a| a,
                    else => {
                        std.log.warn("MCP server 'args' must be a JSON array of strings; skipping", .{});
                        return null;
                    },
                };
                var args_list: std.ArrayList([]const u8) = .empty;
                defer args_list.deinit(allocator);
                for (args_arr.items) |item| {
                    const s = switch (item) {
                        .string => |x| x,
                        else => continue,
                    };
                    try args_list.append(allocator, try allocator.dupe(u8, s));
                }
                config.args = try args_list.toOwnedSlice(allocator);
            }

            // cwd (stdio-only, optional).
            if (obj.get("cwd")) |cwd_field| {
                if (cwd_field == .string) {
                    config.cwd = try allocator.dupe(u8, cwd_field.string);
                }
            }
        }

        // Validate: exactly one transport present.
        const has_url = if (config.url) |u| u.len > 0 else false;
        const has_cmd = if (config.command) |c| c.len > 0 else false;
        if (has_url == has_cmd) {
            std.log.warn("MCP server config needs exactly one of 'url' or 'command'; skipping", .{});
            return null;
        }

        return config;
    }

    /// Free all owned memory inside a `McpServerConfig` (but NOT the
    /// `McpServersMap` entry itself). Safe to call with partial configs.
    fn freeMcpServerConfig(cfg: *McpServerConfig, allocator: std.mem.Allocator) void {
        if (cfg.url) |u| allocator.free(u);
        if (cfg.command) |c| allocator.free(c);
        if (cfg.args) |a| {
            for (a) |arg| allocator.free(arg);
            allocator.free(a);
        }
        if (cfg.cwd) |c| allocator.free(c);
        freeMcpHeadersMap(&cfg.headers, allocator);
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
        // Plan 2026-08-06-set-active-profile-default — owned slice was
        // duped in `init` only when non-empty.
        if (self.active_profile) |ap| self.allocator.free(ap);

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
            .notify_on_error = self.notify_on_error,
            // Top-level compaction defaults — primitive copies, no
            // allocation needed (they're plain optionals).
            .max_capacity_token_model = self.max_capacity_token_model,
            .compaction_threshold_percent = self.compaction_threshold_percent,
            // Plan 2026-08-06-set-active-profile-default — deep-dupe
            // the user-chosen default profile name (null stays null).
            .active_profile = if (self.active_profile) |ap|
                try self.allocator.dupe(u8, ap)
            else
                null,
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
            if (config.active_profile) |ap| self.allocator.free(ap);
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

        // Deep-copy the typed MCP servers map. Each entry is cloned field
        // by field — only the transport actually in use (url OR command)
        // has its strings duped; the other's slots stay null.
        var mcp_it = self.mcp_servers.iterator();
        while (mcp_it.next()) |entry| {
            const src = entry.value_ptr.*;

            var cloned: McpServerConfig = .{
                .url = null,
                .headers = McpHeadersMap.init(self.allocator),
                .command = null,
                .args = null,
                .cwd = null,
            };
            errdefer freeMcpServerConfig(&cloned, self.allocator);

            var h_it = src.headers.iterator();
            while (h_it.next()) |h| {
                const k = try self.allocator.dupe(u8, h.key_ptr.*);
                errdefer self.allocator.free(k);
                const v = try self.allocator.dupe(u8, h.value_ptr.*);
                errdefer self.allocator.free(v);
                try cloned.headers.put(k, v);
            }

            if (src.url) |u| cloned.url = try self.allocator.dupe(u8, u);
            if (src.command) |c| cloned.command = try self.allocator.dupe(u8, c);
            if (src.cwd) |c| cloned.cwd = try self.allocator.dupe(u8, c);
            if (src.args) |src_args| {
                const args_dup = try self.allocator.alloc([]const u8, src_args.len);
                errdefer self.allocator.free(args_dup);
                for (src_args, 0..) |a, i| {
                    args_dup[i] = try self.allocator.dupe(u8, a);
                }
                cloned.args = args_dup;
            }

            const key_dup = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_dup);

            try config.mcp_servers.put(key_dup, cloned);
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

    /// Input for `addMcpServerStdio` — the stdio-only transport variant
    /// (HTTP follows in a sibling task). All string fields are borrowed;
    /// the primitive deep-copies them into the live `mcp_servers` map.
    pub const AddMcpServerStdioInput = struct {
        /// The server name (key in `mcp_servers`). Must be non-empty and
        /// must not collide with an existing server. Trailing whitespace is
        /// NOT trimmed — the caller is responsible for the exact key.
        name: []const u8,
        /// The command to spawn. Must be non-empty (an empty command would
        /// never reach the `parseMcpServerConfig` validity check anyway).
        command: []const u8,
        /// Optional argv after `command`. `null` means no args. Each entry
        /// is deep-copied into the new `McpServerConfig.args` slice.
        args: ?[]const []const u8 = null,
        /// Optional working directory. `null` means inherit from the parent.
        cwd: ?[]const u8 = null,
    };

    /// Add a new stdio MCP server to the live config in-place. Mutates
    /// `self.mcp_servers` (typed map) AND rebuilds `self.mcpServers_parsed`
    /// (the json.Value mirror used by `mcpServers()` + `buildMCPToolsRun`).
    ///
    /// The caller is responsible for persisting the change to disk (see
    /// `persistMcpServerStdio` for the matching disk-write helper). The
    /// two-step split lets the unit tests exercise the in-memory mutation
    /// without touching disk; the agent-tool exec wrapper chains both.
    ///
    /// Errors:
    ///   - `error.InvalidName` — `name` is empty.
    ///   - `error.DuplicateServer` — `name` is already a key in `mcp_servers`.
    ///   - `error.InvalidCommand` — `command` is empty.
    ///   - propagates `OutOfMemory` from `allocator.dupe` / `ObjectMap.put`.
    ///
    /// Plan: docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
    pub fn addMcpServerStdio(
        self: *LlmConfig,
        input: AddMcpServerStdioInput,
    ) !void {
        // ── 1. Validate ────────────────────────────────────────────────────
        if (input.name.len == 0) return error.InvalidName;
        if (input.command.len == 0) return error.InvalidCommand;
        if (self.mcp_servers.contains(input.name)) return error.DuplicateServer;

        // ── 2. Build the new typed entry ───────────────────────────────────
        var entry: McpServerConfig = .{
            .url = null,
            .headers = McpHeadersMap.init(self.allocator),
            .command = try self.allocator.dupe(u8, input.command),
            .args = null,
            .cwd = if (input.cwd) |c| try self.allocator.dupe(u8, c) else null,
        };
        errdefer freeMcpServerConfig(&entry, self.allocator);

        if (input.args) |src_args| {
            const args_dup = try self.allocator.alloc([]const u8, src_args.len);
            errdefer self.allocator.free(args_dup);
            for (src_args, 0..) |a, i| {
                args_dup[i] = try self.allocator.dupe(u8, a);
            }
            entry.args = args_dup;
        }

        // ── 3. Insert into the typed map ───────────────────────────────────
        // F8 fix: scope the `key_dup` + `entry` ownership transfer inside
        // a labeled block so the `errdefer` only fires on the actual
        // failure path (dupe + put). Once `put` succeeds, the block
        // exits and the errdefer no longer applies — the map owns the
        // key. A later error in `rebuildMcpServersParsed` (OOM etc.)
        // therefore can't double-free `key_dup` via the outer scope's
        // errdefer.
        // The block's only purpose is to scope the `key_dup` + `entry`
        // ownership transfer so the `errdefer self.allocator.free(k)`
        // is dormant after the successful `put`. The map now owns
        // `k`; the constant is captured here only to give Zig a
        // binding for the errdefer (which requires `k` to be a
        // declaration in scope). We mark it `_` because we don't
        // reference it again — the map is the owner.
        const _key_dup = blk: {
            const k = try self.allocator.dupe(u8, input.name);
            errdefer self.allocator.free(k);
            try self.mcp_servers.put(k, entry);
            // Transfer ownership of the entry's heap-allocated fields to
            // the map. `put` COPIES the struct value (which copies
            // POINTERS — the map and the local `entry` now share the
            // same duped strings). Reset the local `entry` so the outer
            // scope's `freeMcpServerConfig` errdefer (declared earlier)
            // is a no-op for these fields; otherwise a later error
            // would double-free strings the map still owns.
            entry = .{
                .url = null,
                .headers = McpHeadersMap.init(self.allocator),
                .command = null,
                .args = null,
                .cwd = null,
            };
            break :blk k;
        };
        _ = _key_dup; // owned by the map now; suppress unused-constant warning

        // ── 4. Rebuild mcpServers_parsed from the typed map ───────────────
        // The typed map is now authoritative — we serialize it back to a
        // json.Value so `mcpServers()` + `buildMCPToolsRun` see the new
        // entry on the next iteration. Old `mcpServers_parsed` is freed.
        try rebuildMcpServersParsed(self);
    }

    /// Serialize the typed `mcp_servers` map back into `mcpServers_parsed`.
    /// Called by `addMcpServerStdio` after each insert; safe to call when
    /// `mcpServers_parsed` is null (re-builds from scratch).
    ///
    /// Each server becomes a JSON object with the same keys as the typed
    /// entry. We deliberately drop the `headers` field when it's empty
    /// (matches `parseMcpServerConfig`'s "absent = empty" convention) and
    /// `args` / `cwd` when they're null. Mirrors the on-disk shape that
    /// `nalar_config_put.zig` writes — `parseMcpServerConfig` accepts
    /// either HTTP (`url` + `headers`) or stdio (`command` + `args` + `cwd`)
    /// and rejects entries with neither or both, so we only emit the keys
    /// the new entry actually uses.
    fn rebuildMcpServersParsed(self: *LlmConfig) !void {
        const allocator = self.allocator;
        var new_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer new_obj.deinit(allocator);

        var it = self.mcp_servers.iterator();
        while (it.next()) |entry| {
            const server_name = entry.key_ptr.*;
            const cfg = entry.value_ptr.*;
            var server_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer server_obj.deinit(allocator);

            if (cfg.url) |u| {
                try server_obj.put(allocator, "url", .{ .string = try allocator.dupe(u8, u) });
            }
            if (cfg.headers.count() > 0) {
                var hdr_obj = try json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer hdr_obj.deinit(allocator);
                var h_it = cfg.headers.iterator();
                while (h_it.next()) |h| {
                    const k = try allocator.dupe(u8, h.key_ptr.*);
                    errdefer allocator.free(k);
                    const v = try allocator.dupe(u8, h.value_ptr.*);
                    errdefer allocator.free(v);
                    try hdr_obj.put(allocator, k, .{ .string = v });
                }
                try server_obj.put(allocator, "headers", .{ .object = hdr_obj });
            }
            if (cfg.command) |c| {
                try server_obj.put(allocator, "command", .{ .string = try allocator.dupe(u8, c) });
            }
            if (cfg.args) |a| {
                // Transfer ownership: `args_arr` (and its duped string items)
                // becomes part of the JSON tree. Do NOT `defer` deinit —
                // it would fire before Stringify reads the array, freeing
                // the items the tree still points to. Instead, free the
                // array later in `freeServerObjValue` (which knows it's an
                // .array variant owned by us).
                var args_arr = json.Array.init(allocator);
                for (a) |arg| {
                    try args_arr.append(.{ .string = try allocator.dupe(u8, arg) });
                }
                try server_obj.put(allocator, "args", .{ .array = args_arr });
            }
            if (cfg.cwd) |c| {
                try server_obj.put(allocator, "cwd", .{ .string = try allocator.dupe(u8, c) });
            }

            const name_dup = try allocator.dupe(u8, server_name);
            errdefer allocator.free(name_dup);
            try new_obj.put(allocator, name_dup, .{ .object = server_obj });
        }

        // Parse the new object map as `mcpServers_parsed`. Round-trip via
        // string serialization is required because json.ObjectMap → json.Value
        // isn't a direct cast — we need a Parsed wrapper. After parseFromSlice
        // returns, the source ObjectMap + everything we put into it is
        // orphaned (Stringify.valueAlloc deep-copied the structure into the
        // serialized buffer; reparsed owns independent copies).
        const serialized = try std.json.Stringify.valueAlloc(allocator, json.Value{ .object = new_obj }, .{});
        defer allocator.free(serialized);
        const reparsed = try json.parseFromSlice(json.Value, allocator, serialized, .{
            .ignore_unknown_fields = true,
        });
        errdefer reparsed.deinit();

        // Free the source tree manually. ObjectMap.deinit only frees the
        // hash map structure — it does NOT recurse into values or free the
        // outer keys. Our shape has duped OUTER keys (server names, owned)
        // + literal INNER keys ("command", "args", etc., NOT owned) +
        // json.Value values that recursively own duped strings.
        freeNewObjDeep(allocator, &new_obj);

        // Free the old mcpServers_parsed (its underlying ObjectMap is now
        // orphaned — we own a fresh one inside `reparsed`). Matches the
        // deinit pattern in `LlmConfig.deinit`.
        if (self.mcpServers_parsed) |*old| old.deinit();
        self.mcpServers_parsed = reparsed;
    }

    /// Free a `new_obj` tree built by `rebuildMcpServersParsed`. The OUTER
    /// keys are duped server names (owned); the INNER keys ("command",
    /// "args", "url", "cwd", "headers") are STRING LITERALS and MUST NOT
    /// be freed. The values inside server_obj own memory (duped strings,
    /// headers sub-map). We exploit that with a dedicated helper rather
    /// than a generic recursive free.
    fn freeNewObjDeep(allocator: std.mem.Allocator, new_obj: *json.ObjectMap) void {
        var it = new_obj.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            freeServerObjDeep(allocator, &kv.value_ptr.object);
        }
        new_obj.deinit(allocator);
    }

    /// Free a single server's ObjectMap. The KEYS are string literals
    /// ("command", "args", "url", "cwd", "headers") — DO NOT free them.
    /// The VALUES own memory (duped strings, headers sub-map).
    fn freeServerObjDeep(allocator: std.mem.Allocator, server_obj: *json.ObjectMap) void {
        var it = server_obj.iterator();
        while (it.next()) |kv| {
            freeServerObjValue(allocator, &kv.value_ptr.*);
        }
        server_obj.deinit(allocator);
    }

    /// Free one value out of a server_obj entry. The captured pattern
    /// `|*arr|` is fragile because switch captures are immutable, so we
    /// pass a pointer to the Value union and dispatch on the active tag.
    fn freeServerObjValue(allocator: std.mem.Allocator, value_ptr: *json.Value) void {
        switch (value_ptr.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| {
                    if (item.* == .string) {
                        allocator.free(item.string);
                    }
                }
                arr.deinit();
            },
            .object => freeHeadersObjDeep(allocator, &value_ptr.object),
            else => {},
        }
    }

    /// Free the headers sub-map. Keys + values are BOTH duped strings.
    fn freeHeadersObjDeep(allocator: std.mem.Allocator, hdr_obj: *json.ObjectMap) void {
        var it = hdr_obj.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.string);
        }
        hdr_obj.deinit(allocator);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Inline tests for `addMcpServerStdio` — plan 2026-08-28-add-mcp-server-agent-tool
    // ─────────────────────────────────────────────────────────────────────

    /// Build a minimal `LlmConfig` for the `addMcpServerStdio` tests. Only
    /// the fields touched by the primitive are wired up; the rest are
    /// sentinel values that `deinit()` doesn't free.
    fn addMcpServerStdioFixture(allocator: std.mem.Allocator) !LlmConfig {
        return .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, ""),
            .model = try allocator.dupe(u8, ""),
            .base_url = try allocator.dupe(u8, ""),
            .url_style = try allocator.dupe(u8, "openai"),
            .model_compaction_size_kb = 100,
            .retry_delay_ms = 0,
            .max_capacity_token_model = null,
            .compaction_threshold_percent = null,
            .active_profile = null,
            .mcpServers_parsed = null,
            .mcp_servers = LlmConfig.McpServersMap.init(allocator),
            .profiles_models = LlmConfig.ProfilesMap.init(allocator),
            .sub_agents = &.{},
            .random_names = &.{},
        };
    }

    test "addMcpServerStdio: valid stdio entry persists command+args+cwd" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "hello",
            .command = "mcp-hello-world",
            .args = &.{ "--port", "3001" },
            .cwd = "/opt/mcp",
        });

        // Typed map populated with deep-copied strings.
        try std.testing.expect(cfg.hasMcpServer("hello"));
        const server = cfg.mcpServerConfig("hello").?;
        try std.testing.expectEqualStrings("mcp-hello-world", server.command.?);
        try std.testing.expectEqualStrings("/opt/mcp", server.cwd.?);
        try std.testing.expectEqual(@as(usize, 2), server.args.?.len);
        try std.testing.expectEqualStrings("--port", server.args.?[0]);
        try std.testing.expectEqualStrings("3001", server.args.?[1]);
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());

        // mcpServers_parsed rebuilt — fetchable via mcpServers() accessor.
        try std.testing.expect(cfg.mcpServers() != null);
        const mcp_val = cfg.mcpServers().?;
        const obj = mcp_val.object;
        try std.testing.expect(obj.get("hello") != null);
        const hello_obj = obj.get("hello").?.object;
        try std.testing.expectEqualStrings("mcp-hello-world", hello_obj.get("command").?.string);
        try std.testing.expectEqualStrings("/opt/mcp", hello_obj.get("cwd").?.string);
    }

    test "addMcpServerStdio: minimal stdio entry (command only, no args/cwd)" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "bare",
            .command = "mcp-server",
        });

        const server = cfg.mcpServerConfig("bare").?;
        try std.testing.expectEqualStrings("mcp-server", server.command.?);
        try std.testing.expect(server.args == null);
        try std.testing.expect(server.cwd == null);
        // Transport discriminator returns stdio when `command` is set.
        try std.testing.expectEqual(LlmConfig.McpServerConfig.Transport.stdio, server.transport());
    }

    test "addMcpServerStdio: empty name returns InvalidName" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        const result = cfg.addMcpServerStdio(.{
            .name = "",
            .command = "x",
        });
        try std.testing.expectError(error.InvalidName, result);
        try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
    }

    test "addMcpServerStdio: empty command returns InvalidCommand" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        const result = cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "",
        });
        try std.testing.expectError(error.InvalidCommand, result);
        try std.testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
    }

    test "addMcpServerStdio: duplicate name returns DuplicateServer and preserves prior entry" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "first-cmd",
            .args = &.{"a"},
        });
        // Second insert with the same name MUST fail — the typed map and
        // mcpServers_parsed are unchanged.
        const result = cfg.addMcpServerStdio(.{
            .name = "ctx",
            .command = "second-cmd",
            .args = &.{"b"},
        });
        try std.testing.expectError(error.DuplicateServer, result);
        try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.count());
        const server = cfg.mcpServerConfig("ctx").?;
        try std.testing.expectEqualStrings("first-cmd", server.command.?);
        try std.testing.expectEqualStrings("a", server.args.?[0]);
    }

    test "addMcpServerStdio: preserves existing servers after a second add" {
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try cfg.addMcpServerStdio(.{ .name = "alpha", .command = "cmd-a" });
        try cfg.addMcpServerStdio(.{ .name = "beta", .command = "cmd-b" });
        try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.count());

        const alpha = cfg.mcpServerConfig("alpha").?;
        try std.testing.expectEqualStrings("cmd-a", alpha.command.?);
        const beta = cfg.mcpServerConfig("beta").?;
        try std.testing.expectEqualStrings("cmd-b", beta.command.?);

        // mcpServers_parsed has BOTH entries.
        const obj = cfg.mcpServers().?.object;
        try std.testing.expect(obj.get("alpha") != null);
        try std.testing.expect(obj.get("beta") != null);
    }

    test "addMcpServerStdio: rebuilds mcpServers_parsed from scratch when previously null" {
        // Guards the "first MCP server ever" path — mcpServers_parsed was
        // never populated, so rebuildMcpServersParsed must create a fresh
        // ObjectMap rather than dereferencing the null one.
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        try std.testing.expect(cfg.mcpServers_parsed == null);
        try cfg.addMcpServerStdio(.{ .name = "first", .command = "cmd-1" });

        try std.testing.expect(cfg.mcpServers_parsed != null);
        try std.testing.expect(cfg.mcpServers() != null);
        try std.testing.expectEqualStrings("cmd-1", cfg.mcpServers().?.object.get("first").?.object.get("command").?.string);
    }

    test "addMcpServerStdio: cloned strings are independent (mutating input doesn't leak)" {
        // The primitive deep-copies every string. We mutate the source
        // slices after the call and assert the typed map's values are
        // unchanged — guards against accidental shallow-copy regression.
        const allocator = std.testing.allocator;
        var cfg = try addMcpServerStdioFixture(allocator);
        defer cfg.deinit();

        var cmd_buf: [16]u8 = undefined;
        const cmd_src = std.fmt.bufPrint(&cmd_buf, "initial", .{}) catch unreachable;
        var cwd_buf: [16]u8 = undefined;
        const cwd_src = std.fmt.bufPrint(&cwd_buf, "/initial", .{}) catch unreachable;

        try cfg.addMcpServerStdio(.{
            .name = "leak-guard",
            .command = cmd_src,
            .cwd = cwd_src,
        });

        // Mutate the source buffers in-place — the typed map must still
        // hold the original bytes (deep copy semantics).
        @memcpy(cmd_buf[0.."MUTATED-MUT".len], "MUTATED-MUT");
        @memcpy(cwd_buf[0.."/MUTATED-MU".len], "/MUTATED-MU");

        const server = cfg.mcpServerConfig("leak-guard").?;
        try std.testing.expectEqualStrings("initial", server.command.?);
        try std.testing.expectEqualStrings("/initial", server.cwd.?);
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

    /// Fully-resolved effective settings for one LLM call, produced by
    /// walking the canonical profile cascade (see
    /// `resolveEffectiveProfile`). All strings BORROW from the
    /// `LlmConfig` singleton — never free them, never let them outlive
    /// the config. The derived fields (`is_thinking`,
    /// `thinking_adaptive`) are computed ONCE from the final
    /// `thinking_str`, matching the pre-refactor semantics at
    /// workflow.zig:471/477 exactly.
    ///
    /// Plan: docs/superpowers/plans/2026-08-23-refactor-profile-resolution.md
    pub const EffectiveProfile = struct {
        model: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        url_style: []const u8,
        /// Raw resolved `thinking` string ("auto" when nothing set).
        thinking_str: []const u8,
        /// Derived: parseThinkingString(thinking_str) catch null.
        /// "auto"/"" → null, "on"/"true" → true, "off"/"false" → false.
        is_thinking: ?bool,
        /// Derived: std.mem.eql(u8, thinking_str, "auto").
        thinking_adaptive: bool,
        /// Anthropic extended-thinking budget override (null = heuristic/adaptive).
        thinking_budget_tokens: ?u32,
        /// OpenAI reasoning effort ("low"/"medium"/"high"/"auto"; null = omit).
        reasoning_effort: ?[]const u8,
    };

    /// Internal: getProfile that treats an empty name as a miss so the
    /// cascade can pass `active_profile orelse ""` without branching.
    fn getProfileIfSet(self: *const LlmConfig, name: []const u8) ?LlmProfile {
        if (name.len == 0) return null;
        return self.getProfile(name);
    }

    /// THE canonical profile cascade — ONE implementation for the whole
    /// codebase. Walks:
    ///
    ///   1. `selected_profile_model` (non-empty AND profile exists AND
    ///      field non-empty/non-null)
    ///   2. `active_profile`          (same guards)
    ///   3. top-level defaults (`self.model` / `"auto"` / null)
    ///
    /// Per-field fall-through: a profile that EXISTS but has an empty
    /// string or null optional falls through to the next step FOR THAT
    /// FIELD ONLY (partial profiles are allowed). This matches the old
    /// hand-rolled blocks in workflow.zig byte-for-byte.
    ///
    /// Consumers: workflow entry + per-iteration re-read (workflow.zig),
    /// llm_history.resolveSessionProfile (HTTP read paths), and any new
    /// code that needs effective LLM settings. Do NOT hand-roll this
    /// cascade again.
    pub fn resolveEffectiveProfile(
        self: *const LlmConfig,
        selected_profile_model: []const u8,
    ) EffectiveProfile {
        const sel = self.getProfileIfSet(selected_profile_model);
        const act = if (sel == null)
            self.getProfileIfSet(self.active_profile orelse "")
        else
            null;

        // String fields: first non-empty value down the cascade.
        const model: []const u8 = blk: {
            if (sel) |p| if (p.model.len > 0) break :blk p.model;
            if (act) |p| if (p.model.len > 0) break :blk p.model;
            break :blk self.model;
        };
        const base_url: []const u8 = blk: {
            if (sel) |p| if (p.base_url.len > 0) break :blk p.base_url;
            if (act) |p| if (p.base_url.len > 0) break :blk p.base_url;
            break :blk self.base_url;
        };
        const api_key: []const u8 = blk: {
            if (sel) |p| if (p.api_key.len > 0) break :blk p.api_key;
            if (act) |p| if (p.api_key.len > 0) break :blk p.api_key;
            break :blk self.api_key;
        };
        const url_style: []const u8 = blk: {
            if (sel) |p| if (p.url_style.len > 0) break :blk p.url_style;
            if (act) |p| if (p.url_style.len > 0) break :blk p.url_style;
            break :blk self.url_style;
        };
        // thinking: empty on a profile → default "auto" (NOT top-level
        // self.thinking — the top-level LlmConfig has no `thinking`
        // field; workflow.zig's old block defaulted to "auto").
        const thinking_str: []const u8 = blk: {
            if (sel) |p| if (p.thinking.len > 0) break :blk p.thinking;
            if (act) |p| if (p.thinking.len > 0) break :blk p.thinking;
            break :blk "auto";
        };
        const thinking_budget_tokens: ?u32 = blk: {
            if (sel) |p| if (p.thinking_budget_tokens) |t| break :blk t;
            if (act) |p| if (p.thinking_budget_tokens) |t| break :blk t;
            break :blk null;
        };
        const reasoning_effort: ?[]const u8 = blk: {
            if (sel) |p| {
                if (p.reasoning_effort) |re| {
                    if (re.len > 0) break :blk re;
                }
            }
            if (act) |p| {
                if (p.reasoning_effort) |re| {
                    if (re.len > 0) break :blk re;
                }
            }
            break :blk null;
        };

        // Derived ONCE from the final string (pre-refactor:
        // workflow.zig:471 parseThinkingString catch null; :477 eql "auto").
        return .{
            .model = model,
            .base_url = base_url,
            .api_key = api_key,
            .url_style = url_style,
            .thinking_str = thinking_str,
            .is_thinking = parse_thinking.parseThinkingString(thinking_str) catch null,
            .thinking_adaptive = std.mem.eql(u8, thinking_str, "auto"),
            .thinking_budget_tokens = thinking_budget_tokens,
            .reasoning_effort = reasoning_effort,
        };
    }

    /// Whole-profile variant of the cascade: returns the winning
    /// `LlmProfile` (selected → active → null), NOT per-field merged.
    /// Used by consumers that need profile-level overrides like
    /// `max_capacity_tokens` / `compaction_threshold_percent` (compaction
    /// decision, HTTP footer computation). This is the body of the old
    /// `llm_history.resolveSessionProfile`, moved here so Config owns
    /// the entire cascade family.
    pub fn resolveSessionProfileCompat(
        self: *const LlmConfig,
        selected_profile_model: []const u8,
    ) ?LlmProfile {
        if (self.getProfileIfSet(selected_profile_model)) |p| return p;
        if (self.active_profile) |ap| {
            if (ap.len > 0) {
                if (self.getProfile(ap)) |p| return p;
            }
        }
        return null;
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
            .thinking_budget_tokens = null,
            .reasoning_effort = null,
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
        // thinking: route through the pure parse_thinking helper. The
        // helper accepts "auto" / "on" / "off" / "true" / "false" /
        // "" and surfaces `error.InvalidThinkingMode` on garbage.
        // Unparseable values fall through to `null` (= auto / inherit)
        // so a typo in a sub-agent's `thinking` field doesn't break
        // the whole spawn path — same fallback semantics as the
        // previous inline parser at this site.
        const resolved_thinking: ?bool = parse_thinking.parseThinkingString(sa.thinking) catch null;

        // temperature: "auto" → null. Numeric → parseFloat. Anything
        // else → null.
        const resolved_temperature: ?f32 = blk: {
            if (std.mem.eql(u8, sa.temperature, "auto")) break :blk null;
            break :blk std.fmt.parseFloat(f32, sa.temperature) catch null;
        };

        // thinking_budget_tokens: pass through. HTTP layer enforces
        // the (0, 2_000_000] range, so by the time we see this
        // value it's guaranteed non-zero. Empty/null on the sub-agent
        // means "inherit from parent profile" — the workflow's
        // resolver will fall through to the parent profile's value.
        const resolved_budget: ?u32 = sa.thinking_budget_tokens;

        // reasoning_effort: pass through. The HTTP layer validates
        // the 4-value set via `parse_thinking.parseReasoningEffort`,
        // so by the time we see this value it's either null or one
        // of "low" | "medium" | "high" | "auto". Empty string here
        // (which the form sends for "auto") is normalized to null
        // by the HTTP layer before reaching this site.
        const resolved_effort: ?[]const u8 = blk: {
            const e = sa.reasoning_effort orelse break :blk null;
            if (e.len == 0) break :blk null;
            break :blk e;
        };

        return ResolvedSubAgent{
            .name = sa.name,
            .is_random_fallback = false,
            .requested_name = requested_name,
            // Overlay: empty field in SubAgentConfig → orchestrator default.
            //
            // NOTE (plan 2026-08-23-refactor-profile-resolution): this
            // is deliberately NOT `resolveEffectiveProfile`. The overlay
            // base here is the ORCHESTRATOR's top-level values
            // (`self.model` etc.) — a sub-agent with an empty field
            // inherits the top-level Defaults tab, never the user's
            // active profile. Routing this through the cascade would
            // silently change behavior whenever active_profile is set.
            // The full cascade applies to MAIN-agent sessions only;
            // per-profile sub_agents are already scoped by their parent
            // profile via resolveSubAgent's lookup order.
            .model = if (sa.model.len > 0) sa.model else self.model,
            .base_url = if (sa.base_url.len > 0) sa.base_url else self.base_url,
            .api_key = if (sa.api_key.len > 0) sa.api_key else self.api_key,
            .url_style = if (sa.url_style.len > 0) sa.url_style else self.url_style,
            .is_thinking = resolved_thinking,
            .temperature = resolved_temperature,
            .thinking_budget_tokens = resolved_budget,
            .reasoning_effort = resolved_effort,
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
    /// config file exists at the platform-default path).
    ///
    /// Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
    /// defaults (`api_key` / `model` / `base_url` / `url_style`) are NO
    /// LONGER written. The user configures LLM access exclusively through
    /// `profiles_models`; `LlmConfig.init` backfills the in-memory
    /// top-level fields from the active profile at load time. Optional
    /// operational fields are populated with their documented defaults so
    /// a subsequent `LlmConfig.init` re-parse yields a well-formed
    /// `LlmConfig`.
    pub const defaultConfigJson: []const u8 =
        \\{
        \\  "profiles_models": {},
        \\  "active_profile": null,
        \\  "model_compaction_size_kb": 100,
        \\  "notify_on_complete": false,
        \\  "retry_delay_ms": 0,
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

// ---------------------------------------------------------------------------
// resolveEffectiveProfile — THE canonical profile cascade (plan
// 2026-08-23-refactor-profile-resolution). One implementation; every
// consumer (workflow entry, per-iteration re-read, llm_history HTTP
// paths) must go through here.
//
// Cascade: selected_profile_model → active_profile → top-level defaults.
// Per-field fall-through: a profile that EXISTS but has an empty/null
// field falls through for THAT field only (partial profiles allowed).
// ---------------------------------------------------------------------------

/// Shared fixture: top-level defaults + two profiles ("alpha" fully
/// populated, "partial" with only model set). Built directly (no disk
/// round-trip). All strings are duped on the testing allocator because
/// `deinit`/`freeProfilesMap` free every field — assigning literals
/// here would panic "Invalid free".
fn cascadeFixture(allocator: std.mem.Allocator) !LlmConfig {
    var cfg: LlmConfig = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "top-key"),
        .model = try allocator.dupe(u8, "top-model"),
        .base_url = try allocator.dupe(u8, "https://top"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    try cfg.profiles_models.put(try allocator.dupe(u8, "alpha"), .{
        .model = try allocator.dupe(u8, "alpha-model"),
        .base_url = try allocator.dupe(u8, "https://alpha"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "alpha-key"),
        .url_style = try allocator.dupe(u8, "anthropic"),
        .sub_agents = &.{},
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = 4096,
        .reasoning_effort = try allocator.dupe(u8, "high"),
    });
    try cfg.profiles_models.put(try allocator.dupe(u8, "partial"), .{
        .model = try allocator.dupe(u8, "partial-model"),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .sub_agents = &.{},
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

test "resolveEffectiveProfile: selected profile wins over top-level for every field" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("alpha");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("https://alpha", e.base_url);
    try std.testing.expectEqualStrings("alpha-key", e.api_key);
    try std.testing.expectEqualStrings("anthropic", e.url_style);
    try std.testing.expectEqualStrings("on", e.thinking_str);
    // Derived from thinking_str="on":
    try std.testing.expect(e.is_thinking == true);
    try std.testing.expectEqual(false, e.thinking_adaptive);
    try std.testing.expectEqual(@as(?u32, 4096), e.thinking_budget_tokens);
    try std.testing.expectEqualStrings("high", e.reasoning_effort.?);
}

test "resolveEffectiveProfile: no selection + no active → pure top-level defaults" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("");
    try std.testing.expectEqualStrings("top-model", e.model);
    try std.testing.expectEqualStrings("https://top", e.base_url);
    try std.testing.expectEqualStrings("top-key", e.api_key);
    try std.testing.expectEqualStrings("openai", e.url_style);
    try std.testing.expectEqualStrings("auto", e.thinking_str);
    // Derived from thinking_str="auto":
    try std.testing.expect(e.is_thinking == null);
    try std.testing.expectEqual(true, e.thinking_adaptive);
    try std.testing.expectEqual(@as(?u32, null), e.thinking_budget_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), e.reasoning_effort);
}

test "resolveEffectiveProfile: missing selected name falls through to top-level" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("does_not_exist");
    try std.testing.expectEqualStrings("top-model", e.model);
}

test "resolveEffectiveProfile: partial profile falls through for THAT field only" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    const e = cfg.resolveEffectiveProfile("partial");
    // Set on the profile:
    try std.testing.expectEqualStrings("partial-model", e.model);
    // Empty on the profile → top-level fallback:
    try std.testing.expectEqualStrings("https://top", e.base_url);
    try std.testing.expectEqualStrings("top-key", e.api_key);
    try std.testing.expectEqualStrings("openai", e.url_style);
    // Empty thinking on the profile → default "auto".
    try std.testing.expectEqualStrings("auto", e.thinking_str);
}

test "resolveEffectiveProfile: active_profile wins when selection empty" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");

    const e = cfg.resolveEffectiveProfile("");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("anthropic", e.url_style);
    try std.testing.expectEqual(@as(?u32, 4096), e.thinking_budget_tokens);
}

test "resolveEffectiveProfile: selected wins over active_profile" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "partial");

    const e = cfg.resolveEffectiveProfile("alpha");
    try std.testing.expectEqualStrings("alpha-model", e.model);
    try std.testing.expectEqualStrings("alpha-key", e.api_key);
}

test "resolveEffectiveProfile: missing selected falls to active_profile" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");

    const e = cfg.resolveEffectiveProfile("does_not_exist");
    try std.testing.expectEqualStrings("alpha-model", e.model);
}

test "resolveEffectiveProfile: derived fields for off / garbage thinking strings" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();
    cfg.active_profile = try std.testing.allocator.dupe(u8, "partial");
    // Mutate the stored profile's thinking directly. The map owns its
    // strings (freeProfilesMap frees `thinking`), so free the old
    // slice and install a fresh owned copy — assigning a literal
    // would make deinit() free a non-heap pointer.
    const pptr = cfg.profiles_models.getPtr("partial").?;
    cfg.allocator.free(pptr.thinking);
    pptr.thinking = try cfg.allocator.dupe(u8, "off");

    const e_off = cfg.resolveEffectiveProfile("");
    try std.testing.expect(e_off.is_thinking == false);
    try std.testing.expectEqual(false, e_off.thinking_adaptive);

    cfg.allocator.free(pptr.thinking);
    pptr.thinking = try cfg.allocator.dupe(u8, "total-garbage");
    const e_bad = cfg.resolveEffectiveProfile("");
    // Garbage ≠ "auto" → adaptive=false; parse fails → is_thinking=null.
    try std.testing.expect(e_bad.is_thinking == null);
    try std.testing.expectEqual(false, e_bad.thinking_adaptive);
}

test "resolveSessionProfileCompat: mirrors old resolveSessionProfile semantics" {
    const allocator = std.testing.allocator;
    var cfg = try cascadeFixture(allocator);
    defer cfg.deinit();

    // Selected hit.
    try std.testing.expect(cfg.resolveSessionProfileCompat("alpha") != null);
    try std.testing.expectEqualStrings("alpha-model", cfg.resolveSessionProfileCompat("alpha").?.model);
    // Miss → null (no active set in fixture).
    try std.testing.expect(cfg.resolveSessionProfileCompat("") == null);
    try std.testing.expect(cfg.resolveSessionProfileCompat("nope") == null);

    // Active hit.
    cfg.active_profile = try std.testing.allocator.dupe(u8, "alpha");
    const p = cfg.resolveSessionProfileCompat("").?;
    try std.testing.expectEqualStrings("alpha-model", p.model);
}

test {
    _ = @import("config_test.zig");
    _ = @import("parse_thinking_test.zig");
}
