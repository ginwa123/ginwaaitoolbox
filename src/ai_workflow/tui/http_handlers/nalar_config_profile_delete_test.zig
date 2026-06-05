//! Tests for the pure `removeProfileFromConfig` helper used by the
//! `DELETE /api/config/nalar/profiles/:name` handler. The helper is
//! split out from the handler so the file-system roundtrip does not
//! need to be exercised by the unit test — the existing
//! `nalar_config_put_test.zig` already documents the convention of
//! NOT exercising the full HTTP handler.

const std = @import("std");
const testing = std.testing;
const json = std.json;

const nalarcore = @import("nalarcore");
// The symbols under test (`removeProfileFromConfig` and
// `NalarConfigJsonForDelete`) are defined in
// `ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig`
// and re-exported by `http_handlers/mod.zig`. We import them via
// `nalarcore.http_handlers.X` (rather than the top-level `nalarcore.X`
// used by the sibling `nalar_config_put_test.zig`) because they are
// HTTP-handler implementation details — they are NOT part of the
// public nalarcore surface and the convention is that handler
// internals stay scoped under `nalarcore.http_handlers`.
const removeProfileFromConfig = nalarcore.http_handlers.removeProfileFromConfig;
const NalarConfigJsonForDelete = nalarcore.http_handlers.NalarConfigJsonForDelete;

// ---------- Helpers ----------

/// Build a `NalarConfigJsonForDelete` with two profiles (`alpha` and
/// `beta`) and `active_profile = "alpha"`. All string fields are duped
/// from `allocator`; `profiles_models` is a populated `ObjectMap`.
/// Caller MUST `defer cfg.deinit(allocator)`.
fn makeConfigJson(allocator: std.mem.Allocator) !NalarConfigJsonForDelete {
    var cfg: NalarConfigJsonForDelete = .{};
    errdefer cfg.deinit(allocator);

    cfg.api_key = try allocator.dupe(u8, "test-key");
    cfg.model = try allocator.dupe(u8, "gpt-4o");
    cfg.base_url = try allocator.dupe(u8, "https://api.example.com");
    cfg.url_style = try allocator.dupe(u8, "openai");
    cfg.max_tokens = null;
    cfg.system_prompt = try allocator.dupe(u8, "");
    cfg.active_profile = try allocator.dupe(u8, "alpha");

    // Build the profiles map as a local var, populate it, then attach
    // to `cfg` — the same pattern used in `nalar_config_put.zig`.
    // We can't do `var profiles = cfg.profiles_models.?.object;` and
    // then `put` into `profiles` because in Zig 0.15.2 the
    // tagged-union field access returns a COPY of the ObjectMap
    // struct (not a pointer into the union's storage), so puts go
    // to the local copy and the original `cfg.profiles_models` stays
    // empty. The helper would then find no profile to remove.
    var profiles = try json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer profiles.deinit(allocator);

    // alpha
    var alpha = try json.ObjectMap.init(allocator, &.{}, &.{});
    try alpha.put(allocator, "model", .{ .string = try allocator.dupe(u8, "gpt-4o") });
    try alpha.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.example.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "alpha"), .{ .object = alpha });

    // beta
    var beta = try json.ObjectMap.init(allocator, &.{}, &.{});
    try beta.put(allocator, "model", .{ .string = try allocator.dupe(u8, "claude") });
    try beta.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.anthropic.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "beta"), .{ .object = beta });

    cfg.profiles_models = .{ .object = profiles };
    return cfg;
}

/// Build a minimal `NalarConfigJsonForDelete` with `profiles_models =
/// null` and `active_profile = null` — exercises the
/// "missing profiles_models" graceful path. All string fields are
/// duped as empty strings. Caller MUST `defer cfg.deinit(allocator)`.
fn makeEmptyConfigJson(allocator: std.mem.Allocator) !NalarConfigJsonForDelete {
    var cfg: NalarConfigJsonForDelete = .{};
    errdefer cfg.deinit(allocator);

    cfg.api_key = try allocator.dupe(u8, "");
    cfg.model = try allocator.dupe(u8, "");
    cfg.base_url = try allocator.dupe(u8, "");
    cfg.url_style = try allocator.dupe(u8, "openai");
    cfg.max_tokens = null;
    cfg.system_prompt = try allocator.dupe(u8, "");
    cfg.profiles_models = null;
    cfg.active_profile = null;

    return cfg;
}

test "removeProfileFromConfig: removes the named profile and returns true" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(removed);

    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 1), obj.count());
    try testing.expect(obj.get("alpha") == null);
    try testing.expect(obj.get("beta") != null);
}

test "removeProfileFromConfig: returns false when the profile does not exist" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "ghost");
    try testing.expect(!removed);

    // Existing profiles unchanged
    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 2), obj.count());
}

test "removeProfileFromConfig: clears active_profile when it matches the deleted name" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(cfg.active_profile == null);
}

test "removeProfileFromConfig: preserves active_profile when it does not match" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "beta");
    try testing.expectEqualStrings("alpha", cfg.active_profile.?);
}

test "removeProfileFromConfig: handles missing profiles_models gracefully" {
    const allocator = testing.allocator;
    var cfg = try makeEmptyConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(!removed);
}
