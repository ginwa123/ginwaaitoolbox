const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const LLMModels = @import("LLMModels.zig");
const get_model_token_count = LLMModels.get_model_token_count;
const is_do_compact = LLMModels.is_do_compact;
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
