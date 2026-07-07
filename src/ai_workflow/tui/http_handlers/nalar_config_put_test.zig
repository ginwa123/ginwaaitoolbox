//! Tests for the live-reload `LlmConfigHolder` semantics on `ContextIPCTui`.
//!
//! These tests verify the swap-and-hold pattern that keeps in-flight
//! workflows (which captured the old `*const LlmConfig` into a local)
//! dereferencing valid memory until the next swap or shutdown.
//!
//! They do NOT exercise the full HTTP handler — that requires a running
//! GinwaServer. The handler-level "reload from disk" path is covered by
//! manual smoke test against `nalar-dev` (see the plan's §4).

const std = @import("std");
const testing = std.testing;

const nalarcore = @import("nalarcore");
const ContextIPCTui = nalarcore.ContextIPCTui;
const LlmConfigHolder = nalarcore.LlmConfigHolder;
const LlmConfig = nalarcore.config.LlmConfig;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal-but-valid `LlmConfig` on the heap, owned by `allocator`.
/// Caller must `free` via `nalarcore.freeAllLlmConfigs` (in production) or
/// the explicit `deinit`+`destroy` here (in tests).
fn makeConfig(allocator: std.mem.Allocator, model: []const u8) !*LlmConfig {
    const ptr = try allocator.create(LlmConfig);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, model),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .notify_on_complete = false,
        // Note: top-level `max_capacity_token_model` and
        // `compaction_threshold_percent` were moved to per-profile
        // fields in Chunk 7 — see `LlmProfile.max_capacity_tokens`
        // and `LlmProfile.compaction_threshold_percent`.
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
    };
    return ptr;
}

/// Build a minimal `ContextIPCTui` carrying the given `LlmConfigHolder`.
/// Other fields are left `undefined` — the holder tests only touch
/// `llm_config_holder` and `allocator`. We must build on the heap because
/// `ContextIPCTui` contains a `std.Io.Group` which is not copyable.
fn makeCtx(allocator: std.mem.Allocator, holder: LlmConfigHolder) !*ContextIPCTui {
    const ctx = try allocator.create(ContextIPCTui);
    ctx.* = .{
        .allocator = allocator,
        .io = undefined, // not used by holder helpers
        .db = undefined, // not used by holder helpers
        .llm_config_holder = holder,
        .logger = undefined, // not used by holder helpers
        .environment = null, // not used by holder helpers
        .active_loops = undefined, // not used by holder helpers
        .event_bus = undefined, // not used by holder helpers
        .server = undefined, // not used by holder helpers
        .group_emit_session_create = undefined, // not used by holder helpers
    };
    return ctx;
}

// ---------------------------------------------------------------------------
// 1. Holder initial state
// ---------------------------------------------------------------------------

test "LlmConfigHolder: initial state has null previous, current is reachable" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    defer {
        cfg_a.deinit();
        allocator.destroy(cfg_a);
    }

    const holder: LlmConfigHolder = .{ .current = cfg_a };
    try testing.expectEqual(@as(?*const LlmConfig, null), holder.previous);
    try testing.expectEqualStrings("model-a", holder.current.model);
}

// ---------------------------------------------------------------------------
// 2. setLlmConfig: replaces current and moves old into previous
// ---------------------------------------------------------------------------

test "setLlmConfig: replaces current and moves old into previous" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    nalarcore.setLlmConfig(ctx, cfg_b);

    try testing.expectEqual(cfg_b, nalarcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);
    // Both pointers are still readable — old config has not been freed yet.
    try testing.expectEqualStrings("model-a", ctx.llm_config_holder.previous.?.model);
    try testing.expectEqualStrings("model-b", nalarcore.getLlmConfig(ctx).model);

    // Cleanup: current=cfg_b, previous=cfg_a. freeAllLlmConfigs frees both.
    nalarcore.freeAllLlmConfigs(ctx);
}

// ---------------------------------------------------------------------------
// 3. setLlmConfig: second swap frees the first old; the most recent old is held
// ---------------------------------------------------------------------------

test "setLlmConfig: second swap frees the first old, holds the most recent" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");
    const cfg_c = try makeConfig(allocator, "model-c");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    // Swap 1: current=cfg_b, previous=cfg_a. No free (previous slot was null).
    nalarcore.setLlmConfig(ctx, cfg_b);
    try testing.expectEqual(cfg_b, nalarcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_a, ctx.llm_config_holder.previous);

    // Swap 2: current=cfg_c, previous=cfg_b. cfg_a is freed inside setLlmConfig
    // (it was the previous slot, promoted to "pending_previous" and freed).
    nalarcore.setLlmConfig(ctx, cfg_c);
    try testing.expectEqual(cfg_c, nalarcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_b, ctx.llm_config_holder.previous);

    // cfg_b is still readable (held as previous).
    try testing.expectEqualStrings("model-b", ctx.llm_config_holder.previous.?.model);
    try testing.expectEqualStrings("model-c", nalarcore.getLlmConfig(ctx).model);

    // Cleanup: current=cfg_c, previous=cfg_b. freeAllLlmConfigs frees both.
    // (cfg_a was already freed inside the 2nd setLlmConfig.)
    nalarcore.freeAllLlmConfigs(ctx);
}

// ---------------------------------------------------------------------------
// 4. freeAllLlmConfigs: drains both current and previous
// ---------------------------------------------------------------------------

test "freeAllLlmConfigs: drains both current and previous" {
    const allocator = testing.allocator;
    const cfg_a = try makeConfig(allocator, "model-a");
    const cfg_b = try makeConfig(allocator, "model-b");

    const ctx = try makeCtx(allocator, .{ .current = cfg_a });
    defer allocator.destroy(ctx);

    nalarcore.setLlmConfig(ctx, cfg_b);
    // Now: current=cfg_b, previous=cfg_a

    nalarcore.freeAllLlmConfigs(ctx);
    // freeAllLlmConfigs sets previous to null (and current to undefined,
    // but we don't read it after).
    try testing.expectEqual(@as(?*const LlmConfig, null), ctx.llm_config_holder.previous);
}

// ---------------------------------------------------------------------------
// 5. Long sequence of swaps: only the most recent two are alive
// ---------------------------------------------------------------------------

test "setLlmConfig: long swap sequence holds only the most recent two configs" {
    const allocator = testing.allocator;

    // Each swap frees the previous-previous. We need 6 unique configs
    // (the initial `current` plus 5 new installs) so that the freed pointer
    // in each call is never reinstalled.
    const cfg_0 = try makeConfig(allocator, "model-0");
    const cfg_1 = try makeConfig(allocator, "model-1");
    const cfg_2 = try makeConfig(allocator, "model-2");
    const cfg_3 = try makeConfig(allocator, "model-3");
    const cfg_4 = try makeConfig(allocator, "model-4");
    const cfg_5 = try makeConfig(allocator, "model-5");

    const ctx = try makeCtx(allocator, .{ .current = cfg_0 });
    defer allocator.destroy(ctx);

    nalarcore.setLlmConfig(ctx, cfg_1); // previous=cfg_0
    nalarcore.setLlmConfig(ctx, cfg_2); // previous=cfg_1, cfg_0 freed
    nalarcore.setLlmConfig(ctx, cfg_3); // previous=cfg_2, cfg_1 freed
    nalarcore.setLlmConfig(ctx, cfg_4); // previous=cfg_3, cfg_2 freed
    nalarcore.setLlmConfig(ctx, cfg_5); // previous=cfg_4, cfg_3 freed

    // Only cfg_5 and cfg_4 are alive. cfg_2 and cfg_3 were both freed.
    try testing.expectEqual(cfg_5, nalarcore.getLlmConfig(ctx));
    try testing.expectEqual(cfg_4, ctx.llm_config_holder.previous);
    try testing.expectEqualStrings("model-5", nalarcore.getLlmConfig(ctx).model);
    try testing.expectEqualStrings("model-4", ctx.llm_config_holder.previous.?.model);

    nalarcore.freeAllLlmConfigs(ctx); // frees cfg_5 + cfg_4
}

// ---------------------------------------------------------------------------
// 6. Public API surface
// ---------------------------------------------------------------------------

test "nalarcore exposes LlmConfigHolder, getLlmConfig, setLlmConfig, freeAllLlmConfigs" {
    try testing.expect(@hasDecl(nalarcore, "LlmConfigHolder"));
    try testing.expect(@hasDecl(nalarcore, "getLlmConfig"));
    try testing.expect(@hasDecl(nalarcore, "setLlmConfig"));
    try testing.expect(@hasDecl(nalarcore, "freeAllLlmConfigs"));
    // `*const LlmConfig` must be a single aligned pointer (same size as
    // a usize on the target) so concurrent readers can do an atomic load
    // without a lock.
    const PtrType = *const LlmConfig;
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(PtrType));
}

// ---------------------------------------------------------------------------
// 7. Static-contract tests for the PUT handler (compaction settings)
// ---------------------------------------------------------------------------
//
// The PUT handler is too integration-heavy to test behaviourally in this
// file (no GinwaServer + DI + sqlite fixture). Per project convention
// (`nalar-http-handler-thin-wrapper-pattern.md`), we assert the contract
// statically by reading the handler source and grepping for required
// substrings.

const PUT_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/nalar_config_put.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

test "PUT handler writes max_capacity_tokens to per-profile JSON" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "profile_change.max_capacity_tokens") == null) {
        std.debug.print("!! PUT handler doesn't read max_capacity_tokens from ProfileChange !!\n", .{});
        return error.ProfileMaxCapacityReadMissing;
    }
    if (std.mem.indexOf(u8, source, "\"max_capacity_tokens\"") == null) {
        std.debug.print("!! PUT handler doesn't write max_capacity_tokens to profile JSON !!\n", .{});
        return error.ProfileMaxCapacityWriteMissing;
    }
}

test "PUT handler writes compaction_threshold_percent to per-profile JSON" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "profile_change.compaction_threshold_percent") == null) {
        std.debug.print("!! PUT handler doesn't read compaction_threshold_percent from ProfileChange !!\n", .{});
        return error.ProfileThresholdReadMissing;
    }
    if (std.mem.indexOf(u8, source, "\"compaction_threshold_percent\"") == null) {
        std.debug.print("!! PUT handler doesn't write compaction_threshold_percent to profile JSON !!\n", .{});
        return error.ProfileThresholdWriteMissing;
    }
}

test "PUT handler rejects compaction_threshold_percent > 100 with InvalidThresholdPercent" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "if (tp > 100) return error.InvalidThresholdPercent;") == null) {
        std.debug.print("!! PUT handler doesn't reject threshold > 100 !!\n", .{});
        return error.ThresholdValidationMissing;
    }
    // The error variant must exist in the LlmConfig.LoadError enum
    // (declared in src/modules/config/Config.zig, NOT in this handler).
    const cfg_source = try readSource(allocator, "src/modules/config/Config.zig");
    defer allocator.free(cfg_source);
    if (std.mem.indexOf(u8, cfg_source, "InvalidThresholdPercent,") == null) {
        std.debug.print("!! LlmConfig.LoadError does not declare InvalidThresholdPercent !!\n", .{});
        return error.LoadErrorMissingInvalidThresholdPercent;
    }
}

test "PUT ConfigInput / ProfileChange declare both new fields as optional" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "max_capacity_tokens: ?u32 = null,") == null) {
        std.debug.print("!! ProfileChange missing max_capacity_tokens optional field !!\n", .{});
        return error.ProfileChangeMissingMaxCapacity;
    }
    if (std.mem.indexOf(u8, source, "compaction_threshold_percent: ?u8 = null,") == null) {
        std.debug.print("!! ProfileChange missing compaction_threshold_percent optional field !!\n", .{});
        return error.ProfileChangeMissingThreshold;
    }
}

test "PUT handler is registered in test_runner.zig" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/test_runner.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "nalar_config_put_test.zig") == null) {
        std.debug.print("!! test_runner.zig does not import nalar_config_put_test.zig !!\n", .{});
        return error.TestRunnerMissingImport;
    }
}
