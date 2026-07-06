//! Integration test for the config-driven compaction threshold chain.
//!
//! Asserts that `LlmConfig.compactionThresholdPercent()` correctly
//! drives `LLMModels.shouldCompact` decisions — i.e., two configs with
//! the same model but different `compaction_threshold_percent` values
//! produce DIFFERENT compaction decisions at the same token count.
//!
//! Regression test that would catch a future bug where the threshold
//! was wired to the wrong config field, or where `shouldCompact` lost
//! its `?u8` override parameter.

const std = @import("std");
const testing = std.testing;

const nalarcore = @import("nalarcore");
const LLMModels = nalarcore.llm_models;

/// Build a minimal `LlmConfig` with only the `compaction_threshold_percent`
/// field set — fields not relevant to the test default to safe empty values.
/// The returned pointer owns its heap allocations and must be `deinit`ed
/// + freed by the caller.
fn makeLlmConfigWithThreshold(
    allocator: std.mem.Allocator,
    threshold: ?u8,
) !*nalarcore.config.LlmConfig {
    const cfg_ptr = try allocator.create(nalarcore.config.LlmConfig);
    cfg_ptr.* = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = threshold,
        .notify_on_complete = false,
        .mcpServers_parsed = null,
        .mcp_servers = nalarcore.config.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = nalarcore.config.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
    };
    return cfg_ptr;
}

test "compaction_threshold_percent: null falls back to 80% built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfigWithThreshold(allocator, null);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    try testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent());
}

test "compaction_threshold_percent: explicit override wins over built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfigWithThreshold(allocator, 50);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent());
}

test "compaction: two configs with different thresholds produce different decisions at the same token count" {
    const allocator = testing.allocator;

    // Two configs — same model + capacity, different thresholds only.
    const cfg80 = try makeLlmConfigWithThreshold(allocator, null); // → 80
    defer {
        cfg80.deinit();
        allocator.destroy(cfg80);
    }
    const cfg50 = try makeLlmConfigWithThreshold(allocator, 50);
    defer {
        cfg50.deinit();
        allocator.destroy(cfg50);
    }

    const cap: u32 = cfg80.maxCapacityForModel("MiniMax-M2.7");
    const at_79pct: u32 = cap * 79 / 100; // ~158,000 with 200k default

    // 79% of 200,000 = 158,000 — below the 80% threshold → no compact
    // under cfg80 (which uses the built-in 80% default).
    try testing.expect(!LLMModels.shouldCompact(
        at_79pct,
        cfg80.maxCapacityForModel("MiniMax-M2.7"),
        cfg80.compactionThresholdPercent(),
    ));

    // 79% is above 50% threshold → compact under cfg50.
    try testing.expect(LLMModels.shouldCompact(
        at_79pct,
        cfg50.maxCapacityForModel("MiniMax-M2.7"),
        cfg50.compactionThresholdPercent(),
    ));
}

test "compaction: max_capacity_token_model override shifts the threshold proportionally" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfigWithThreshold(allocator, 50);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    const model = "MiniMax-M2.7";
    try testing.expectEqual(@as(u32, 200_000), LLMModels.getModelTokenCount(model));

    // Set a 2x override on capacity; threshold stays 50%.
    cfg.max_capacity_token_model = 400_000;
    try testing.expectEqual(@as(u32, 400_000), cfg.maxCapacityForModel(model));

    // Sanity: with built-in capacity (200k) and 50% threshold, the
    // boundary token count is 100k — at 50k we are below.
    try testing.expect(!LLMModels.shouldCompact(50_000, 200_000, 50));
    try testing.expect(LLMModels.shouldCompact(100_000, 200_000, 50));

    // With the 2x capacity override (400k) and same 50% threshold, the
    // boundary shifts to 200k — at 100k we are now below (was at the
    // boundary without the override).
    try testing.expect(!LLMModels.shouldCompact(
        100_000,
        cfg.maxCapacityForModel(model),
        cfg.compactionThresholdPercent(),
    ));
    try testing.expect(LLMModels.shouldCompact(
        200_000,
        cfg.maxCapacityForModel(model),
        cfg.compactionThresholdPercent(),
    ));
}
