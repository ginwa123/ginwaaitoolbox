// Stub test file - Chunk 3 fills this in.
const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/git_pr_create.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const HTTP_RESP_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

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

test "git_pr_create handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitPrCreateHandler") == null) {
        std.debug.print("!! mod.zig does not export gitPrCreateHandler !!\n", .{});
        return error.GitPrCreateExportMissing;
    }
    if (std.mem.indexOf(u8, source, "@import(\"git_pr_create.zig\")") == null) {
        std.debug.print("!! mod.zig does not @import git_pr_create.zig !!\n", .{});
        return error.GitPrCreateImportMissing;
    }
}

test "git_pr_create route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/pr") == null) {
        std.debug.print("!! main.zig does not register /api/git/pr !!\n", .{});
        return error.GitPrCreateRouteMissing;
    }
    if (std.mem.indexOf(u8, source, "gitPrCreateHandler") == null) {
        std.debug.print("!! main.zig does not reference gitPrCreateHandler !!\n", .{});
        return error.GitPrCreateHandlerRefMissing;
    }
}

test "http_response.zig defines GitPrCreateResponse struct + helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESP_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitPrCreateResponse") == null) {
        std.debug.print("!! http_response.zig does not define GitPrCreateResponse !!\n", .{});
        return error.GitPrCreateResponseTypeMissing;
    }
    if (std.mem.indexOf(u8, source, "makeGitPrCreateResponse") == null) {
        std.debug.print("!! http_response.zig does not define makeGitPrCreateResponse helper !!\n", .{});
        return error.GitPrCreateResponseHelperMissing;
    }
}

test "git_pr_create handler body has worktree_path, base, title, body fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "worktree_path: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'worktree_path' field !!\n", .{});
        return error.WorktreePathFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "base: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'base' field !!\n", .{});
        return error.BaseFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "title: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'title' field !!\n", .{});
        return error.TitleFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "body: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'body' field !!\n", .{});
        return error.BodyFieldMissing;
    }
}