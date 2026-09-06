const std = @import("std");
const builtin = @import("builtin");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for remove_file tool
pub const RemoveFileInput = struct {
    /// Absolute path to the file or directory to delete
    path: []const u8,
    /// If true, recursively delete directory and all contents inside
    recursive: bool = false,
};

/// Tool definition for remove_file
pub const remove_file_tool_system_prompt =
    \\## Remove File Tool — Behavior
    \\Use `remove_file` to delete a file or directory.
    \\- Set `recursive=true` to delete directories with contents. This cannot be undone.
    \\- Verify the path is correct before deleting.
    \\
;

pub const remove_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_file",
        .description = "Delete a file or directory from the filesystem. Use recursive=true to delete folders with all contents inside. Warning: This cannot be undone!",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file or directory to delete.",
                },
                .{
                    .name = "recursive",
                    .type = "boolean",
                    .description = "If true, recursively delete directory and all contents inside. Default: false.",
                },
            },
            .required = &.{ "path" },
        },
        .system_prompt = remove_file_tool_system_prompt,
    },
};

/// Windows NTSTATUS panic guard.
///
/// std's Threaded Io backend maps OBJECT_NAME_INVALID / INVALID_PARAMETER /
/// OBJECT_PATH_SYNTAX_BAD to ntstatusBug(), which PANICS and kills nalar.exe
/// (see Threaded.zig: dirAccessWindows + the delete path via NtCreateFile).
/// The LLM controls `input.path`, so every name must be validated BEFORE any
/// Dir.access / openDir / deleteTree / deleteFile call.
/// Returns an error message for invalid paths, null when safe for the OS.
fn invalidPathReason(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 32767) return "path too long";
    for (path) |c| {
        if (c == 0) return "path contains NUL byte";
        if (c < 0x20) return "path contains control character";
    }
    if (builtin.os.tag != .windows) return null;
    // Unix-style `/foo`, bare names, and drive-relative `C:foo` all reach
    // NtQueryAttributesFile as malformed NT names -> process panic.
    if (!std.fs.path.isAbsoluteWindows(path)) {
        return "path must be an absolute Windows path (e.g. C:\\dir\\file)";
    }
    // Extended-length prefix `\\?\` / `\\.\` skips Win32 normalization;
    // remember it so the drive-colon check below stays correct.
    var rest: []const u8 = path;
    if (rest.len > 4 and (std.mem.startsWith(u8, rest, "\\\\?\\") or std.mem.startsWith(u8, rest, "\\\\.\\"))) {
        rest = rest[4..];
    }
    // Wildcards / reserved chars are never valid in NT names.
    for (rest) |c| {
        switch (c) {
            '*', '?', '<', '>', '|', '"' => return "path contains invalid character",
            else => {},
        }
    }
    // Colon is only legal as a drive prefix (`X:`); anything else is an
    // ADS suffix (`file:stream`) or garbage -> OBJECT_NAME_INVALID.
    for (rest, 0..) |c, i| {
        if (c != ':') continue;
        const ok_drive = i == 1 and std.ascii.isAlphabetic(rest[0]);
        if (!ok_drive) return "path contains invalid character";
    }
    // UNC paths need at least `\\server\share`; a bare `\\server` is not a
    // complete name for the NT syscalls below.
    var body: []const u8 = rest;
    if (body.len >= 2 and isSep(body[0]) and isSep(body[1])) {
        body = body[2..];
        if (body.len == 0) return "incomplete UNC path";
        var segs: usize = 0;
        var k: usize = 0;
        var seg_start: usize = 0;
        while (k <= body.len) : (k += 1) {
            const at_end = k == body.len;
            if (!at_end and !isSep(body[k])) continue;
            if (k - seg_start > 0) segs += 1;
            seg_start = k + 1;
        }
        if (segs < 2) return "incomplete UNC path";
    }
    // Per-segment checks: no empty segments (`C:\foo\\bar`), no `..`
    // (root escape: `C:\foo\..` resolves to the drive root), no trailing
    // dots/spaces, no reserved device names (they open devices, not files).
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and !isSep(body[i])) continue;
        const seg = body[seg_start..i];
        const is_first = seg_start == 0;
        if (seg.len == 0) {
            // Only the leading rooted `\` separator and the trailing
            // separator (stripped by stripTrailingSeps before FS calls)
            // may be empty. (`\\` UNC lead was consumed above.)
            if (!is_first and !at_end) return "path contains empty segment";
        } else {
            if (std.mem.eql(u8, seg, "..")) return "path must not contain ..";
            if (at_end and std.mem.eql(u8, seg, ".")) return "path must not end with .";
            if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') {
                return "path segment ends with dot or space";
            }
            if (isReservedDosName(seg)) return "path uses reserved device name";
        }
        seg_start = i + 1;
    }
    return null;
}

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// DOS device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9), with or without
/// extension. As a path component they open a device via NtCreateFile —
/// never something the delete tool should touch.
fn isReservedDosName(seg: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, seg, '.')) |idx| seg[0..idx] else seg;
    if (stem.len < 3 or stem.len > 4) return false;
    // Drive prefix `C:` has no dot and len 2 — excluded by the length check.
    var upper: [4]u8 = undefined;
    for (stem, 0..) |c, k| upper[k] = std.ascii.toUpper(c);
    const s = upper[0..stem.len];
    if (std.mem.eql(u8, s, "CON") or std.mem.eql(u8, s, "PRN") or
        std.mem.eql(u8, s, "AUX") or std.mem.eql(u8, s, "NUL")) return true;
    if (s.len == 4 and (std.mem.eql(u8, s[0..3], "COM") or std.mem.eql(u8, s[0..3], "LPT")) and
        s[3] >= '1' and s[3] <= '9') return true;
    return false;
}

/// Strip trailing separators so `C:\foo\` never reaches NT as a
/// trailing-separator name. Never strips the root itself (`X:\`, `\\`, `\`).
fn stripTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    const floor: usize = floor: {
        if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSep(path[2])) break :floor 3;
        if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) break :floor 2;
        break :floor 1;
    };
    while (end > floor and isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

/// Refusing to delete a filesystem root (`C:\`, `\`, `\\server\share`) with
/// recursive=true would wipe the drive/share. Fail closed. Windows only;
/// call with the normalized (trailing-sep-stripped) path.
fn isWindowsRoot(norm_path: []const u8) bool {
    var rest: []const u8 = norm_path;
    if (rest.len > 4 and (std.mem.startsWith(u8, rest, "\\\\?\\") or std.mem.startsWith(u8, rest, "\\\\.\\"))) {
        rest = rest[4..];
    }
    // Drive root `X:\` / `X:/`, or current-drive root `\`.
    if (rest.len == 3 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':' and isSep(rest[2])) return true;
    if (rest.len == 1 and isSep(rest[0])) return true;
    // UNC share root `\\server\share` (exactly two non-empty components).
    if (norm_path.len >= 2 and isSep(norm_path[0]) and isSep(norm_path[1]) and
        !std.mem.startsWith(u8, norm_path, "\\\\?\\") and !std.mem.startsWith(u8, norm_path, "\\\\.\\"))
    {
        const body = norm_path[2..];
        var count: usize = 0;
        var k: usize = 0;
        var seg_start: usize = 0;
        while (k <= body.len) : (k += 1) {
            const at_end = k == body.len;
            if (!at_end and !isSep(body[k])) continue;
            if (k - seg_start > 0) {
                count += 1;
            } else {
                return false; // empty segment -> not a clean share root
            }
            seg_start = k + 1;
        }
        if (count == 2) return true;
    }
    return false;
}

/// Check if path is a directory.
/// Callers must validate via invalidPathReason() first: on Windows an
/// unchecked name panics inside openDir (OBJECT_NAME_INVALID -> ntstatusBug).
fn isDirectory(io : std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    return true;
}

/// Execute the remove_file tool - deletes a file or directory
/// Returns an XML string with result
pub fn executeRemoveFileToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: RemoveFileInput,
) ![]const u8 {
    if (input.path.len == 0) {
        return xmlError(allocator, "", "path cannot be empty");
    }

    // Panic guard: reject malformed NT names BEFORE any syscall.
    // (Windows Threaded backend turns them into ntstatusBug panics.)
    if (invalidPathReason(input.path)) |reason| {
        return xmlError(allocator, input.path, reason);
    }
    const norm_path = stripTrailingSeps(input.path);
    if (builtin.os.tag == .windows and isWindowsRoot(norm_path)) {
        return xmlError(allocator, input.path, "refusing to delete filesystem root");
    }

    const path_exists = blk: {
        std.Io.Dir.cwd().access(io, norm_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!path_exists) {
        return xmlError(allocator, input.path, "Path not found");
    }

    // Check if it's a directory by trying to open as dir
    const is_directory = isDirectory(io, norm_path);

    if (is_directory) {
        // It's a directory
        if (!input.recursive) {
            return xmlError(allocator, input.path, "Path is a directory. Use recursive=true to delete directories with contents.");
        }

        // Recursive delete using deleteTree
        std.Io.Dir.cwd().deleteTree(io, norm_path) catch {
            return xmlError(allocator, input.path, "Failed to delete directory");
        };

        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>true</deleted>
            \\<recursive>true</recursive>
        , .{input.path});
    }

    // It's a file - delete it
    std.Io.Dir.cwd().deleteFile(io, norm_path) catch {
        return xmlError(allocator, input.path, "Failed to delete file");
    };

    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>true</deleted>
    , .{input.path});
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, path: []const u8, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{ path, error_msg }) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}

/// Generate error XML response for parse failures (no path available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path></path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{error_msg}) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}

// --- Regression tests: malformed names must return error XML, never panic ---
// (Windows Threaded backend maps OBJECT_NAME_INVALID / INVALID_PARAMETER /
// OBJECT_PATH_SYNTAX_BAD to ntstatusBug -> process abort. The validator above
// is what stands between LLM input and that panic.)

test "remove_file validator rejects empty and NUL paths on all platforms" {
    try std.testing.expect(invalidPathReason("") != null);
    try std.testing.expect(invalidPathReason("a\x00b") != null);
    try std.testing.expect(invalidPathReason("a\x07b") != null);
}

test "remove_file validator accepts sane paths on all platforms" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(invalidPathReason("C:\\Users\\ginwa\\file.txt") == null);
        try std.testing.expect(invalidPathReason("C:/Users/ginwa/file.txt") == null);
        try std.testing.expect(invalidPathReason("\\\\server\\share\\file.txt") == null);
    } else {
        try std.testing.expect(invalidPathReason("/tmp/some-file.txt") == null);
        try std.testing.expect(invalidPathReason("relative/path.txt") == null);
    }
}

test "remove_file validator rejects Windows-malformed names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // NOTE: single-rooted `/unix/style/path` IS valid NT syntax (it resolves
    // against the current drive root and safely yields FileNotFound), so it
    // must NOT be rejected — only names that panic NtQueryAttributesFile are.
    try std.testing.expect(invalidPathReason("/unix/style/path") == null);
    // Bare names and drive-relative `C:foo` are not absolute.
    try std.testing.expect(invalidPathReason("relative\\path.txt") != null);
    try std.testing.expect(invalidPathReason("C:foo\\bar.txt") != null);
    // Wildcards / reserved chars -> OBJECT_NAME_INVALID.
    try std.testing.expect(invalidPathReason("C:\\foo*.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo?.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo<bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo|bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo\"bar.txt") != null);
    // ADS suffix / stray colon.
    try std.testing.expect(invalidPathReason("C:\\foo:stream") != null);
    // Empty segment, dot-dot escape, trailing dot/space, device names.
    try std.testing.expect(invalidPathReason("C:\\foo\\\\bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo\\..\\bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo.") != null);
    try std.testing.expect(invalidPathReason("C:\\foo ") != null);
    try std.testing.expect(invalidPathReason("C:\\NUL") != null);
    try std.testing.expect(invalidPathReason("C:\\dir\\COM1.txt") != null);
    // Incomplete UNC.
    try std.testing.expect(invalidPathReason("\\\\server") != null);
}

test "remove_file refuses filesystem roots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("C:\\")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("C:\\\\")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("\\\\server\\share")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("\\\\server\\share\\")));
    try std.testing.expect(!isWindowsRoot(stripTrailingSeps("C:\\Users")));
    try std.testing.expect(!isWindowsRoot(stripTrailingSeps("\\\\server\\share\\dir")));
}

test "remove_file stripTrailingSeps keeps roots intact" {
    try std.testing.expectEqualStrings("C:\\foo", stripTrailingSeps("C:\\foo\\"));
    try std.testing.expectEqualStrings("C:\\foo", stripTrailingSeps("C:\\foo///"));
    try std.testing.expectEqualStrings("C:\\", stripTrailingSeps("C:\\"));
    try std.testing.expectEqualStrings("/tmp/x", stripTrailingSeps("/tmp/x/"));
}

test "remove_file execute returns error XML on invalid path without touching FS" {
    // Empty path and validator/root rejections return before `io` is ever
    // used, so `undefined` is safe for those. Anything that passes validation
    // gets a real Io (Threaded) — the point is it must not panic.
    const bad_io: std.Io = undefined;
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const out = try executeRemoveFileToString(fba.allocator(), bad_io, .{ .path = "" });
    try std.testing.expect(std.mem.indexOf(u8, out, "<deleted>false</deleted>") != null);
    if (builtin.os.tag == .windows) {
        // Validator rejection (wildcard): never reaches the syscall.
        var buf1: [1024]u8 = undefined;
        var fba1 = std.heap.FixedBufferAllocator.init(&buf1);
        const out1 = try executeRemoveFileToString(fba1.allocator(), bad_io, .{ .path = "C:\\definitely\\missing\\*.txt" });
        try std.testing.expect(std.mem.indexOf(u8, out1, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out1, "invalid character") != null);

        // Root guard: never reaches the syscall.
        var buf3: [1024]u8 = undefined;
        var fba3 = std.heap.FixedBufferAllocator.init(&buf3);
        const out3 = try executeRemoveFileToString(fba3.allocator(), bad_io, .{ .path = "C:\\", .recursive = true });
        try std.testing.expect(std.mem.indexOf(u8, out3, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out3, "filesystem root") != null);

        // Valid NT syntax, missing on disk: goes through access() and must
        // come back as error XML (FileNotFound), NOT an ntstatusBug panic.
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var buf2: [1024]u8 = undefined;
        var fba2 = std.heap.FixedBufferAllocator.init(&buf2);
        const out2 = try executeRemoveFileToString(fba2.allocator(), io, .{ .path = "C:\\definitely\\missing\\nalar-test-file.txt" });
        try std.testing.expect(std.mem.indexOf(u8, out2, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out2, "Path not found") != null);
    }
}
