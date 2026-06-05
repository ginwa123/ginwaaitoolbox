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
