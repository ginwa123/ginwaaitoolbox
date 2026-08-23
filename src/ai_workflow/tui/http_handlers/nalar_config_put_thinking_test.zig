// Static-contract tests for the model-thinking validation in
// nalar_config_put.zig (plan 2026-08-23-model-thinking).
//
// Per the user preference (2026-08-17 cleanup commit 91c0ee63): no
// HTTP handler `_test.zig` files. Instead, this file uses the same
// source-grep pattern as `nalar_config_put_test.zig` — lock in the
// validation paths via grep + assert that the error variants exist
// in `LlmConfig.LoadError`.

const std = @import("std");
const testing = std.testing;

const PUT_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/nalar_config_put.zig";
const CONFIG_PATH = "src/modules/config/Config.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(128 * 1024));
}

test "PUT handler ProfileChange declares thinking_budget_tokens + reasoning_effort" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "thinking_budget_tokens: ?u32 = null,") == null) {
        std.debug.print("!! ProfileChange missing thinking_budget_tokens field !!\n", .{});
        return error.ProfileChangeMissingThinkingBudgetTokens;
    }
    if (std.mem.indexOf(u8, source, "reasoning_effort: ?[]const u8 = null,") == null) {
        std.debug.print("!! ProfileChange missing reasoning_effort field !!\n", .{});
        return error.ProfileChangeMissingReasoningEffort;
    }
}

test "PUT handler rejects thinking_budget_tokens=0 with InvalidThinkingBudgetTokens" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must guard against t == 0 (which would violate
    // the Anthropic 1024 floor — see plan 2026-08-23-model-thinking).
    if (std.mem.indexOf(u8, source, "if (t == 0 or t > 2_000_000) return error.InvalidThinkingBudgetTokens;") == null) {
        std.debug.print("!! PUT handler doesn't reject t == 0 !!\n", .{});
        return error.ZeroBudgetValidationMissing;
    }
}

test "PUT handler rejects thinking_budget_tokens > 2_000_000 with InvalidThinkingBudgetTokens" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "t > 2_000_000") == null) {
        std.debug.print("!! PUT handler doesn't enforce upper bound 2_000_000 !!\n", .{});
        return error.UpperBoundValidationMissing;
    }
}

test "PUT handler rejects garbage reasoning_effort via parse_thinking helper" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must route reasoning_effort through
    // parse_thinking_mod.parseReasoningEffort so the validation
    // logic lives in exactly one place.
    if (std.mem.indexOf(u8, source, "parseReasoningEffort") == null) {
        std.debug.print("!! PUT handler doesn't call parse_thinking.parseReasoningEffort !!\n", .{});
        return error.ReasoningEffortValidationMissing;
    }
    if (std.mem.indexOf(u8, source, "return error.InvalidReasoningEffort;") == null) {
        std.debug.print("!! PUT handler doesn't surface InvalidReasoningEffort error !!\n", .{});
        return error.ReasoningEffortErrorSurfaceMissing;
    }
}

test "LlmConfig.LoadError declares InvalidThinkingBudgetTokens + InvalidReasoningEffort" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, CONFIG_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "InvalidThinkingBudgetTokens,") == null) {
        std.debug.print("!! LlmConfig.LoadError does not declare InvalidThinkingBudgetTokens !!\n", .{});
        return error.LoadErrorMissingInvalidThinkingBudgetTokens;
    }
    if (std.mem.indexOf(u8, source, "InvalidReasoningEffort,") == null) {
        std.debug.print("!! LlmConfig.LoadError does not declare InvalidReasoningEffort !!\n", .{});
        return error.LoadErrorMissingInvalidReasoningEffort;
    }
}

test "PUT handler validates sub_agents thinking_budget_tokens + reasoning_effort" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The sub_agents block (top-level array) must also enforce the
    // same bounds. The for-loop over `sas` reads sa.thinking_budget_tokens
    // and sa.reasoning_effort from the parsed LlmConfig.SubAgentJson.
    if (std.mem.indexOf(u8, source, "sa.thinking_budget_tokens") == null) {
        std.debug.print("!! PUT handler doesn't read sub_agent thinking_budget_tokens !!\n", .{});
        return error.SubAgentBudgetReadMissing;
    }
    if (std.mem.indexOf(u8, source, "sa.reasoning_effort") == null) {
        std.debug.print("!! PUT handler doesn't read sub_agent reasoning_effort !!\n", .{});
        return error.SubAgentEffortReadMissing;
    }
}

test "PUT handler validates on-disk object-map shape profiles" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The on-disk shape (object map) bypasses the typed
    // ProfileChange parse path, so the handler must validate raw
    // json.Value entries before deep-copying. The
    // `validateModelThinkingOnDiskProfileMap` helper does this.
    if (std.mem.indexOf(u8, source, "validateModelThinkingOnDiskProfileMap") == null) {
        std.debug.print("!! PUT handler missing validateModelThinkingOnDiskProfileMap helper !!\n", .{});
        return error.OnDiskValidationHelperMissing;
    }
}