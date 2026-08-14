//! Tests for `design_io.zig` (sanitizeFilename, atomicWriteFile,
//! deleteFileIfExists, deleteDirectoryRecursively).
//!
//! The atomic-write test reads back the file via `Io.Dir.readFileAlloc`
//! (the stdlib's Zig-0.16-onwards replacement for the removed
//! `std.fs.cwd().readFileAlloc` — see project memory
//! `zig-0.16-stdfs-cwd-removed.md`).

const std = @import("std");
const testing = std.testing;
const design_io = @import("design_io.zig");

// ─── sanitizeFilename ─────────────────────────────────────────────────────

test "sanitizeFilename replaces /, \\, NUL with _" {
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "login/card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("login_card", result);
    }
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "win\\card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("win_card", result);
    }
    // NUL gets replaced with '_' — the binary buffer can't contain
    // a literal NUL in a Zig slice but a 1-char input gets the
    // single NUL replaced.
    var buf: [1]u8 = .{0};
    const result = try design_io.sanitizeFilename(testing.allocator, &buf);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("_", result);
}

test "sanitizeFilename strips leading dots" {
    {
        const result = try design_io.sanitizeFilename(testing.allocator, ".hidden");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("hidden", result);
    }
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "..card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("card", result);
    }
    // "../foo" → pass 1: ".._foo" → leading-dot strip: "_foo".
    // (Both dots are at the start, so the second pass strips them
    // away, leaving only the substituted underscore.)
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "../foo");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("_foo", result);
    }
}

test "sanitizeFilename returns untitled for empty input (no fallback on slashes/dots)" {
    // Empty input → untitled.
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("untitled", result);
    }
    // "..." → pass 1 keeps the dots → leading-dot strip removes
    // them all → empty → "untitled".
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "...");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("untitled", result);
    }
    // "////" → pass 1 replaces each / with _ → "____" — no leading
    // dots, no empty result, so the literal "____" is returned.
    {
        const result = try design_io.sanitizeFilename(testing.allocator, "////");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("____", result);
    }
}

// ─── atomicWriteFile ──────────────────────────────────────────────────────

test "atomicWriteFile writes content that can be read back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the tmpdir's absolute directory path first (dir.realPath,
    // not file.realPathFile which requires the file to exist).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "test.html" });
    defer testing.allocator.free(path);

    try design_io.atomicWriteFile(testing.allocator, path, "<div>hello</div>");

    // Read back. Uses Dir.readFileAlloc per project memory
    // `zig-0.16-stdfs-cwd-removed.md` (std.fs.cwd() is gone in 0.16).
    const content = try tmp.dir.readFileAlloc(testing.io, "test.html", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("<div>hello</div>", content);
}

test "atomicWriteFile overwrites an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "test.html" });
    defer testing.allocator.free(path);

    try design_io.atomicWriteFile(testing.allocator, path, "first");
    try design_io.atomicWriteFile(testing.allocator, path, "second");

    const content = try tmp.dir.readFileAlloc(testing.io, "test.html", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second", content);
}

// ─── deleteFileIfExists ──────────────────────────────────────────────────

test "deleteFileIfExists succeeds when the file is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "never-existed.html" });
    defer testing.allocator.free(path);

    // No file at `path` — should NOT error, just return successfully.
    try design_io.deleteFileIfExists(testing.allocator, path);
}

test "deleteFileIfExists removes an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "to-delete.html" });
    defer testing.allocator.free(path);

    try design_io.atomicWriteFile(testing.allocator, path, "delete me");

    // Sanity: the file exists.
    const stat_before = try tmp.dir.statFile(testing.io, "to-delete.html", .{});
    try testing.expect(stat_before.kind == .file);

    // Delete it.
    try design_io.deleteFileIfExists(testing.allocator, path);

    // After delete, file is gone.
    const stat_after_result = tmp.dir.statFile(testing.io, "to-delete.html", .{});
    try testing.expectError(error.FileNotFound, stat_after_result);
}

// ─── deleteDirectoryIfEmpty ───────────────────────────────────────────────

test "deleteDirectoryIfEmpty removes an empty directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const empty_path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "empty" });
    defer testing.allocator.free(empty_path);

    // Create the empty directory inside the test tmpdir. Uses
    // Io.Dir.cwd().createDirPath which is the Io-native mkdir-p
    // (per project memory zig-0.16-stdfs-cwd-removed.md).
    try std.Io.Dir.cwd().createDirPath(testing.io, empty_path);

    // Sanity: it exists.
    const stat_before = try tmp.dir.statFile(testing.io, "empty", .{});
    try testing.expect(stat_before.kind == .directory);

    // deleteDirectoryIfEmpty should succeed.
    try design_io.deleteDirectoryIfEmpty(testing.allocator, empty_path);

    // After: directory is gone.
    const stat_after_result = tmp.dir.statFile(testing.io, "empty", .{});
    try testing.expectError(error.FileNotFound, stat_after_result);
}

test "deleteDirectoryIfEmpty succeeds when the path does not exist (no-op)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const never_existed = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "never-existed" });
    defer testing.allocator.free(never_existed);

    // Should NOT error — ENOENT is swallowed.
    try design_io.deleteDirectoryIfEmpty(testing.allocator, never_existed);
}

test "deleteDirectoryIfEmpty returns DirNotEmpty when a file remains inside" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const non_empty_path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "non-empty" });
    defer testing.allocator.free(non_empty_path);
    const user_note_path = try std.fs.path.join(testing.allocator, &.{ non_empty_path, "user-note.txt" });
    defer testing.allocator.free(user_note_path);

    // Create a directory that contains a user file. The contract:
    // deleteDirectoryIfEmpty must NOT remove the directory if a file
    // remains — that's how we preserve user-dropped files (.DS_Store,
    // README.md, screenshots, etc.) inside a deleted page folder.
    try std.Io.Dir.cwd().createDirPath(testing.io, non_empty_path);
    try design_io.atomicWriteFile(testing.allocator, user_note_path, "user file");

    // deleteDirectoryIfEmpty should refuse (DirNotEmpty) — protecting
    // the user's file from being swept away with the page.
    try testing.expectError(error.DirNotEmpty, design_io.deleteDirectoryIfEmpty(testing.allocator, non_empty_path));

    // The user's file MUST still exist.
    const stat_after = try tmp.dir.statFile(testing.io, "non-empty/user-note.txt", .{});
    try testing.expect(stat_after.kind == .file);
}
