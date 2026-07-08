//! Integration test for the per-profile compaction threshold chain.
//!
//! Asserts that `LlmConfig.compactionThresholdPercent(profile, sub_agent)`
//! correctly drives `LLMModels.shouldCompact` decisions — i.e., two
//! configs with the same model but different
//! `LlmProfile.compaction_threshold_percent` values produce DIFFERENT
//! compaction decisions at the same token count.
//!
//! Regression test that would catch a future bug where the threshold
//! was wired to the wrong config field, or where the resolver lost its
//! `profile` / `sub_agent` cascade parameters (Chunk 7 reshape).

const std = @import("std");
const testing = std.testing;

const nalarcore = @import("nalarcore");
const LLMModels = nalarcore.llm_models;
const LlmProfile = nalarcore.config.LlmConfig.LlmProfile;
const SubAgentConfig = nalarcore.config.LlmConfig.SubAgentConfig;

/// Build a minimal `LlmConfig` with no per-profile overrides. The
/// returned pointer owns its heap allocations and must be `deinit`ed
/// + freed by the caller.
fn makeLlmConfig(allocator: std.mem.Allocator) !*nalarcore.config.LlmConfig {
    const cfg_ptr = try allocator.create(nalarcore.config.LlmConfig);
    cfg_ptr.* = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .notify_on_complete = false,
        .mcpServers_parsed = null,
        .mcp_servers = nalarcore.config.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = nalarcore.config.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
    };
    return cfg_ptr;
}

/// Build an LlmProfile with the given threshold. The returned
/// pointer owns its heap allocations; pair with `freeProfile`.
fn makeProfile(
    allocator: std.mem.Allocator,
    name: []const u8,
    threshold: ?u8,
    max_capacity: ?u32,
) !*LlmProfile {
    const p = try allocator.create(LlmProfile);
    p.* = .{
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "test-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .sub_agents = &.{},
        .max_capacity_tokens = max_capacity,
        .compaction_threshold_percent = threshold,
    };
    _ = name;
    return p;
}

/// Free the inner strings of an LlmProfile (allocated by `makeProfile`),
/// then destroy the struct itself. Mirrors `freeProfilesMap`'s per-entry
/// cleanup (Config.zig:431-440).
fn freeProfile(allocator: std.mem.Allocator, p: *LlmProfile) void {
    allocator.free(p.model);
    allocator.free(p.base_url);
    allocator.free(p.thinking);
    allocator.free(p.temperature);
    allocator.free(p.api_key);
    allocator.free(p.url_style);
    // sub_agents is `&.{}` in makeProfile (empty slice) — no free needed.
    allocator.destroy(p);
}

test "compactionThresholdPercent: null profile falls back to 80% built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    try testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

test "compactionThresholdPercent: profile override wins over built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile);
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, null));
}

test "compaction: two profiles with different thresholds produce different decisions at the same token count" {
    const allocator = testing.allocator;

    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile_80 = try makeProfile(allocator, "prod", null, null); // → 80 (built-in)
    defer freeProfile(allocator, profile_80);
    const profile_50 = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile_50);

    const model = "MiniMax-M2.7";
    const cap: u32 = cfg.maxCapacityForModel(null, null, null, model);
    const at_79pct: u32 = cap * 79 / 100; // ~158,000 with 200k default

    // 79% of 200,000 = 158,000 — below the 80% threshold → no compact
    // under profile_80 (which uses the built-in 80% default).
    try testing.expect(!LLMModels.shouldCompact(
        at_79pct,
        cfg.maxCapacityForModel(profile_80, null, null, model),
        cfg.compactionThresholdPercent(profile_80, null, null),
    ));

    // 79% is above 50% threshold → compact under profile_50.
    try testing.expect(LLMModels.shouldCompact(
        at_79pct,
        cfg.maxCapacityForModel(profile_50, null, null, model),
        cfg.compactionThresholdPercent(profile_50, null, null),
    ));
}

test "compaction: max_capacity_tokens override shifts the threshold proportionally" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile = try makeProfile(allocator, "dev", 50, 400_000);
    defer freeProfile(allocator, profile);

    const model = "MiniMax-M2.7";
    try testing.expectEqual(@as(u32, 200_000), LLMModels.getModelTokenCount(model));

    // With the 2x capacity override (400k) and same 50% threshold, the
    // boundary shifts to 200k — at 100k we are below (was at the
    // boundary without the override).
    try testing.expectEqual(@as(u32, 400_000), cfg.maxCapacityForModel(profile, null, null, model));
    try testing.expect(!LLMModels.shouldCompact(
        100_000,
        cfg.maxCapacityForModel(profile, null, null, model),
        cfg.compactionThresholdPercent(profile, null, null),
    ));
    try testing.expect(LLMModels.shouldCompact(
        200_000,
        cfg.maxCapacityForModel(profile, null, null, model),
        cfg.compactionThresholdPercent(profile, null, null),
    ));
}

test "compaction: sub-agent override beats parent profile (cascade)" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    // Parent profile uses 50% threshold.
    const profile = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile);
    // Sub-agent tightens to 90% — should win over the parent.
    const sub_agent = try allocator.create(SubAgentConfig);
    sub_agent.* = .{
        .name = try allocator.dupe(u8, "alpha"),
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "test-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .system_prompt = try allocator.dupe(u8, ""),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = 90,
    };
    defer {
        allocator.free(sub_agent.name);
        allocator.free(sub_agent.model);
        allocator.free(sub_agent.base_url);
        allocator.free(sub_agent.thinking);
        allocator.free(sub_agent.temperature);
        allocator.free(sub_agent.url_style);
        allocator.free(sub_agent.api_key);
        allocator.free(sub_agent.system_prompt);
        allocator.destroy(sub_agent);
    }

    // Sub-agent cascade wins: 90% threshold (not 50% from profile).
    try testing.expectEqual(@as(u8, 90), cfg.compactionThresholdPercent(profile, sub_agent, null));
    // Without sub-agent: profile's 50% wins.
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, null));
    // Without profile and sub-agent: built-in 80%.
    try testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

test "compactionThresholdPercent: top-level defaults (cfg) cascade before built-in" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    // Set top-level default to 65% on the cfg itself.
    cfg.compaction_threshold_percent = 65;
    cfg.max_capacity_token_model = 350_000;

    // No profile, no sub-agent → top-level defaults apply.
    try testing.expectEqual(@as(u8, 65), cfg.compactionThresholdPercent(null, null, cfg));
    try testing.expectEqual(@as(u32, 350_000), cfg.maxCapacityForModel(null, null, cfg, "MiniMax-M2.7"));

    // Profile override (50%) wins over top-level defaults (65%).
    const profile = try makeProfile(allocator, "dev", 50, 600_000);
    defer freeProfile(allocator, profile);
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, cfg));
    try testing.expectEqual(@as(u32, 600_000), cfg.maxCapacityForModel(profile, null, cfg, "MiniMax-M2.7"));
}