const std = @import("std");
const config = @import("Config.zig");
const LlmConfig = config.LlmConfig;

test "config module imports" {
    // Sanity check: the module is importable.
    try std.testing.expect(@hasDecl(LlmConfig, "McpServerConfig"));
    try std.testing.expect(@hasDecl(LlmConfig, "McpServersMap"));
    try std.testing.expect(@hasDecl(LlmConfig, "McpHeadersMap"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerConfig"));
    try std.testing.expect(@hasDecl(LlmConfig, "hasMcpServer"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerUrl"));
    try std.testing.expect(@hasDecl(LlmConfig, "mcpServerCount"));
    try std.testing.expect(@hasDecl(LlmConfig, "hasMcpServers"));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Write `json` to a temp `config.json` and load it with `LlmConfig.init`.
/// Caller owns the returned `LlmConfig` and must call `deinit` on it.
fn writeAndRead(allocator: std.mem.Allocator, io: std.Io, json: []const u8) !LlmConfig {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data = json,
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(config_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");

    return LlmConfig.init(allocator, io, config_path, &env_map);
}

// ---------------------------------------------------------------------------
// Parsing: snake_case `mcp_servers` field (the canonical form)
// ---------------------------------------------------------------------------

test "mcp_servers: parses snake_case field with one server" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "base_url": "https://example.com",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": {
        \\        "CONTEXT7_API_KEY": "YOUR_API_KEY"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasMcpServers());
    try std.testing.expectEqual(@as(u32, 1), cfg.mcpServerCount());
    try std.testing.expect(cfg.hasMcpServer("context7"));
    try std.testing.expect(!cfg.hasMcpServer("nope"));

    const ctx = cfg.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx.url);
    try std.testing.expect(ctx.isValid());
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(ctx.headers.count())));
    try std.testing.expectEqualStrings("YOUR_API_KEY", ctx.headers.get("CONTEXT7_API_KEY").?);
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", cfg.mcpServerUrl("context7").?);
}

test "mcp_servers: parses multiple servers" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": { "CONTEXT7_API_KEY": "ctx-key" }
        \\    },
        \\    "github": {
        \\      "url": "https://mcp.github.com/mcp",
        \\      "headers": { "GITHUB_TOKEN": "gh-token" }
        \\    },
        \\    "plain": {
        \\      "url": "https://mcp.plain.com/mcp"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 3), cfg.mcpServerCount());
    try std.testing.expect(cfg.hasMcpServer("context7"));
    try std.testing.expect(cfg.hasMcpServer("github"));
    try std.testing.expect(cfg.hasMcpServer("plain"));

    const ctx = cfg.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("ctx-key", ctx.headers.get("CONTEXT7_API_KEY").?);

    const gh = cfg.mcpServerConfig("github").?;
    try std.testing.expectEqualStrings("gh-token", gh.headers.get("GITHUB_TOKEN").?);

    const plain = cfg.mcpServerConfig("plain").?;
    try std.testing.expectEqualStrings("https://mcp.plain.com/mcp", plain.url);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(plain.headers.count())));
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

test "mcp_servers: empty config yields empty map" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServers());
    try std.testing.expectEqual(@as(u32, 0), cfg.mcpServerCount());
    try std.testing.expect(!cfg.hasMcpServer("anything"));
    try std.testing.expect(cfg.mcpServerConfig("anything") == null);
    try std.testing.expect(cfg.mcpServerUrl("anything") == null);
}

test "mcp_servers: skips server entries missing url" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "bad": { "headers": { "X": "y" } },
        \\    "good": { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("bad"));
    try std.testing.expect(cfg.hasMcpServer("good"));
    try std.testing.expectEqual(@as(u32, 1), cfg.mcpServerCount());
}

test "mcp_servers: skips server entries with non-string url" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "numeric": { "url": 42 },
        \\    "good":   { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("numeric"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: empty url is skipped" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "empty":   { "url": "" },
        \\    "good":    { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("empty"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: non-object server entry is skipped" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "string": "not-an-object",
        \\    "array":  [1, 2, 3],
        \\    "good":   { "url": "https://good.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(!cfg.hasMcpServer("string"));
    try std.testing.expect(!cfg.hasMcpServer("array"));
    try std.testing.expect(cfg.hasMcpServer("good"));
}

test "mcp_servers: skips non-string header values" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "mix": {
        \\      "url": "https://mix.example.com",
        \\      "headers": {
        \\        "OK": "good",
        \\        "BAD": 42,
        \\        "ALSO_OK": "fine"
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const mix = cfg.mcpServerConfig("mix").?;
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(mix.headers.count())));
    try std.testing.expectEqualStrings("good", mix.headers.get("OK").?);
    try std.testing.expectEqualStrings("fine", mix.headers.get("ALSO_OK").?);
    try std.testing.expect(mix.headers.get("BAD") == null);
}

test "mcp_servers: non-object headers field is treated as empty" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "weird": {
        \\      "url": "https://weird.example.com",
        \\      "headers": "not-an-object"
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const weird = cfg.mcpServerConfig("weird").?;
    try std.testing.expectEqualStrings("https://weird.example.com", weird.url);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(weird.headers.count())));
}

test "mcp_servers: missing headers field is treated as empty" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "noheaders": { "url": "https://nh.example.com" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const nh = cfg.mcpServerConfig("noheaders").?;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(nh.headers.count())));
}

// ---------------------------------------------------------------------------
// Backward compat: the existing `mcpServers()` json.Value accessor still works
// ---------------------------------------------------------------------------

test "mcp_servers: legacy mcpServers() json.Value accessor still returns data" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": { "url": "https://mcp.context7.com/mcp" }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const raw = cfg.mcpServers().?;
    const obj = raw.object;
    try std.testing.expect(obj.get("context7") != null);
    const ctx_value = obj.get("context7").?;
    const ctx_obj = ctx_value.object;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx_obj.get("url").?.string);
}

// ---------------------------------------------------------------------------
// Lifecycle: clone produces a deep, independent copy
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// notify_on_complete: opt-in OS notification flag
// ---------------------------------------------------------------------------

test "notify_on_complete: defaults to false when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_complete);
}

test "notify_on_complete: reads true from JSON when present" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": true
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.notify_on_complete);
}

test "notify_on_complete: reads false from JSON when explicitly false" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "notify_on_complete": false
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.notify_on_complete);
}

// ---------------------------------------------------------------------------
// url_style: top-level OpenAI vs Anthropic selector (regression for
// `NalarSettings.vue` URL Style dropdown — see plan
// `2026-06-11-nalar-config-url-style.md`).
// ---------------------------------------------------------------------------

test "LlmConfig: url_style field round-trips through disk JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "url_style": "anthropic"
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("anthropic", cfg.url_style);
}

test "LlmConfig: url_style defaults to openai when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("openai", cfg.url_style);
}

// ---------------------------------------------------------------------------
// retry_delay_ms: workflow retry backoff in milliseconds. 0 = no delay
// (current behavior). Plan 2026-07-15-retry-delay. Defaults to 0 when
// missing so existing config files load without surprises.
// ---------------------------------------------------------------------------

test "LlmConfig: retry_delay_ms defaults to 0 when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 0), cfg.retry_delay_ms);
}

test "LlmConfig: retry_delay_ms reads from JSON when present" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "retry_delay_ms": 5000
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 5000), cfg.retry_delay_ms);
}

// ---------------------------------------------------------------------------
// model_compaction_size_kb: session-compactor threshold (consumed by
// `session_compact.zig:57`). No UI — power users edit config.json.
// ---------------------------------------------------------------------------

test "LlmConfig: model_compaction_size_kb reads value from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "model_compaction_size_kb": 250
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 250), cfg.model_compaction_size_kb);
}

test "LlmConfig: model_compaction_size_kb defaults to 100 when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 100), cfg.model_compaction_size_kb);
}

test "mcp_servers: clone produces independent deep copy" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "mcp_servers": {
        \\    "context7": {
        \\      "url": "https://mcp.context7.com/mcp",
        \\      "headers": { "CONTEXT7_API_KEY": "YOUR_API_KEY" }
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    // Both should have the same data.
    try std.testing.expect(cloned.hasMcpServer("context7"));
    const ctx = cloned.mcpServerConfig("context7").?;
    try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", ctx.url);
    try std.testing.expectEqualStrings("YOUR_API_KEY", ctx.headers.get("CONTEXT7_API_KEY").?);

    // The strings should be at different addresses — independent allocations.
    const orig_url = cfg.mcpServerUrl("context7").?;
    try std.testing.expect(orig_url.ptr != ctx.url.ptr);

    const orig_key = cfg.mcpServerConfig("context7").?.headers.get("CONTEXT7_API_KEY").?;
    try std.testing.expect(orig_key.ptr != ctx.headers.get("CONTEXT7_API_KEY").?.ptr);
}

// ---------------------------------------------------------------------------
// sub_agents: top-level typed array
// ---------------------------------------------------------------------------

test "sub_agents: top-level field is parsed into SubAgentsList" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "sub_agents": [
        \\    {
        \\      "name": "SubAgent1",
        \\      "model": "MiniMax-M3",
        \\      "base_url": "https://api.minimax.io/v1",
        \\      "thinking": "false",
        \\      "temperature": "auto",
        \\      "url_style": "openai",
        \\      "api_key": "",
        \\      "system_prompt": ""
        \\    }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.sub_agents.len);
    const sa = cfg.sub_agents[0];
    try std.testing.expectEqualStrings("SubAgent1", sa.name);
    try std.testing.expectEqualStrings("MiniMax-M3", sa.model);
    try std.testing.expectEqualStrings("https://api.minimax.io/v1", sa.base_url);
    try std.testing.expectEqualStrings("false", sa.thinking);
    try std.testing.expectEqualStrings("auto", sa.temperature);
    try std.testing.expectEqualStrings("openai", sa.url_style);
    try std.testing.expectEqualStrings("", sa.api_key);
    try std.testing.expectEqualStrings("", sa.system_prompt);
}

test "sub_agents: hasSubAgent / getSubAgent accessors" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "you are alpha" },
        \\    { "name": "beta",  "model": "M2", "base_url": "https://b",
        \\      "thinking": "off", "temperature": "auto", "url_style": "anthropic",
        \\      "api_key": "ak2", "system_prompt": "" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasSubAgent("alpha"));
    try std.testing.expect(cfg.hasSubAgent("beta"));
    try std.testing.expect(!cfg.hasSubAgent("nope"));

    const a = cfg.getSubAgent("alpha").?;
    try std.testing.expectEqualStrings("M1", a.model);
    try std.testing.expectEqualStrings("https://a", a.base_url);
    try std.testing.expectEqualStrings("on", a.thinking);
    try std.testing.expectEqualStrings("0.5", a.temperature);
    try std.testing.expectEqualStrings("you are alpha", a.system_prompt);

    try std.testing.expect(cfg.getSubAgent("nope") == null);
}

test "sub_agents: clone produces independent deep copy" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "sp" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), cloned.sub_agents.len);
    const orig = cfg.sub_agents[0];
    const copy = cloned.sub_agents[0];
    try std.testing.expect(orig.name.ptr != copy.name.ptr);
    try std.testing.expect(orig.model.ptr != copy.model.ptr);
    try std.testing.expectEqualStrings("alpha", copy.name);
    try std.testing.expectEqualStrings("sp", copy.system_prompt);
}

test "sub_agents: per-profile sub_agents are parsed" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "p1sa", "model": "M1", "base_url": "https://a",
        \\          "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\          "api_key": "ak1", "system_prompt": "sp1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const p1 = cfg.getProfile("profile1").?;
    try std.testing.expectEqual(@as(usize, 1), p1.sub_agents.len);
    try std.testing.expectEqualStrings("p1sa", p1.sub_agents[0].name);
    try std.testing.expectEqualStrings("M1", p1.sub_agents[0].model);
    try std.testing.expectEqualStrings("sp1", p1.sub_agents[0].system_prompt);
}

// ---------------------------------------------------------------------------
// resolveSubAgent — config-driven sub-agent selection
// ---------------------------------------------------------------------------
//
// Tests the LlmConfig.resolveSubAgent function that the
// spawn_sub_agent tool uses to look up a named sub-agent from
// config. The function returns a ResolvedSubAgent overlay that's
// applied on top of the orchestrator's default model/api_key/etc.
//
// v1: profile_name is always passed as "" from tool_registry.zig
// because ToolExecContext doesn't yet carry the parent's
// selected_profile_model. The tests exercise the top-level
// sub_agents lookup only. The "per-profile sub_agents first" rule
// from the plan is wired but not yet exercised by the spawn path.

const resolve_alloc = std.testing.allocator;
const resolve_io = std.testing.io;

/// Pair of (cfg, resolved) so the test can keep cfg alive while
/// inspecting the resolved struct. The slices in
/// `ResolvedSubAgent` borrow from `cfg` (the LlmConfig's owned
/// strings), so cfg MUST outlive any use of the resolved
/// struct — hence the pair, not just the resolved struct.
const ResolvedPair = struct {
    cfg: LlmConfig,
    resolved: LlmConfig.ResolvedSubAgent,
};

/// Helper: build a config JSON with the given top-level sub_agents
/// array (and no profiles) and resolve `agent_name` against it.
/// Caller owns the returned `cfg` and must call `deinit` on it
/// AFTER they're done with `resolved`.
fn resolveFromTopLevel(json: []const u8, agent_name: []const u8) !ResolvedPair {
    var cfg = try writeAndRead(resolve_alloc, resolve_io, json);
    const resolved = cfg.resolveSubAgent("", agent_name);
    return ResolvedPair{ .cfg = cfg, .resolved = resolved };
}

/// Helper: same as `resolveFromTopLevel` but passes `profile_name`
/// so the per-profile sub_agents lookup is exercised.
fn resolveFromProfile(
    json: []const u8,
    profile_name: []const u8,
    agent_name: []const u8,
) !ResolvedPair {
    var cfg = try writeAndRead(resolve_alloc, resolve_io, json);
    const resolved = cfg.resolveSubAgent(profile_name, agent_name);
    return ResolvedPair{ .cfg = cfg, .resolved = resolved };
}

test "resolveSubAgent: top-level hit returns the matched sub-agent's fields" {
    const json =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "gpt-4o",
        \\      "base_url": "https://api.openai.com/v1",
        \\      "thinking": "true", "temperature": "0.3",
        \\      "url_style": "openai", "api_key": "reviewer-key",
        \\      "system_prompt": "You are a strict code reviewer." }
        \\  ]
        \\}
    ;
    var pair = try resolveFromTopLevel(json, "reviewer");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expectEqualStrings("reviewer", r.name);
    try std.testing.expect(!r.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", r.requested_name);
    try std.testing.expectEqualStrings("gpt-4o", r.model);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", r.base_url);
    try std.testing.expectEqualStrings("reviewer-key", r.api_key);
    try std.testing.expectEqualStrings("openai", r.url_style);
    try std.testing.expectEqualStrings("You are a strict code reviewer.", r.system_prompt);
    try std.testing.expectEqual(@as(?bool, true), r.is_thinking);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), r.temperature.?, 0.0001);
    // Top-level lookup: source is "" (no profile).
    try std.testing.expectEqualStrings("", r.source);
}

test "resolveSubAgent: miss returns random fallback with orchestrator defaults" {
    const json =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "url_style": "anthropic"
        \\}
    ;
    var pair = try resolveFromTopLevel(json, "unknown");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expect(r.is_random_fallback);
    try std.testing.expectEqualStrings("unknown", r.requested_name);
    // Random name format: "agent-" + 16 hex chars.
    try std.testing.expect(r.name.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, r.name, "agent-"));
    try std.testing.expectEqual(@as(usize, "agent-".len + 16), r.name.len);
    // All hex chars in the suffix.
    for (r.name["agent-".len..]) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Orchestrator defaults preserved.
    try std.testing.expectEqualStrings("default-model", r.model);
    try std.testing.expectEqualStrings("https://default.example.com", r.base_url);
    try std.testing.expectEqualStrings("default-key", r.api_key);
    try std.testing.expectEqualStrings("anthropic", r.url_style);
    // No specialized system_prompt.
    try std.testing.expectEqualStrings("", r.system_prompt);
    try std.testing.expectEqual(@as(?bool, null), r.is_thinking);
    try std.testing.expectEqual(@as(?f32, null), r.temperature);
    try std.testing.expectEqualStrings("", r.source);
}

test "resolveSubAgent: overlay — empty SubAgentConfig field falls through to orchestrator" {
    // Sub-agent has `model` but no `api_key` / `base_url`. Resolve
    // and verify the orchestrator's values are used for the empty
    // fields (NOT the empty string from the SubAgentConfig).
    const json =
        \\{
        \\  "api_key": "default-key", "model": "default-model",
        \\  "base_url": "https://default.example.com",
        \\  "url_style": "openai",
        \\  "sub_agents": [
        \\    { "name": "minimal", "model": "gpt-4o",
        \\      "base_url": "", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "", "api_key": "", "system_prompt": "" }
        \\  ]
        \\}
    ;
    var pair = try resolveFromTopLevel(json, "minimal");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expect(!r.is_random_fallback);
    try std.testing.expectEqualStrings("gpt-4o", r.model); // from SubAgentConfig
    try std.testing.expectEqualStrings("https://default.example.com", r.base_url); // orchestrator
    try std.testing.expectEqualStrings("default-key", r.api_key); // orchestrator
    try std.testing.expectEqualStrings("openai", r.url_style); // orchestrator
    try std.testing.expectEqual(@as(?bool, null), r.is_thinking); // "auto" -> inherit
    try std.testing.expectEqual(@as(?f32, null), r.temperature); // "auto" -> inherit
}

test "resolveSubAgent: thinking \"true\" -> Some(true), \"false\" -> Some(false)" {
    const json_true =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "sa", "model": "m",
        \\    "base_url": "u", "thinking": "true", "temperature": "auto",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair_true = try resolveFromTopLevel(json_true, "sa");
    defer pair_true.cfg.deinit();
    try std.testing.expectEqual(@as(?bool, true), pair_true.resolved.is_thinking);

    const json_false =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "sa", "model": "m",
        \\    "base_url": "u", "thinking": "false", "temperature": "auto",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair_false = try resolveFromTopLevel(json_false, "sa");
    defer pair_false.cfg.deinit();
    try std.testing.expectEqual(@as(?bool, false), pair_false.resolved.is_thinking);
}

test "resolveSubAgent: temperature \"0.7\" parses to Some(0.7)" {
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "sa", "model": "m",
        \\    "base_url": "u", "thinking": "auto", "temperature": "0.7",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair = try resolveFromTopLevel(json, "sa");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expect(r.temperature != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), r.temperature.?, 0.0001);
}

test "resolveSubAgent: temperature garbage -> null (treat as auto)" {
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "sa", "model": "m",
        \\    "base_url": "u", "thinking": "auto", "temperature": "garbage",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair = try resolveFromTopLevel(json, "sa");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expectEqual(@as(?f32, null), r.temperature);
}

test "resolveSubAgent: top-level sub_agents list is empty -> miss fallback" {
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [] }
    ;
    var pair = try resolveFromTopLevel(json, "anything");
        defer pair.cfg.deinit();
        const r = pair.resolved;
    try std.testing.expect(r.is_random_fallback);
    try std.testing.expectEqualStrings("anything", r.requested_name);
    try std.testing.expectEqualStrings("m", r.model);
}

test "resolveSubAgent: two sub_agents, the second one matches" {
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "first", "model": "M1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "sp1" },
        \\    { "name": "second", "model": "M2", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k", "system_prompt": "sp2" }
        \\  ]
        \\}
    ;
    var pair1 = try resolveFromTopLevel(json, "first");
    defer pair1.cfg.deinit();
    try std.testing.expect(!pair1.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("M1", pair1.resolved.model);
    try std.testing.expectEqualStrings("sp1", pair1.resolved.system_prompt);
    var pair2 = try resolveFromTopLevel(json, "second");
    defer pair2.cfg.deinit();
    try std.testing.expect(!pair2.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("M2", pair2.resolved.model);
    try std.testing.expectEqualStrings("sp2", pair2.resolved.system_prompt);
}

test "resolveSubAgent: name match is exact (case-sensitive)" {
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "u",
        \\  "sub_agents": [{ "name": "Reviewer", "model": "M1",
        \\    "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\    "url_style": "openai", "api_key": "k", "system_prompt": "p" }] }
    ;
    var pair_match = try resolveFromTopLevel(json, "Reviewer");
    defer pair_match.cfg.deinit();
    try std.testing.expect(!pair_match.resolved.is_random_fallback);
    var pair_miss = try resolveFromTopLevel(json, "reviewer");
    defer pair_miss.cfg.deinit();
    try std.testing.expect(pair_miss.resolved.is_random_fallback);
}

// ---------------------------------------------------------------------------
// resolveSubAgent — per-profile sub_agents lookup (decision #1)
// ---------------------------------------------------------------------------
//
// Exercises the full lookup chain: when a profile is selected, its
// sub_agents list is consulted first; the top-level list is the
// fallback. `resolveFromProfile` passes a non-empty profile_name
// into `resolveSubAgent`, mirroring how `tool_registry.execSpawnSubAgent`
// passes `ctx.selected_profile_model`.

test "resolveSubAgent: per-profile sub_agent is preferred over top-level" {
    // profile1 has its own "reviewer" with a specialized model;
    // the top-level "reviewer" uses a different model. The
    // per-profile hit must win.
    const json =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level reviewer" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1_MODEL", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "PROFILE1_MODEL",
        \\          "base_url": "u", "thinking": "true", "temperature": "0.5",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "profile1 reviewer" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json, "profile1", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.name);
    // Per-profile hit: PROFILE1_MODEL wins, not TOP_MODEL.
    try std.testing.expectEqualStrings("PROFILE1_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("profile1 reviewer", pair.resolved.system_prompt);
    try std.testing.expectEqualStrings("profile1", pair.resolved.source);
}

test "resolveSubAgent: when profile doesn't have the sub_agent, fall back to top-level" {
    // profile1 has no sub_agents at all; the top-level "reviewer"
    // is the source.
    const json =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": { "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k" }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json, "profile1", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    // Top-level hit: TOP_MODEL wins, source is "".
    try std.testing.expectEqualStrings("TOP_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("", pair.resolved.source);
}

test "resolveSubAgent: profile has the sub_agent but with empty profile_name -> top-level" {
    // Same JSON as the per-profile test, but the call passes
    // `""` for `profile_name` (e.g. the parent session has no
    // profile selected). The top-level list must be consulted.
    const json =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "reviewer", "model": "P1_MODEL",
        \\          "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "profile1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    // Note: resolveFromTopLevel passes "" as profile_name, so the
    // per-profile list is SKIPPED entirely — only the top-level
    // list is consulted.
    var pair = try resolveFromTopLevel(json, "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("TOP_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("top-level", pair.resolved.system_prompt);
    try std.testing.expectEqualStrings("", pair.resolved.source);
}

test "resolveSubAgent: profile_name not in profiles_models -> fallback to top-level" {
    // The user requested a profile that doesn't exist; the
    // function silently falls through to the top-level list.
    const json =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "reviewer", "model": "TOP_MODEL",
        \\      "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "top-level" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": { "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k" }
        \\  }
        \\}
    ;
    // profile_name "profile_unknown" is not in profiles_models;
    // we should still resolve via the top-level list.
    var pair = try resolveFromProfile(json, "profile_unknown", "reviewer");
    defer pair.cfg.deinit();
    try std.testing.expect(!pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("TOP_MODEL", pair.resolved.model);
    try std.testing.expectEqualStrings("", pair.resolved.source);
}

test "resolveSubAgent: per-profile miss AND top-level miss -> random fallback" {
    const json =
        \\{ "api_key": "k", "model": "default", "base_url": "u",
        \\  "sub_agents": [
        \\    { "name": "other", "model": "M", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "system_prompt": "p" }
        \\  ],
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "P1", "base_url": "u",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "k",
        \\      "sub_agents": [
        \\        { "name": "diff_name", "model": "M",
        \\          "base_url": "u", "thinking": "auto", "temperature": "auto",
        \\          "url_style": "openai", "api_key": "k",
        \\          "system_prompt": "p" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    var pair = try resolveFromProfile(json, "profile1", "reviewer");
    defer pair.cfg.deinit();
    // Neither profile1.sub_agents (has "diff_name") nor top-level
    // (has "other") contains "reviewer" -> random fallback.
    try std.testing.expect(pair.resolved.is_random_fallback);
    try std.testing.expectEqualStrings("reviewer", pair.resolved.requested_name);
    try std.testing.expectEqualStrings("default", pair.resolved.model);
    try std.testing.expectEqualStrings("", pair.resolved.source);
}

// ---------------------------------------------------------------------------
// Auto-init: writeDefaultConfig() bootstrap helper (Chunk 1)
// ---------------------------------------------------------------------------

test "writeDefaultConfig creates a valid JSON config file at the given path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    // Build an absolute path inside the tmp dir; the file does not exist yet.
    const full_path = try std.fs.path.join(allocator, &.{ base_path, "config.json" });
    defer allocator.free(full_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, full_path);

    // Read it back and verify the JSON shape.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, full_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("api_key") != null);
    try std.testing.expect(obj.get("model") != null);
    try std.testing.expect(obj.get("base_url") != null);
    try std.testing.expectEqualStrings("openai", obj.get("url_style").?.string);
    try std.testing.expectEqual(@as(i64, 100), obj.get("model_compaction_size_kb").?.integer);
    try std.testing.expectEqual(@as(bool, false), obj.get("notify_on_complete").?.bool);
    // Plan 2026-07-07-compaction-inline: the top-level
    // `max_capacity_token_model` and `compaction_threshold_percent`
    // fields are RESTORED. The default JSON writes them as null so
    // the loader sees the cascade wildcard (fall through to per-profile
    // override, then built-in).
    try std.testing.expect(obj.get("max_capacity_token_model").? == .null);
    try std.testing.expect(obj.get("compaction_threshold_percent").? == .null);
}

test "writeDefaultConfig creates parent directories that do not exist" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    // Path includes a 2-level deep parent that does NOT exist yet.
    const nested_path = try std.fs.path.join(allocator, &.{ base_path, "deep", "nested", "config.json" });
    defer allocator.free(nested_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, nested_path);

    // Verify the file was written and is readable.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, nested_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"api_key\": \"\"") != null);
}

// ---------------------------------------------------------------------------
// Auto-init: LlmConfig.init() creates default config on first run (Chunk 2)
// ---------------------------------------------------------------------------

test "init auto-creates config.json when default path does not exist (path=null)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir — this becomes
    // our fake $HOME / $XDG_CONFIG_HOME / %APPDATA% depending on
    // platform. `getDefaultConfigDir` reads different env vars per
    // platform: Linux uses XDG_CONFIG_HOME/HOME, macOS uses HOME
    // (under `Library/Application Support/`), Windows uses APPDATA.
    // Setting all three keeps the test platform-portable.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base_path);
    try env_map.put("XDG_CONFIG_HOME", base_path);
    try env_map.put("APPDATA", base_path);

    // Call init() with path = null. The default config path resolves
    // via getDefaultConfigPath to a platform-appropriate location
    // (e.g. `<base>/.config/nalar/config.json` on Linux, `<base>/Library/Application Support/nalar/config.json`
    // on macOS, `<base>/nalar/config.json` on Windows). The file does
    // not exist yet — auto-init must create it.
    var cfg = try LlmConfig.init(allocator, std.testing.io, null, &env_map);
    defer cfg.deinit();

    // Post-condition: the file now exists on disk and contains the default template.
    // Use getDefaultConfigPath to get the actual platform-appropriate
    // path (instead of hardcoding one platform's layout, which broke
    // macOS CI — see PR #68 review).
    const expected_path = try config.getDefaultConfigPath(allocator, &env_map);
    defer allocator.free(expected_path);

    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"api_key\": \"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"url_style\": \"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"model_compaction_size_kb\": 100") != null);
    // Plan 2026-07-15-retry-delay: top-level `retry_delay_ms` is
    // auto-created as 0 (the documented default = no delay).
    try std.testing.expect(std.mem.indexOf(u8, content, "\"retry_delay_ms\": 0") != null);
    // Plan 2026-07-07-compaction-inline: top-level
    // `max_capacity_token_model` and `compaction_threshold_percent`
    // are RESTORED as null defaults in the auto-created file. The
    // loader sees them as the cascade wildcard.
    try std.testing.expect(std.mem.indexOf(u8, content, "max_capacity_token_model") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "compaction_threshold_percent") != null);
}

test "init does NOT auto-create when explicit path is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the canonical absolute path of the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = path_buf[0..base_len];
    const missing_path = try std.fs.path.join(allocator, &.{ base_path, "nope.json" });
    defer allocator.free(missing_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base_path);
    try env_map.put("XDG_CONFIG_HOME", base_path);
    try env_map.put("APPDATA", base_path);

    // Explicit path arg (non-null) — must surface ConfigFileNotFound,
    // NOT silently auto-create.
    //
    // Note: `LlmConfig.init` logs via std.log.err on this path for
    // production observability. The Zig 0.16 test harness treats
    // `log_err_count > 0` as a test failure even when the assertion
    // itself passes — see the chunk-2 deviation notes in
    // `docs/superpowers/plans/2026-07-02-auto-init-config.md` (the
    // assertions pass; the build wrapper exits 1). Verify each
    // `expectError` test by name via the test binary directly
    // (see run logs in the chunk report).
    const result = LlmConfig.init(allocator, std.testing.io, missing_path, &env_map);
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

test "init does NOT auto-create when file exists with parse error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write invalid JSON to the existing file FIRST (realPathFileAlloc
    // requires the file to exist; mirrors the order used by the
    // existing writeAndRead helper above).
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "not json{",
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(config_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");

    // File exists → auto-init must NOT run; the parse error surfaces.
    //
    // Note: `LlmConfig.init` logs via std.log.err on this path for
    // production observability. The Zig 0.16 test harness treats
    // `log_err_count > 0` as a test failure even when the assertion
    // itself passes — see the chunk-2 deviation notes in
    // `docs/superpowers/plans/2026-07-02-auto-init-config.md` (the
    // assertions pass; the build wrapper exits 1). Verify each
    // `expectError` test by name via the test binary directly
    // (see run logs in the chunk report).
    const result = LlmConfig.init(allocator, std.testing.io, config_path, &env_map);
    try std.testing.expectError(error.InvalidJson, result);

    // The original file content must be unchanged (no auto-create ran).
    var read_buf: [4096]u8 = undefined;
    const content_slice = try tmp.dir.readFile(std.testing.io, "config.json", &read_buf);
    try std.testing.expectEqualStrings("not json{", content_slice);
}

// ---------------------------------------------------------------------------
// Compaction overrides: max_capacity_token_model + compaction_threshold_percent
// (configurable compaction settings — see
//  docs/superpowers/plans/2026-07-06-configurable-compaction.md).
// ---------------------------------------------------------------------------

test "LlmConfig: LlmProfile.max_capacity_tokens reads value from JSON" {
    const allocator = std.testing.allocator;

    // NOTE: `profiles_models` is a real JSON map (matches the
    // shape the UI sends). The legacy `profile1..profile4` keys
    // are convenience shorthands for tests; both shapes parse to
    // the same internal `ProfilesMap`.
    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "max_capacity_tokens": 128000 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u32, 128000), profile.max_capacity_tokens);
}

test "LlmConfig: LlmProfile.max_capacity_tokens defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u32, null), profile.max_capacity_tokens);
}

test "LlmConfig: LlmProfile.compaction_threshold_percent reads value from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "compaction_threshold_percent": 70 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u8, 70), profile.compaction_threshold_percent);
}

test "LlmConfig: LlmProfile.compaction_threshold_percent defaults to null when missing from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(?u8, null), profile.compaction_threshold_percent);
}

test "LlmConfig: maxCapacityForModel returns profile override when set" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3", "max_capacity_tokens": 1000000 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile override wins over the LLMModels built-in.
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel(&profile, null, null, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u32, 1000000), cfg.maxCapacityForModel(&profile, null, null, "SomeOtherModel"));
}

test "LlmConfig: maxCapacityForModel falls back to LLMModels default when profile has null" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // MiniMax-M3 default is 500_000 (see LLMModels.zig:18).
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(&profile, null, null, "MiniMax-M3"));
    // Unknown model falls back to 200_000 (LLMModels.zig:31).
    try std.testing.expectEqual(@as(u32, 200000), cfg.maxCapacityForModel(&profile, null, null, "Unknown"));
    // No profile at all: same default applies.
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(null, null, null, "MiniMax-M3"));
}

test "LlmConfig: compactionThresholdPercent returns profile override when set" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m", "compaction_threshold_percent": 50 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    try std.testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(&profile, null, null));
}

test "LlmConfig: compactionThresholdPercent returns 80 when no profile / null profile" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": { "profile1": { "model": "m" } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile has null threshold — falls back to built-in 80.
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(&profile, null, null));
    // No profile at all — same default.
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

// ============================================================
// Top-level defaults round-trip + cascade tests
// (restored in plan 2026-07-07-compaction-inline)
// ============================================================

test "LlmConfig: top-level max_capacity_token_model reads from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "max_capacity_token_model": 250000 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, 250000), cfg.max_capacity_token_model);
}

test "LlmConfig: top-level max_capacity_token_model defaults to null when missing" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u32, null), cfg.max_capacity_token_model);
}

test "LlmConfig: top-level compaction_threshold_percent reads from JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b",
        \\  "compaction_threshold_percent": 70 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, 70), cfg.compaction_threshold_percent);
}

test "LlmConfig: top-level compaction_threshold_percent defaults to null when missing" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "m", "base_url": "b" }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(?u8, null), cfg.compaction_threshold_percent);
}

test "LlmConfig: top-level defaults cascade — profile override wins" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 200000,
        \\  "compaction_threshold_percent": 70,
        \\  "profiles_models": { "profile1": { "model": "MiniMax-M3",
        \\      "max_capacity_tokens": 600000,
        \\      "compaction_threshold_percent": 90 } } }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const profile = cfg.profiles_models.get("profile1") orelse unreachable;
    // Profile override (600_000) wins over top-level defaults (200_000).
    try std.testing.expectEqual(@as(u32, 600000), cfg.maxCapacityForModel(&profile, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 90), cfg.compactionThresholdPercent(&profile, null, &cfg));
    // Without profile, top-level defaults apply.
    try std.testing.expectEqual(@as(u32, 200000), cfg.maxCapacityForModel(null, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 70), cfg.compactionThresholdPercent(null, null, &cfg));
}

test "LlmConfig: top-level defaults apply when profile is null (passes through)" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 350000,
        \\  "compaction_threshold_percent": 65 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    // No profile → top-level defaults apply (no LLMModels fallback).
    try std.testing.expectEqual(@as(u32, 350000), cfg.maxCapacityForModel(null, null, &cfg, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 65), cfg.compactionThresholdPercent(null, null, &cfg));
}

test "LlmConfig: top-level defaults are skipped when defaults=null passed" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "api_key": "k", "model": "MiniMax-M3", "base_url": "b",
        \\  "max_capacity_token_model": 200000,
        \\  "compaction_threshold_percent": 70 }
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    // defaults=null skips step 3 → built-in LLMModels default applies.
    try std.testing.expectEqual(@as(u32, 500000), cfg.maxCapacityForModel(null, null, null, "MiniMax-M3"));
    try std.testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}
