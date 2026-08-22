const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/git_worktree_info.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const HTTP_RESP_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

/// Read a source file from disk, relative to the project root. Mirrors the
/// pattern from `set_git_worktree_test.zig` — the project doesn't have a
/// behavioral handler-test infrastructure, so we static-grep for required
/// substrings.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Static wiring tests ───────────────────────────────────────────────────

test "git_worktree_info handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitWorktreeInfoHandler") == null) {
        std.debug.print("!! mod.zig does not export gitWorktreeInfoHandler !!\n", .{});
        return error.GitWorktreeInfoExportMissing;
    }
    if (std.mem.indexOf(u8, source, "@import(\"git_worktree_info.zig\")") == null) {
        std.debug.print("!! mod.zig does not @import git_worktree_info.zig !!\n", .{});
        return error.GitWorktreeInfoImportMissing;
    }
}

test "git_worktree_info route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/worktree/info") == null) {
        std.debug.print("!! main.zig does not register /api/git/worktree/info !!\n", .{});
        return error.GitWorktreeInfoRouteMissing;
    }
    if (std.mem.indexOf(u8, source, "gitWorktreeInfoHandler") == null) {
        std.debug.print("!! main.zig does not reference gitWorktreeInfoHandler !!\n", .{});
        return error.GitWorktreeInfoHandlerRefMissing;
    }
}

test "http_response.zig defines GitWorktreeInfoResponse struct + helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESP_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitWorktreeInfoResponse") == null) {
        std.debug.print("!! http_response.zig does not define GitWorktreeInfoResponse !!\n", .{});
        return error.GitWorktreeInfoResponseTypeMissing;
    }
    if (std.mem.indexOf(u8, source, "makeGitWorktreeInfoResponse") == null) {
        std.debug.print("!! http_response.zig does not define makeGitWorktreeInfoResponse helper !!\n", .{});
        return error.GitWorktreeInfoResponseHelperMissing;
    }
}

test "git_worktree_info handler accepts optional ?base= query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    // The handler must read ?base=<branch> and forward it to the
    // diff/ahead computations (design decision #12). The static check
    // verifies the handler at least reads the `base` query param.
    if (std.mem.indexOf(u8, source, "req.query.get(\"base\")") == null) {
        std.debug.print("!! git_worktree_info.zig does not read ?base= query param !!\n", .{});
        return error.GitWorktreeInfoBaseParamMissing;
    }
}

test "git_worktree_info handler probes origin/main + origin/master + origin/develop" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    // Auto-detection requires probing all three default base branches.
    // Static check ensures the handler enumerates them.
    if (std.mem.indexOf(u8, source, "origin/main") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/main !!\n", .{});
        return error.OriginMainProbeMissing;
    }
    if (std.mem.indexOf(u8, source, "origin/master") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/master !!\n", .{});
        return error.OriginMasterProbeMissing;
    }
    if (std.mem.indexOf(u8, source, "origin/develop") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/develop !!\n", .{});
        return error.OriginDevelopProbeMissing;
    }
}

test "test_runner.zig registers git_worktree_info_test.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/test_runner.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "@import(\"http_handlers/git_worktree_info_test.zig\")") == null) {
        std.debug.print("!! test_runner.zig does not import git_worktree_info_test.zig !!\n", .{});
        return error.GitWorktreeInfoTestRegistrationMissing;
    }
}