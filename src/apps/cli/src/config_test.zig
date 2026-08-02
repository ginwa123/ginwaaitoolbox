//! Tests for src/config.zig.

const std = @import("std");
const testing = std.testing;
const config_mod = @import("config.zig");

test "load: all defaults when no flags and no env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    var cfg = try config_mod.load(testing.allocator, &env, null, null, null);
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://localhost:8081", cfg.server);
    try testing.expect(cfg.session_id == null);
    try testing.expect(cfg.profile == null);
}

test "load: flag overrides env and default" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NALARCLI_SERVER", "http://env:1234");

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        "http://flag:5678",
        null,
        null,
    );
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://flag:5678", cfg.server);
}

test "load: env overrides default when no flag" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NALARCLI_SERVER", "http://env:9090");

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("http://env:9090", cfg.server);
}

test "load: session + profile fall through to env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NALARCLI_SESSION_ID", "session-env");
    try env.put("NALARCLI_PROFILE", "profile-env");

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("session-env", cfg.session_id.?);
    try testing.expectEqualStrings("profile-env", cfg.profile.?);
}

test "load: flag session/profile override env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NALARCLI_SESSION_ID", "session-env");
    try env.put("NALARCLI_PROFILE", "profile-env");

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        null,
        "session-flag",
        "profile-flag",
    );
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expectEqualStrings("session-flag", cfg.session_id.?);
    try testing.expectEqualStrings("profile-flag", cfg.profile.?);
}

test "load: empty env value is treated as missing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NALARCLI_SESSION_ID", "");

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        null,
        null,
        null,
    );
    defer config_mod.deinit(&cfg, testing.allocator);

    try testing.expect(cfg.session_id == null);
}

test "deinit: frees server slice only" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    var cfg = try config_mod.load(
        testing.allocator,
        &env,
        "http://example:1234",
        null,
        null,
    );
    const slice = cfg.server;

    config_mod.deinit(&cfg, testing.allocator);

    // The helper resets the slice pointer to a static empty string
    // (safe to inspect after deinit; we just verify the value).
    try testing.expectEqualStrings("", cfg.server);
    // The original slice is still the heap-allocated copy — we just
    // can't safely access it after deinit without a use-after-free.
    _ = slice;
}
