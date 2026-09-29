//! Static contract: every agent tool that hands a model-supplied path to
//! `std.fs` must validate it first.
//!
//! Why a source-scanning test rather than a behavioural one: the failure
//! this guards against is a MISSING CALL SITE. On Windows a malformed NT
//! name (`C:\foo*.txt`, `C:foo\bar`, `C:\foo:stream`, `relative\path`, a
//! reserved device name) makes std's Threaded Io backend call
//! `ntstatusBug()`, which panics and kills the process — so a behavioural
//! test can only observe it by crashing, and only on a Windows host. This
//! file is the Linux-runnable half: it fails the moment a tool stops
//! calling the validator, on any platform.
//!
//! The behavioural half is the validator's own table of cases, which live
//! with the tool that first needed it (remove_file.zig) and are now
//! registered for discovery.

const std = @import("std");
const testing = std.testing;

/// Every path-taking agent tool, with a symbol that only exists if its
/// entry point is still present.
///
/// ADD A TOOL HERE IN THE SAME COMMIT THAT ADDS ITS GUARD. The test below
/// is the thing that keeps this list honest: a new path-taking tool that
/// forgets the guard is invisible until someone adds it here — at which
/// point the list is one commit out of date. The scan below cannot detect
/// that automatically, so treat this table as the specification.
const guarded_tools = [_]struct {
    file: []const u8,
    entry_symbol: []const u8,
}{
    .{ .file = "read_file.zig", .entry_symbol = "pub fn readFile(" },
    .{ .file = "write_file.zig", .entry_symbol = "pub fn writeFile(" },
    .{ .file = "text_replace.zig", .entry_symbol = "pub fn executeTextReplace(" },
    .{ .file = "remove_file.zig", .entry_symbol = "invalidPathReason(input.path)" },
    .{ .file = "present_files.zig", .entry_symbol = "pub fn executePresentFilesToString(" },
    .{ .file = "glob.zig", .entry_symbol = "pub fn executeGlob(" },
};

/// Directory of the tools, relative to the project root.
///
/// A project-relative constant rather than `@src().file`, because the test
/// binary's cwd is the build root but `@src()`'s shape is not something to
/// depend on. `set_git_worktree_test.zig` already uses this convention for
/// the same reason.
const TOOL_DIR = "src/modules/agent/tools/";

fn readSibling(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ TOOL_DIR, name });
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        full,
        allocator,
        std.Io.Limit.limited(1024 * 1024),
    );
}

test "every path-taking agent tool validates its path before any std.fs call" {
    const allocator = testing.allocator;
    for (guarded_tools) |tool| {
        const src = try readSibling(allocator, tool.file);
        defer allocator.free(src);

        if (std.mem.indexOf(u8, src, tool.entry_symbol) == null) {
            std.debug.print("!! {s} no longer contains {s} — update guarded_tools\n", .{ tool.file, tool.entry_symbol });
            return error.EntryPointMoved;
        }

        if (std.mem.indexOf(u8, src, "invalidPathReason(") == null) {
            std.debug.print(
                "!! {s} does not call invalidPathReason. On Windows a malformed NT " ++
                    "name panics the process (std ntstatusBug), so this tool can take " ++
                    "the whole app down.\n",
                .{tool.file},
            );
            return error.MissingPathGuard;
        }

        // The validator must come from the shared helper. A private second
        // copy is how the drift started in the first place.
        if (std.mem.indexOf(u8, src, "path_validate.invalidPathReason") == null) {
            std.debug.print("!! {s} does not import the shared helpers.path_validate\n", .{tool.file});
            return error.NotShared;
        }
    }
}

test "the validator has exactly one implementation, in helpers/" {
    const own = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/helpers/path_validate.zig",
        testing.allocator,
        std.Io.Limit.limited(1024 * 1024),
    );
    defer testing.allocator.free(own);
    try testing.expect(std.mem.indexOf(u8, own, "pub fn invalidPathReason(") != null);

    // No TOOL may define its own. Call sites and aliases are fine and
    // expected; a second `fn invalidPathReason` definition is the drift.
    for (guarded_tools) |tool| {
        const src = try readSibling(testing.allocator, tool.file);
        defer testing.allocator.free(src);
        const redefines = std.mem.indexOf(u8, src, "fn invalidPathReason(") != null;
        if (redefines) {
            std.debug.print("!! {s} defines its own invalidPathReason — use helpers.path_validate\n", .{tool.file});
        }
        try testing.expect(!redefines);
    }
}
