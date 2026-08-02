//! CLI configuration: server URL + optional session/profile defaults.
//!
//! Resolution order (highest priority first):
//!   1. CLI flags (`--server`, `--session`, `--profile`)
//!   2. Environment variables: `NALARCLI_SERVER`, `NALARCLI_SESSION_ID`,
//!      `NALARCLI_PROFILE`
//!   3. Compile-time defaults (see `default_server`).
//!
//! Defines a `Config` struct + a `load` helper. Tests live in
//! `tests/config_test.zig`.

const std = @import("std");

/// Default server URL used when neither flag nor env is set.
pub const default_server = "http://localhost:8081";

/// Runtime configuration for one CLI invocation.
pub const Config = struct {
    server: []const u8,
    /// Borrowed slices: either the cli flag or the env map. Both
    /// are required to outlive the Config (env: the `Init.environ_map`;
    /// flags: the caller's flag storage).
    session_id: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

pub const env_server = "NALARCLI_SERVER";
pub const env_session = "NALARCLI_SESSION_ID";
pub const env_profile = "NALARCLI_PROFILE";

/// Look up an env var. Returns null if unset or empty.
fn getEnvOrNull(environment: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = environment.get(key) orelse return null;
    if (v.len == 0) return null;
    return v;
}

/// Load config from CLI flags + env. The returned `server` slice is
/// heap-allocated (caller frees with `allocator.free`); the
/// `session_id` and `profile` slices are borrowed (see Config docs).
pub fn load(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    flag_server: ?[]const u8,
    flag_session: ?[]const u8,
    flag_profile: ?[]const u8,
) !Config {
    const server_src = flag_server orelse getEnvOrNull(environment, env_server) orelse default_server;
    const cfg = Config{
        .server = try allocator.dupe(u8, server_src),
        .session_id = flag_session orelse getEnvOrNull(environment, env_session),
        .profile = flag_profile orelse getEnvOrNull(environment, env_profile),
    };
    return cfg;
}

/// Free the heap-allocated `server` slice. Safe to call on a config
/// returned by `load` (the borrowed fields are not freed).
pub fn deinit(cfg: *Config, allocator: std.mem.Allocator) void {
    allocator.free(cfg.server);
    cfg.server = &[_]u8{};
}
