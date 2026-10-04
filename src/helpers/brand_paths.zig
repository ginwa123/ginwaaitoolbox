//! Legacy-name compatibility for the nalar → pabrik rebrand.
//!
//! The app was renamed, but the directories, files and cookies an earlier
//! version wrote are still on every user's disk. Renaming a path without a
//! read-through here does not "clean up the old name" — it silently orphans
//! the config, the database, the memories, the skills and the agent personas,
//! and the failure surfaces as an app that looks like a fresh install.
//!
//! The rule this module encodes, applied by every resolver:
//!
//!   * WRITE only to the current name (`pabrik`).
//!   * READ from the current name when it exists, otherwise from the legacy
//!     name (`nalar`) when that exists.
//!
//! So an upgraded install keeps working untouched, and a fresh install never
//! creates a legacy-named directory. Nothing here migrates or deletes user
//! data — that is deliberately left to the user (`pabrik service migrate`).
//!
//! The `legacy_*` names are the ONLY sanctioned surviving occurrences of the
//! old brand in the codebase, so grepping for `legacy_app_name` finds every
//! compatibility seam.

const std = @import("std");

/// Directory name of the app in `$XDG_CONFIG_HOME`, `$HOME/Library/Application
/// Support`, `$HOME/.config`, `%APPDATA%`, `$XDG_STATE_HOME`, …
pub const app_name = "pabrik";

/// The name this app shipped under before the rebrand.
pub const legacy_app_name = "nalar";

/// Project-local directory (skills, memories, agents, hooks, design pages).
pub const local_dir_name = ".pabrik";

/// The project-local directory name before the rebrand.
pub const legacy_local_dir_name = ".nalar";

/// Project memory file auto-loaded into every session's context.
pub const memory_file_name = "PABRIK.md";

/// Pre-rebrand project memory file. Still read: renaming it would silently
/// stop loading the build commands a user wrote into their project long ago.
pub const legacy_memory_file_name = "NALAR.md";

/// True when `path` exists as a file or a directory.
///
/// Deliberately not `std.fs.accessAbsolute` — that was removed in Zig 0.16 and
/// its stdlib replacement needs an `Io` handle, which the pure path resolvers
/// do not have. `access(2)` is a single syscall and works on Linux, macOS and
/// Windows (UCRT).
pub fn exists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, 0) == 0;
}

/// Choose between two fully-joined candidate paths, freeing the loser.
///
/// Both arguments must be owned by `allocator`. Returns `current` whenever it
/// exists, or when neither exists (so a fresh install writes to the new name);
/// only when `current` is absent AND `legacy` is present does it return
/// `legacy`, which is what keeps a pre-rebrand install readable.
pub fn choose(allocator: std.mem.Allocator, current: []u8, legacy: []u8) []u8 {
    if (exists(current)) {
        allocator.free(legacy);
        return current;
    }
    if (exists(legacy)) {
        allocator.free(current);
        return legacy;
    }
    allocator.free(legacy);
    return current;
}

/// Same rule for two paths the caller still owns — no allocation happens, so
/// nothing is freed. Useful when both candidates are stack-built.
pub fn preferExisting(current: []const u8, legacy: []const u8) []const u8 {
    if (exists(current)) return current;
    if (exists(legacy)) return legacy;
    return current;
}

test "choose keeps the current path, and frees the losing candidate" {
    const alloc = std.testing.allocator;
    const here = "src/helpers/brand_paths.zig"; // exists on disk
    const gone = "src/helpers/brand_paths-legacy-gone";

    // current exists -> current wins, and `legacy` is freed (testing allocator
    // would report a leak otherwise)
    const cur = try alloc.dupe(u8, here);
    const leg = try alloc.dupe(u8, gone);
    const chosen = choose(alloc, cur, leg);
    defer alloc.free(chosen);
    try std.testing.expectEqualStrings(here, chosen);

    // current missing, legacy exists -> legacy wins
    const cur2 = try alloc.dupe(u8, gone);
    const leg2 = try alloc.dupe(u8, here);
    const chosen2 = choose(alloc, cur2, leg2);
    defer alloc.free(chosen2);
    try std.testing.expectEqualStrings(here, chosen2);

    // neither exists -> the caller writes to the current name
    const cur3 = try alloc.dupe(u8, gone);
    const leg3 = try alloc.dupe(u8, "src/helpers/brand_paths-legacy-either");
    const chosen3 = choose(alloc, cur3, leg3);
    defer alloc.free(chosen3);
    try std.testing.expectEqualStrings(gone, chosen3);
}

test "preferExisting reads the legacy path only while it is the one on disk" {
    const here = "src/helpers/brand_paths.zig";
    const gone = "src/helpers/brand_paths-legacy-does-not-exist";
    try std.testing.expectEqualStrings(here, preferExisting(here, gone));
    try std.testing.expectEqualStrings(here, preferExisting(gone, here));
    try std.testing.expectEqualStrings(gone, preferExisting(gone, "src/helpers/nope"));
}

test "the current name and its legacy spelling stay distinguishable" {
    try std.testing.expect(!std.mem.eql(u8, app_name, legacy_app_name));
    try std.testing.expect(!std.mem.eql(u8, local_dir_name, legacy_local_dir_name));
    try std.testing.expect(!std.mem.eql(u8, memory_file_name, legacy_memory_file_name));
}
