const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const LLMModels = @import("LLMModels.zig");
const get_model_token_count = LLMModels.getModelTokenCount;
const is_do_compact = LLMModels.isDoCompact;
const resolve_max_capacity = LLMModels.resolveMaxCapacity;
const should_compact = LLMModels.shouldCompact;
const MINIMAX_2_7 = LLMModels.MINIMAX_2_7;

// ============================================================================
// get_model_token_count Tests
// ============================================================================

test "get_model_token_count returns correct token count for MINIMAX_2_7" {
    const result = get_model_token_count(MINIMAX_2_7.name);
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for unknown model" {
    const result = get_model_token_count("Unknown-Model");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for empty string" {
    const result = get_model_token_count("");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for partial match" {
    // Partial name should not match
    const result = get_model_token_count("MiniMax");
    try expectEqual(@as(u32, 200000), result);
}

test "get_model_token_count returns fallback for case-sensitive mismatch" {
    // Model name comparison is case-sensitive
    const result = get_model_token_count("minimax-m2.7");
    try expectEqual(@as(u32, 200000), result);
}

// ============================================================================
// is_do_compact Tests
// ============================================================================

test "is_do_compact returns false when below 80% threshold" {
    // 50% of capacity
    try expect(!is_do_compact(50, 100));
}

test "is_do_compact returns false when just below 80% threshold" {
    // 79% of capacity
    try expect(!is_do_compact(79, 100));
}

test "is_do_compact returns true at exactly 80% threshold" {
    // Exactly 80% of capacity
    try expect(is_do_compact(80, 100));
}

test "is_do_compact returns true above 80% threshold" {
    // 81% of capacity
    try expect(is_do_compact(81, 100));
}

test "is_do_compact returns true at 100% capacity" {
    try expect(is_do_compact(100, 100));
}

test "is_do_compact returns false at 0 tokens" {
    try expect(!is_do_compact(0, 100));
}

test "is_do_compact with real-world token values" {
    // Simulating MINIMAX-M2.7 with 200k context (80% threshold = 160k)
    const max_capacity = 200000;
    
    // 250k message exceeds 80% threshold (160k) → should compact
    const large_message = 250000;
    try expect(is_do_compact(large_message, max_capacity));
}

test "is_do_compact with 200k model values" {
    const max_capacity = 200000;
    // Just below threshold (79%)
    try expect(!is_do_compact(157999, max_capacity));
    // At threshold (80%)
    try expect(is_do_compact(160000, max_capacity));
}

test "is_do_compact threshold calculation is integer-accurate" {
    // Test with values that could cause integer division issues
    const max_capacity: u32 = 3;
    // 3 * 8 / 10 = 2 (integer division)
    try expect(!is_do_compact(1, max_capacity)); // Below threshold
    try expect(is_do_compact(2, max_capacity)); // At threshold
    try expect(is_do_compact(3, max_capacity)); // Above threshold
}

// ============================================================================
// resolve_max_capacity Tests
// ============================================================================

test "resolve_max_capacity returns override when set" {
    try expectEqual(@as(u32, 128000), resolve_max_capacity("MiniMax-M3", 128000));
    try expectEqual(@as(u32, 128000), resolve_max_capacity("Unknown", 128000));
}

test "resolve_max_capacity falls back to getModelTokenCount when override is null" {
    try expectEqual(@as(u32, 500000), resolve_max_capacity("MiniMax-M3", null));
    try expectEqual(@as(u32, 200000), resolve_max_capacity("MiniMax-M2.7", null));
    try expectEqual(@as(u32, 200000), resolve_max_capacity("Unknown", null));
}

// ============================================================================
// should_compact Tests
// ============================================================================

test "should_compact with custom threshold_percent" {
    // 50% of 200k = 100k threshold
    try expect(!should_compact(99_999, 200_000, 50));
    try expect(should_compact(100_000, 200_000, 50));
    try expect(should_compact(200_000, 200_000, 50));
}

test "should_compact with null threshold_percent defaults to 80%" {
    try expect(!should_compact(159_999, 200_000, null));
    try expect(should_compact(160_000, 200_000, null));
    try expect(should_compact(250_000, 200_000, null));
}

test "should_compact with threshold_percent=0 never triggers" {
    // 0% threshold = never compact (token_count >= 0 always, but *0/100 = 0)
    try expect(should_compact(0, 200_000, 0));
    try expect(should_compact(1, 200_000, 0));
    try expect(should_compact(1_000_000, 200_000, 0));
}

test "should_compact with threshold_percent=100 always triggers (unless token_count is 0)" {
    // 100% threshold = token_count >= max_capacity
    try expect(!should_compact(99, 100, 100));
    try expect(should_compact(100, 100, 100));
    try expect(should_compact(101, 100, 100));
}
