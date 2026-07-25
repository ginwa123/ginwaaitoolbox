//! Comprehensive test suite for write_file tool — covers the simple happy
//! path AND the edge cases (empty content, unicode, binary, large files,
//! truncation semantics, path traversal, parent-dir creation, XML
//! serialization, schema contract, memory ownership).
//!
//! TDD ordering: this file was written first; any failing tests signal
//! implementation gaps or document known behaviors.

const std = @import("std");
const write_file = @import("write_file.zig");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn deleteFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
}

fn deleteDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteDir(testing.io, path) catch {};
}

// Best-effort cleanup for a test's full directory tree. Deletes the
// leaf file, then each parent directory in DEEPEST-FIRST order so each
// rmdir sees an empty directory.
//
// Why no `openDir().iterate()` walk: the Zig 0.16 Io runtime is flaky
// when iterating from the cwd Dir handle after a createDir/createDirPath
// syscall (it can return BADF). Since the test is the SOLE creator of
// the tree, we can hardcode the parent list at comptime and avoid the
// iteration. All errors are swallowed — the goal is "leave no residue",
// not "assert cleanup succeeded".
fn deleteTestTree(comptime parents_deep_first: []const []const u8, leaf_file: []const u8) void {
    deleteFile(leaf_file);
    inline for (parents_deep_first) |dir| {
        deleteDir(dir);
    }
}

/// Read back a file's full contents into a freshly allocated slice.
/// Limit is 4 MiB so tests that write up to 1 MiB (e.g. the large-content
/// test) can read back the full content without hitting StreamTooLong.
fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(4 << 20));
}

/// Return the on-disk size of a file (0 if missing).
fn fileSize(path: []const u8) u64 {
    var f = std.Io.Dir.cwd().openFile(testing.io, path, .{}) catch return 0;
    defer f.close(testing.io);
    return std.Io.File.length(f, testing.io) catch 0;
}

// ===========================================================================
// Section 1: Happy path (sanity baseline)
// ===========================================================================

test "writeFile - writes ASCII content to a new file in cwd" {
    const path = "test_wf_basic.txt";
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "Hello, World!",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("Hello, World!", read);
}

test "writeFile - file on disk has exact size equal to content length" {
    const path = "test_wf_size.txt";
    defer deleteFile(path);

    const content = "0123456789";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, content.len), fileSize(path));
}

test "writeFile - overwrites existing file (truncates)" {
    const path = "test_wf_overwrite.txt";
    defer deleteFile(path);

    // First write: 50 bytes of 'A'
    var first_buf: [50]u8 = undefined;
    for (&first_buf) |*b| b.* = 'A';
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = &first_buf,
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 50), fileSize(path));

    // Second write: 5 bytes of 'B' — must truncate the old content
    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "BBBBB",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 5), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("BBBBB", read);
}

test "writeFile - overwrites with larger content (extends)" {
    const path = "test_wf_extend.txt";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "small",
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 5), fileSize(path));

    const bigger = "this is a much longer string than before";
    var _wf_r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = bigger,
    });
    defer _wf_r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, bigger.len), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(bigger, read);
}

test "writeFile - writing same path twice leaves only the second contents" {
    const path = "test_wf_idempotent.txt";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "first version",
    });
    defer _wf_r.deinit(testing.allocator);
    var r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "second version wins",
    });
    defer r2.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("second version wins", read);
}

// ===========================================================================
// Section 2: create_with_dir = true (proactive parent-dir creation)
// ===========================================================================

test "writeFile - create_with_dir=true creates missing parent directory" {
    const dir = "test_wf_create_dir_parent";
    const path = "test_wf_create_dir_parent/inner.txt";
    defer {
        deleteFile(path);
        std.Io.Dir.cwd().deleteDir(testing.io, dir) catch {};
    }

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "in a fresh dir",
        .create_with_dir = true,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("in a fresh dir", read);
}

test "writeFile - create_with_dir=true creates deeply nested parent dirs" {
    const path = "test_wf_deeply_nested/a/b/c/deep.txt";
    defer deleteTestTree(&.{
        "test_wf_deeply_nested/a/b/c",
        "test_wf_deeply_nested/a/b",
        "test_wf_deeply_nested/a",
        "test_wf_deeply_nested",
    }, path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "deep content",
        .create_with_dir = true,
    });
    defer result.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("deep content", read);
}

test "writeFile - create_with_dir=true on existing parent dir is a no-op (idempotent)" {
    const path = "test_wf_existing_parent/file.txt";
    defer {
        deleteFile(path);
        std.Io.Dir.cwd().deleteDir(testing.io, "test_wf_existing_parent") catch {};
    }

    // Create the parent dir first
    try std.Io.Dir.cwd().createDir(testing.io, "test_wf_existing_parent", .default_dir);

    // Now write — create_with_dir=true must succeed without erroring on the
    // already-existing parent (createDirPath is idempotent on POSIX).
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "into existing parent",
        .create_with_dir = true,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("into existing parent", read);
}

// ===========================================================================
// Section 3: create_with_dir = false (the FileNotFound fallback branch)
// ===========================================================================

test "writeFile - create_with_dir=false auto-creates parent on FileNotFound fallback" {
    const path = "test_wf_fallback/inner.txt";
    defer {
        deleteFile(path);
        std.Io.Dir.cwd().deleteDir(testing.io, "test_wf_fallback") catch {};
    }

    // create_with_dir defaults to false → the function should still
    // succeed by hitting the FileNotFound catch-all path which calls
    // createDirPath and re-creates the file.
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "fallback worked",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("fallback worked", read);
}

test "writeFile - create_with_dir=false auto-creates deeply nested missing parents" {
    const path = "test_wf_fallback_deep/x/y/z/deep.txt";
    defer deleteTestTree(&.{
        "test_wf_fallback_deep/x/y/z",
        "test_wf_fallback_deep/x/y",
        "test_wf_fallback_deep/x",
        "test_wf_fallback_deep",
    }, path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "fallback deep",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("fallback deep", read);
}

// ===========================================================================
// Section 4: Empty content
// ===========================================================================

test "writeFile - empty content produces a zero-byte file" {
    const path = "test_wf_empty.txt";
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);
    try testing.expectEqual(@as(u64, 0), fileSize(path));
}

test "writeFile - overwriting with empty content truncates to zero bytes" {
    const path = "test_wf_empties_old.txt";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "this content will be wiped",
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 26), fileSize(path));  // "this content will be wiped" = 26 chars

    var _wf_r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "",
    });
    defer _wf_r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), fileSize(path));
}

// ===========================================================================
// Section 5: Content shape edge cases
// ===========================================================================

test "writeFile - multibyte UTF-8 content preserved byte-for-byte" {
    const path = "test_wf_unicode.txt";
    defer deleteFile(path);

    // 2-byte (é), 3-byte (中), 4-byte (🚀) UTF-8 sequences
    const content = "café 中文 🚀 émoji";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
    try testing.expectEqual(@as(u64, content.len), fileSize(path));
}

test "writeFile - binary content with NUL bytes preserved" {
    const path = "test_wf_binary.bin";
    defer deleteFile(path);

    // Content with NUL bytes, control chars, and other binary noise
    const content = "\x00\x01\x02hello\x00world\xFF\xFE\xFD";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, content.len), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
}

test "writeFile - content with all printable ASCII whitespace preserved" {
    const path = "test_wf_whitespace.txt";
    defer deleteFile(path);

    const content = "tab\there\nnewline\r\ncrlf\ttab2   spaces";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
}

test "writeFile - content containing XML special chars preserved in file" {
    const path = "test_wf_xml_chars.txt";
    defer deleteFile(path);

    // The file on disk stores RAW bytes — escaping only happens in toXmlSuccess.
    const content = "<tag attr=\"value\">&entity;'apos'</tag>";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
}

test "writeFile - single-byte content" {
    const path = "test_wf_single_byte.txt";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "x",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 1), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("x", read);
}

test "writeFile - large content (1 MiB) written completely" {
    const path = "test_wf_large.bin";
    defer deleteFile(path);

    // Allocate a 1 MiB buffer of 'A' bytes
    const size: usize = 1 << 20; // 1 MiB
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    @memset(content, 'A');

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqual(@as(usize, size), read.len);
    // Spot-check first/last bytes
    try testing.expectEqual(@as(u8, 'A'), read[0]);
    try testing.expectEqual(@as(u8, 'A'), read[read.len - 1]);
    // Spot-check middle
    try testing.expectEqual(@as(u8, 'A'), read[size / 2]);
}

// ===========================================================================
// Section 6: Path shape edge cases
// ===========================================================================

test "writeFile - path with no slash (file in cwd) works" {
    const path = "test_wf_no_slash.txt";
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "no slash here",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("no slash here", read);
}

test "writeFile - single-character filename works" {
    const path = "x";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "tiny name",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("tiny name", read);
}

test "writeFile - dotfile (hidden file) works" {
    const path = ".test_wf_hidden";
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "hidden content",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("hidden content", read);
}

test "writeFile - path with directory containing spaces" {
    const path = "test_wf dir with spaces/file.txt";
    defer {
        deleteFile(path);
        deleteDir("test_wf dir with spaces");
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "spaces work too",
        .create_with_dir = true,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("spaces work too", read);
}

test "writeFile - path with .. segments resolves relative to cwd" {
    // Writing through `..` should work — the OS resolves the path normally.
    // The cwd at test time is the project root, so this writes into a
    // sibling test dir we control and cleans up.
    const dir = "test_wf_dotdot_target";
    const path = "test_wf_dotdot_target/../test_wf_dotdot_target/inside.txt";
    defer {
        deleteFile("test_wf_dotdot_target/inside.txt");
        deleteDir("test_wf_dotdot_target");
    }

    std.Io.Dir.cwd().createDir(testing.io, dir, .default_dir) catch {};  // idempotent

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "via dotdot",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, "test_wf_dotdot_target/inside.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("via dotdot", read);
}

test "writeFile - filename at POSIX max length (255 chars) succeeds" {
    // Build a 255-char filename
    var name_buf: [255]u8 = undefined;
    for (&name_buf, 0..) |*b, i| b.* = if (i < 250) 'a' else if (i == 250) '.' else 'x';
    const path = &name_buf;
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "long name",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), fileSize(path));
}

// ===========================================================================
// Section 7: WriteFileResult ownership + deinit
// ===========================================================================

test "writeFileResult.deinit frees the path (no leak)" {
    const path = "test_wf_deinit.txt";
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "deinit me",
    });

    // Capture the path's pointer before deinit so we can verify it's
    // been freed afterwards. After deinit, reading from that pointer
    // would be use-after-free — we can't safely assert anything here
    // other than that deinit() doesn't crash.
    result.deinit(testing.allocator);
}

test "writeFileResult.path is heap-allocated (independent of input.slice)" {
    // The returned path must be a fresh allocation (not aliased to the
    // caller's input slice) — otherwise freeing one would corrupt the other.
    const path = "test_wf_path_alloc.txt";
    defer deleteFile(path);

    const result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "owned path",
    });
    defer result.deinit(testing.allocator);

    // The two pointers must differ
    try testing.expect(result.path.ptr != path.ptr);
    try testing.expectEqualStrings(path, result.path);
    try testing.expectEqual(@as(usize, path.len), result.path.len);
}

test "writeFileResult.path has same bytes as input path" {
    const path = "test_wf_path_bytes.txt";
    defer deleteFile(path);

    const result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "x",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, path, result.path);
}

// ===========================================================================
// Section 8: toXmlSuccess
// ===========================================================================

test "toXmlSuccess contains <success>true</success>" {
    const wf_path = try testing.allocator.dupe(u8, "/x");
    defer testing.allocator.free(wf_path);
    const xml = write_file.toXmlSuccess(testing.allocator, .{ .path = wf_path });
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<success>true</success>") != null);
}

test "toXmlSuccess includes the file_write path" {
    const wf_path = try testing.allocator.dupe(u8, "/abs/path/to/file.txt");
    defer testing.allocator.free(wf_path);
    const xml = write_file.toXmlSuccess(testing.allocator, .{ .path = wf_path });
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<file_write>/abs/path/to/file.txt</file_write>") != null);
}

test "toXmlSuccess emits well-formed XML (open+close tags match)" {
    const wf_path = try testing.allocator.dupe(u8, "/x/y/z.txt");
    defer testing.allocator.free(wf_path);
    const xml = write_file.toXmlSuccess(testing.allocator, .{ .path = wf_path });
    defer testing.allocator.free(xml);

    // Exactly one <success> open + one </success> close
    var open_count: usize = 0;
    var close_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, xml, idx, "<success>")) |p| {
        open_count += 1;
        idx = p + "<success>".len;
    }
    idx = 0;
    while (std.mem.indexOfPos(u8, xml, idx, "</success>")) |p| {
        close_count += 1;
        idx = p + "</success>".len;
    }
    try testing.expectEqual(@as(usize, 1), open_count);
    try testing.expectEqual(@as(usize, 1), close_count);

    var fw_open: usize = 0;
    var fw_close: usize = 0;
    idx = 0;
    while (std.mem.indexOfPos(u8, xml, idx, "<file_write>")) |p| {
        fw_open += 1;
        idx = p + "<file_write>".len;
    }
    idx = 0;
    while (std.mem.indexOfPos(u8, xml, idx, "</file_write>")) |p| {
        fw_close += 1;
        idx = p + "</file_write>".len;
    }
    try testing.expectEqual(@as(usize, 1), fw_open);
    try testing.expectEqual(@as(usize, 1), fw_close);
}

// ===========================================================================
// Section 9: toXmlError
// ===========================================================================

test "toXmlError for PathNotFound contains descriptive message" {
    const xml = write_file.toXmlError(
        testing.allocator,
        error.PathNotFound,
        "/abs/missing/file.txt",
    );
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file_write>/abs/missing/file.txt</file_write>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</error>") != null);
    // The PathNotFound message names "Directory" and "parent directory"
    try testing.expect(std.mem.indexOf(u8, xml, "Directory") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "parent directory") != null);
}

test "toXmlError for InputOutput contains permission-related message" {
    const xml = write_file.toXmlError(
        testing.allocator,
        error.InputOutput,
        "/readonly/file.txt",
    );
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "permission") != null or
        std.mem.indexOf(u8, xml, "Permission") != null or
        std.mem.indexOf(u8, xml, "write permissions") != null);
}

test "toXmlError for generic error uses Unexpected error fallback" {
    const xml = write_file.toXmlError(
        testing.allocator,
        error.AccessDenied,
        "/some/path",
    );
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "AccessDenied") != null or
        std.mem.indexOf(u8, xml, "Unexpected") != null);
}

test "toXmlError path is rendered as-is in the XML body" {
    const xml = write_file.toXmlError(
        testing.allocator,
        error.PathNotFound,
        "/x/y/z.txt",
    );
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<file_write>/x/y/z.txt</file_write>") != null);
}

test "toXmlError wraps an empty path without crashing" {
    const xml = write_file.toXmlError(testing.allocator, error.PathNotFound, "");
    defer testing.allocator.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<file_write></file_write>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
}

// ===========================================================================
// Section 10: Tool schema contract
// ===========================================================================

test "write_file_tool - type is function" {
    try testing.expectEqualStrings("function", write_file.write_file_tool.type);
}

test "write_file_tool - function name is 'write_file'" {
    try testing.expectEqualStrings("write_file", write_file.write_file_tool.function.name);
}

test "write_file_tool - parameters require 'path' and 'content'" {
    const params = write_file.write_file_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);

    var found_path = false;
    var found_content = false;
    for (params.required) |req| {
        if (std.mem.eql(u8, req, "path")) found_path = true;
        if (std.mem.eql(u8, req, "content")) found_content = true;
    }
    try testing.expect(found_path);
    try testing.expect(found_content);
}

test "write_file_tool - declares path, content, create_with_dir properties" {
    const params = write_file.write_file_tool.function.parameters;

    var found_path = false;
    var found_content = false;
    var found_create_with_dir = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) {
            found_path = true;
            try testing.expectEqualStrings("string", prop.type);
        }
        if (std.mem.eql(u8, prop.name, "content")) {
            found_content = true;
            try testing.expectEqualStrings("string", prop.type);
        }
        if (std.mem.eql(u8, prop.name, "create_with_dir")) {
            found_create_with_dir = true;
            try testing.expectEqualStrings("boolean", prop.type);
        }
    }
    try testing.expect(found_path);
    try testing.expect(found_content);
    try testing.expect(found_create_with_dir);
}

test "write_file_tool - description mentions text_replace as the partial-edit alternative" {
    const desc = write_file.write_file_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "text_replace") != null);
}

test "write_file_tool - description mentions create_with_dir semantics" {
    const desc = write_file.write_file_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "create_with_dir") != null or
        std.mem.indexOf(u8, desc, "parent directories") != null);
}

test "write_file_tool - create_with_dir is NOT required (has default false)" {
    const params = write_file.write_file_tool.function.parameters;
    for (params.required) |req| {
        try testing.expect(!std.mem.eql(u8, req, "create_with_dir"));
    }
}

// ===========================================================================
// Section 11: WriteFileInput defaults
// ===========================================================================

test "WriteFileInput.create_with_dir defaults to false" {
    const input: write_file.WriteFileInput = .{
        .path = "/x",
        .content = "y",
    };
    try testing.expectEqual(false, input.create_with_dir);
}

// ===========================================================================
// Section 12: Realistic shape — repeated writes to the same dir
// ===========================================================================

test "writeFile - 5 sequential writes to files in same dir all succeed" {
    const dir = "test_wf_many_files";
    defer {
        for ([_][]const u8{ "f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt" }) |name| {
            const full = std.fs.path.join(testing.allocator, &.{ dir, name }) catch continue;
            defer testing.allocator.free(full);
            deleteFile(full);
        }
        deleteDir(dir);
    }

    const names_buf: [5][]const u8 = .{ "f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt" };
    for (names_buf, 0..) |name, i| {
        const path_owned = try std.fs.path.join(testing.allocator, &.{ dir, name });
        defer testing.allocator.free(path_owned);
        const content_owned = try std.fmt.allocPrint(testing.allocator, "file {d}", .{i});
        defer testing.allocator.free(content_owned);
        var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path_owned,
            .content = content_owned,
            .create_with_dir = true,
        });
        defer _wf_r.deinit(testing.allocator);
    }

    // Verify each file exists with the right contents
    for (names_buf, 0..) |name, i| {
        const full = try std.fs.path.join(testing.allocator, &.{ dir, name });
        defer testing.allocator.free(full);
        const read = try readFileContents(testing.allocator, full);
        defer testing.allocator.free(read);
        var expected_buf: [16]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "file {d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(expected, read);
    }
}

// ===========================================================================
// Section 13: Stress / concurrency-shape (single-threaded but many ops)
// ===========================================================================

test "writeFile - 20 alternating-size overwrites all leave correct final state" {
    const path = "test_wf_stress.bin";
    defer deleteFile(path);

    // Pattern: write 100-byte block, then 1000-byte block, alternating.
    // The file size should track the LAST write in the pattern.
    var small: [100]u8 = undefined;
    var large: [1000]u8 = undefined;
    @memset(&small, 's');
    @memset(&large, 'L');

    var last_was_large = false;
    for (0..20) |_| {
        const content: []const u8 = if (last_was_large) &small else &large;
        var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path,
            .content = content,
        });
    defer _wf_r.deinit(testing.allocator);
        last_was_large = !last_was_large;
    }

    // After 20 iterations starting with `false` (writes 100-byte first),
    // the last iteration writes `small` (since even iterations are small).
    try testing.expectEqual(@as(u64, 100), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, &small, read);
}

// ===========================================================================
// Section 14: Returned result independent across calls
// ===========================================================================

test "writeFile - two consecutive calls return independent path allocations" {
    const path_a = "test_wf_indep_a.txt";
    const path_b = "test_wf_indep_b.txt";
    defer {
        deleteFile(path_a);
        deleteFile(path_b);
    }

    var r1 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path_a,
        .content = "aaa",
    });
    var r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path_b,
        .content = "bbb",
    });

    // Independent heap allocations
    try testing.expect(r1.path.ptr != r2.path.ptr);
    try testing.expectEqualStrings(path_a, r1.path);
    try testing.expectEqualStrings(path_b, r2.path);

    // Freeing one must not corrupt the other
    r1.deinit(testing.allocator);
    try testing.expectEqualStrings(path_b, r2.path);
    r2.deinit(testing.allocator);
}