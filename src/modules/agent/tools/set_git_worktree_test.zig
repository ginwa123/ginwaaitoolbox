const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;
const swt = @import("set_git_worktree.zig");

const TOOL_PATH = "src/modules/agent/tools/set_git_worktree.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

// ─── Static source-check tests ────────────────────────────────────────────

test "set_git_worktree tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! set_git_worktree.zig does not define the tool with .name = \"set_git_worktree\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_git_worktree tool description mentions absolute path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "absolute path") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention 'absolute path' !!\n", .{});
        return error.AbsolutePathMissing;
    }
}

test "set_git_worktree input struct has path + clear + branch fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "path: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'path' field !!\n", .{});
        return error.PathFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "clear: bool") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'clear' field !!\n", .{});
        return error.ClearFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "branch: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'branch' field !!\n", .{});
        return error.BranchFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "base: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'base' field !!\n", .{});
        return error.BaseFieldMissing;
    }
}

test "xmlError for add failure surfaces git stderr, not a generic literal" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Regression: the previous line was
    //     return xmlError(allocator, session_id, "git worktree add failed");
    // which left the user with zero info about WHY git refused (path
    // already exists? not a git repo? bad branch name?). The fix
    // surfaces the captured git stderr (e.g. "fatal: '/foo' already exists")
    // via runGitWorktreeAdd's new ![]u8 return type. This test guards
    // against the generic literal coming back.
    //
    // We look for the specific xmlError call pattern (not just the bare
    // phrase) so the test does not false-positive on docstring mentions
    // of the old behavior.
    if (std.mem.indexOf(u8, source, "xmlError(allocator, session_id, \"git worktree add failed\")") != null) {
        std.debug.print("!! set_git_worktree.zig still calls xmlError(..., \"git worktree add failed\") — surface git's captured stderr instead !!\n", .{});
        return error.GenericGitWorktreeAddErrorLiteralPresent;
    }
}

test "runGitWorktreeAdd returns captured stderr on failure" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The new contract: runGitWorktreeAdd returns ![]u8 — empty string
    // on success, captured stderr (or descriptive fallback) on failure.
    // The caller uses the returned string as the XML error detail.
    // Check that the function signature includes the ![]u8 return type
    // and that the caller binds the result to a `git_detail` variable.
    if (std.mem.indexOf(u8, source, "fn runGitWorktreeAdd(") == null) {
        std.debug.print("!! runGitWorktreeAdd function is missing !!\n", .{});
        return error.RunGitWorktreeAddMissing;
    }
    if (std.mem.indexOf(u8, source, "const git_detail = runGitWorktreeAdd(") == null) {
        std.debug.print("!! caller of runGitWorktreeAdd does not bind the result to a 'git_detail' variable !!\n", .{});
        return error.GitDetailBindingMissing;
    }
    if (std.mem.indexOf(u8, source, "if (git_detail.len > 0)") == null) {
        std.debug.print("!! caller of runGitWorktreeAdd does not check git_detail.len > 0 to surface stderr !!\n", .{});
        return error.GitDetailCheckMissing;
    }
}

// ─── Behavioral tests for validatePath ────────────────────────────────────

test "validatePath accepts valid absolute paths" {
    const valid_paths = [_][]const u8{
        "/home/me/proj/.worktrees/auth-fix",
        "/tmp/experiments/rpc-rewrite",
        "/a/b/c",
        "/x",
    };
    for (valid_paths) |p| {
        try testing.expect(swt.validatePath(p) == null);
    }
}

test "validatePath rejects empty path" {
    try testing.expect(swt.validatePath("") != null);
}

test "validatePath rejects relative path" {
    try testing.expect(swt.validatePath("foo/bar") != null);
}

test "validatePath rejects path with .." {
    try testing.expect(swt.validatePath("/home/me/../etc/passwd") != null);
}

test "validatePath rejects null byte" {
    try testing.expect(swt.validatePath("/foo\x00bar") != null);
}

test "validatePath rejects too-long path" {
    var long_path: [5000]u8 = undefined;
    @memset(long_path[0..], '/');
    long_path[0] = '/';
    for (1..5000) |i| long_path[i] = 'a';
    try testing.expect(swt.validatePath(long_path[0..]) != null);
}

test "validatePath rejects illegal basename" {
    const bad_paths = [_][]const u8{
        "/foo/hello world",
        "/foo/bad!char",
        "/foo/.",
        "/foo/..",
    };
    for (bad_paths) |p| {
        try testing.expect(swt.validatePath(p) != null);
    }
}

// ─── Behavioral tests for validateBasename ────────────────────────────────

test "validateBasename accepts legal names" {
    const ok = [_][]const u8{ "auth-fix", "v2", "x", "a..b" };
    for (ok) |n| {
        try testing.expect(swt.validateBasename(n) == null);
    }
}

test "validateBasename rejects illegal names" {
    const bad = [_][]const u8{ "hello world", "a/b", ".", ".." };
    for (bad) |n| {
        try testing.expect(swt.validateBasename(n) != null);
    }
}

// ─── Behavioral tests for deriveBranchFromPath ────────────────────────────

test "deriveBranchFromPath returns worktree/<basename>" {
    const allocator = testing.allocator;

    const b1 = try swt.deriveBranchFromPath(allocator, "/abs/.worktrees/auth-fix");
    defer allocator.free(b1);
    try testing.expectEqualStrings("worktree/auth-fix", b1);

    const b2 = try swt.deriveBranchFromPath(allocator, "/tmp/foo");
    defer allocator.free(b2);
    try testing.expectEqualStrings("worktree/foo", b2);

    const b3 = try swt.deriveBranchFromPath(allocator, "/Users/me/proj/.worktrees/fix-bug-123");
    defer allocator.free(b3);
    try testing.expectEqualStrings("worktree/fix-bug-123", b3);
}

// ─── Static wiring tests (Chunk 3) ───────────────────────────────────────

const TOOL_REGISTRY_PATH = "src/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/agentic_loop/tools_exec_set_git_worktree.zig`
/// (re-exported as `agentic_loop_mod.tools.execSetGitWorktree`).
const TOOL_EXEC_PATH = "src/agentic_loop/tools_exec_set_git_worktree.zig";
/// The cwd_override field moved with the rest of ToolExecContext to
/// `src/agentic_loop/tools.zig`. This is the new
/// canonical home of the struct declaration.
const TOOL_EXEC_CONTEXT_PATH = "src/agentic_loop/tools.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/agentic_loop/tools_equipped.zig";

test "tools_equipped.zig imports set_git_worktree module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "const set_git_worktree_mod = nalarcore.set_git_worktree;") == null) {
        std.debug.print("!! tools_equipped.zig does not bind set_git_worktree_mod = nalarcore.set_git_worktree !!\n", .{});
        return error.SetGitWorktreeModBindingMissing;
    }
}

test "agentic_loop defines execSetGitWorktree" {
    // After the migration, the exec function lives in
    // `tools_exec_set_git_worktree.zig` (re-exported via
    // `agentic_loop_mod.tools.execSetGitWorktree`). The DB
    // persistence call (`updateSessionGitWorktreeCwd`) moved with it.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn execSetGitWorktree(") == null) {
        std.debug.print("!! tools_exec_set_git_worktree.zig does not define pub fn execSetGitWorktree !!\n", .{});
        return error.ExecSetGitWorktreeMissing;
    }
    if (std.mem.indexOf(u8, source, "updateSessionGitWorktreeCwd") == null) {
        std.debug.print("!! execSetGitWorktree does not call updateSessionGitWorktreeCwd for DB persistence !!\n", .{});
        return error.PersistenceCallMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_git_worktree entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execSetGitWorktree` (NOT `agentic_loop_mod.tools.execSetGitWorktree`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    // The registry entry should be a struct literal that wires the
    // exec function and the tool definition together.
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_git_worktree name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (std.mem.indexOf(u8, source, ".exec = tools.execSetGitWorktree") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execSetGitWorktree !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (std.mem.indexOf(u8, source, ".tool_def = set_git_worktree_mod.set_git_worktree_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_git_worktree tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "set_git_worktree_mod.set_git_worktree_tool,") == null) {
        std.debug.print("!! tools_equipped.zig comptime list is missing set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "ToolExecContext has cwd_override field (Plan B forward-compat)" {
    // After migration, the canonical ToolExecContext struct lives in
    // `agentic_loop/tools.zig` (re-exported from tool_registry.zig).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_CONTEXT_PATH);
    defer allocator.free(source);
    // Plan B (conservative) for the CWD override: add the field as
    // future-proofing. Mutating it from a tool exec is currently
    // dead-letter (ToolExecContext is passed by value), but the field
    // is required to be present so a follow-up plan can opt exec
    // functions in to read it.
    if (std.mem.indexOf(u8, source, "cwd_override: ?[]const u8 = null") == null) {
        std.debug.print("!! ToolExecContext is missing the cwd_override field !!\n", .{});
        return error.CwdOverrideFieldMissing;
    }
}

// ─── Chunk 1 helpers: classifyPath / runGitWorktreeList ───────────────

test "set_git_worktree.zig defines PathState tagged union" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const PathState = union(enum) {") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub const PathState = union(enum)' !!\n", .{});
        return error.PathStateMissing;
    }
    if (std.mem.indexOf(u8, source, "not_found,") == null) {
        std.debug.print("!! PathState is missing the 'not_found' variant !!\n", .{});
        return error.PathStateNotFoundMissing;
    }
    if (std.mem.indexOf(u8, source, "plain_directory:") == null) {
        std.debug.print("!! PathState is missing the 'plain_directory' variant !!\n", .{});
        return error.PathStatePlainDirectoryMissing;
    }
    if (std.mem.indexOf(u8, source, "orphaned_worktree:") == null) {
        std.debug.print("!! PathState is missing the 'orphaned_worktree' variant !!\n", .{});
        return error.PathStateOrphanedWorktreeMissing;
    }
    if (std.mem.indexOf(u8, source, "registered_worktree: RegisteredWorktree") == null) {
        std.debug.print("!! PathState is missing the 'registered_worktree' variant !!\n", .{});
        return error.PathStateRegisteredWorktreeMissing;
    }
}

test "set_git_worktree.zig defines classifyPath function" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn classifyPath(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn classifyPath' !!\n", .{});
        return error.ClassifyPathMissing;
    }
    // Must take the 4 documented args: allocator, io, repo_root, target.
    if (std.mem.indexOf(u8, source, "pub fn classifyPath(\n    allocator: std.mem.Allocator,\n    io: std.Io,\n    repo_root: []const u8,\n    target: []const u8,\n) !PathState {") == null) {
        std.debug.print("!! classifyPath signature does not match the documented 4-arg form !!\n", .{});
        return error.ClassifyPathSignatureMismatch;
    }
}

test "set_git_worktree.zig defines runGitWorktreeList (private)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "fn runGitWorktreeList(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'fn runGitWorktreeList' !!\n", .{});
        return error.RunGitWorktreeListMissing;
    }
    // Must use --porcelain (machine-readable output) for parsing.
    if (std.mem.indexOf(u8, source, "\"--porcelain\"") == null) {
        std.debug.print("!! runGitWorktreeList does not pass --porcelain to git !!\n", .{});
        return error.RunGitWorktreeListNotPorcelain;
    }
}

// ─── Behavioral tests for isCompatibleBranchFamily (pure) ──────────────

test "isCompatibleBranchFamily matches same-family branches" {
    // refactor/x ↔ refactor/y  →  same family
    try testing.expect(swt.isCompatibleBranchFamily("refactor/x", "refactor/y"));
    // feature/x ↔ feature/y  →  same family
    try testing.expect(swt.isCompatibleBranchFamily("feature/auth", "feature/routines"));
    // fix/x ↔ fix/y  →  same family
    try testing.expect(swt.isCompatibleBranchFamily("fix/typo", "fix/bug-42"));
    // feat/x ↔ feat/y  →  same family
    try testing.expect(swt.isCompatibleBranchFamily("feat/ui-redesign", "feat/api-rename"));
    // main ↔ main  →  no family, but the question is "compatible?" — same
    //   exact branch name is the strongest compatibility, but this helper
    //   only tests family prefixes (used as a tie-breaker, not a final answer).
    try testing.expect(!swt.isCompatibleBranchFamily("main", "main"));
    // worktree/x ↔ refactor/x  →  different family
    try testing.expect(!swt.isCompatibleBranchFamily("worktree/x", "refactor/x"));
    // Empty strings are never compatible.
    try testing.expect(!swt.isCompatibleBranchFamily("", "refactor/x"));
    try testing.expect(!swt.isCompatibleBranchFamily("refactor/x", ""));
    try testing.expect(!swt.isCompatibleBranchFamily("", ""));
    // One branch in a known family, the other in a non-family prefix.
    try testing.expect(!swt.isCompatibleBranchFamily("refactor/x", "main"));
    try testing.expect(!swt.isCompatibleBranchFamily("main", "refactor/x"));
}

test "isCompatibleBranchFamily rejects cross-family combinations" {
    const cases = [_][2][]const u8{
        .{ "refactor/x", "feature/y" },
        .{ "feature/x", "fix/y" },
        .{ "fix/x", "feat/y" },
        .{ "feat/x", "refactor/y" },
    };
    for (cases) |pair| {
        try testing.expect(!swt.isCompatibleBranchFamily(pair[0], pair[1]));
    }
}

// ─── Chunk 2: precheck wired into executeSetGitWorktreeToString ────────

test "executeSetGitWorktreeToString calls classifyPath before runGitWorktreeAdd" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The precheck call must appear textually before the
    // runGitWorktreeAdd call in the source (Zig source order is
    // execution order; the precheck must run first).
    const pre_idx = std.mem.indexOf(u8, source, "classifyPath(allocator, io, cwd, worktree_path)") orelse {
        std.debug.print("!! set_git_worktree.zig does not call classifyPath on worktree_path !!\n", .{});
        return error.ClassifyPathCallMissing;
    };
    const add_idx = std.mem.indexOf(u8, source, "runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch, base)") orelse {
        std.debug.print("!! set_git_worktree.zig is missing the runGitWorktreeAdd call !!\n", .{});
        return error.RunGitWorktreeAddCallMissing;
    };
    if (pre_idx >= add_idx) {
        std.debug.print("!! classifyPath must be called BEFORE runGitWorktreeAdd !!\n", .{});
        return error.ClassifyPathNotBeforeRunGitWorktreeAdd;
    }
}

test "executeSetGitWorktreeToString handles all 4 PathState variants" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Look for the explicit switch arm names that the precheck must
    // contain. (Zig's switch on tagged unions does not require an
    // else branch if all variants are listed, but the runtime error
    // for an unhandled variant is unhelpful — we want all 4.)
    const required_arms = [_][]const u8{
        ".not_found =>",
        ".registered_worktree =>",
        ".orphaned_worktree =>",
        ".plain_directory =>",
    };
    for (required_arms) |arm| {
        if (std.mem.indexOf(u8, source, arm) == null) {
            std.debug.print("!! set_git_worktree.zig is missing switch arm '{s}' !!\n", .{arm});
            return error.SwitchArmMissing;
        }
    }
}

test "executeSetGitWorktreeToString auto-binds on compatible branch" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The auto-bind path should call successSetToXml directly from
    // inside the .registered_worktree arm, without re-invoking git.
    // The specific marker is "auto-bound session" — that's the log
    // line + the early return is on the same block.
    if (std.mem.indexOf(u8, source, "auto-bound session") == null) {
        std.debug.print("!! set_git_worktree.zig is missing the 'auto-bound session' log line !!\n", .{});
        return error.AutoBindLogMissing;
    }
    if (std.mem.indexOf(u8, source, "isCompatibleBranchFamily(rwt.branch, branch)") == null) {
        std.debug.print("!! set_git_worktree.zig does not call isCompatibleBranchFamily in the precheck !!\n", .{});
        return error.IsCompatibleBranchFamilyCallMissing;
    }
}

test "set_git_worktree.zig defines freePathState helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn freePathState(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn freePathState' !!\n", .{});
        return error.FreePathStateMissing;
    }
}

test "structured error for incompatible branch mentions existing branch name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The XML error must include the existing branch name and the
    // requested branch name so the LLM can recognize the conflict.
    if (std.mem.indexOf(u8, source, "is already a worktree on branch") == null) {
        std.debug.print("!! set_git_worktree.zig's precheck error does not mention 'is already a worktree on branch' !!\n", .{});
        return error.StructuredErrorMissingBranchName;
    }
    if (std.mem.indexOf(u8, source, "you requested") == null) {
        std.debug.print("!! set_git_worktree.zig's precheck error does not mention the requested branch !!\n", .{});
        return error.StructuredErrorMissingRequestedBranch;
    }
}

// ─── Chunk 3: rewriteGitStderr ─────────────────────────────────────────

test "set_git_worktree.zig defines rewriteGitStderr function" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn rewriteGitStderr(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn rewriteGitStderr' !!\n", .{});
        return error.RewriteGitStderrMissing;
    }
    if (std.mem.indexOf(u8, source, "already exists") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'already exists' pattern !!\n", .{});
        return error.RewriteGitStderrMissingAlreadyExists;
    }
    if (std.mem.indexOf(u8, source, "is already checked out") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'is already checked out' pattern !!\n", .{});
        return error.RewriteGitStderrMissingAlreadyCheckedOut;
    }
    if (std.mem.indexOf(u8, source, "not a git repository") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'not a git repository' pattern !!\n", .{});
        return error.RewriteGitStderrMissingNotARepo;
    }
    if (std.mem.indexOf(u8, source, "invalid reference") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'invalid reference' pattern !!\n", .{});
        return error.RewriteGitStderrMissingInvalidReference;
    }
}

test "rewriteGitStderr rewrites 'already exists' to recovery advice" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(
        allocator,
        "fatal: '/abs/.worktrees/foo' already exists",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    // The original "fatal: ... already exists" must be GONE (replaced),
    // and the new message must mention recovery.
    if (std.mem.indexOf(u8, out, "fatal:") != null) {
        std.debug.print("!! rewriteGitStderr left the 'fatal:' prefix in the output !!\n", .{});
        return error.RewriteKeptFatalPrefix;
    }
    if (std.mem.indexOf(u8, out, "git -C <repo> worktree list --porcelain") == null) {
        std.debug.print("!! rewriteGitStderr's 'already exists' branch does not suggest worktree list !!\n", .{});
        return error.RewriteMissingWorktreeListSuggestion;
    }
}

test "rewriteGitStderr rewrites 'is already checked out' to branch advice" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(
        allocator,
        "fatal: 'worktree/foo' is already checked out at '/abs/.worktrees/foo'",
        "/abs/.worktrees/new",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "auto-derived branch name") == null) {
        std.debug.print("!! rewriteGitStderr's branch-conflict branch does not mention auto-derived branch name !!\n", .{});
        return error.RewriteMissingAutoDerivedSuggestion;
    }
}

test "rewriteGitStderr rewrites 'not a git repository'" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(
        allocator,
        "fatal: not a git repository (or any parent up to mount point /)",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "set_git_worktree requires being called from within a git repo") == null) {
        std.debug.print("!! rewriteGitStderr's not-a-repo branch does not mention the git-repo requirement !!\n", .{});
        return error.RewriteMissingNotARepoExplanation;
    }
}

test "rewriteGitStderr rewrites 'invalid reference' to branch-name rules" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(
        allocator,
        "fatal: invalid reference: bad..name",
        "/abs/.worktrees/foo",
        "bad..name",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "Valid branch names must not contain") == null) {
        std.debug.print("!! rewriteGitStderr's invalid-reference branch does not explain branch-name rules !!\n", .{});
        return error.RewriteMissingBranchRules;
    }
}

test "rewriteGitStderr blames the base ref when one was requested" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(
        allocator,
        "fatal: invalid reference: origin/nope",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "origin/nope",
    );
    defer allocator.free(out);
    // The base ref is the likely culprit, so the message must name it and
    // point at `git fetch` rather than at the new branch name.
    if (std.mem.indexOf(u8, out, "origin/nope") == null) {
        std.debug.print("!! rewriteGitStderr does not name the unresolvable base ref !!\n", .{});
        return error.RewriteMissingBaseRefName;
    }
    if (std.mem.indexOf(u8, out, "git fetch origin") == null) {
        std.debug.print("!! rewriteGitStderr does not suggest `git fetch origin` for an unresolved base !!\n", .{});
        return error.RewriteMissingFetchSuggestion;
    }
}

test "rewriteGitStderr passes through unknown stderr verbatim" {
    const allocator = testing.allocator;
    const unknown = "fatal: some weird edge-case error we did not anticipate\n";
    const out = try swt.rewriteGitStderr(allocator, unknown, "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings(unknown, out);
}

test "rewriteGitStderr returns empty for empty input" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(allocator, "", "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("", out);
}

// ─── Base ref (kanban `Base:` line) ────────────────────────────────────

test "validateBaseRef accepts refs the kanban dialog emits" {
    const ok = [_][]const u8{
        "",
        "origin/main",
        "origin/feat/some-branch",
        "main",
        "worktree/foo-1757792000000",
        "v1.2.3",
    };
    for (ok) |ref| {
        if (swt.validateBaseRef(ref)) |msg| {
            std.debug.print("!! validateBaseRef rejected '{s}': {s} !!\n", .{ ref, msg });
            return error.ValidBaseRefRejected;
        }
    }
}

test "validateBaseRef rejects flag-shaped and malformed refs" {
    const bad = [_][]const u8{
        "-b",
        "--hard",
        "origin/ main",
        "origin/..main",
        "origin//main",
        "origin/main.lock",
        "origin/main@{1}",
        "origin/ma~in",
        "origin/ma^in",
        "origin/ma:in",
        "origin/ma?in",
        "origin/ma*in",
        "origin/ma[in",
        "origin/ma\\in",
        "/origin/main",
        "origin/main/",
    };
    for (bad) |ref| {
        if (swt.validateBaseRef(ref) == null) {
            std.debug.print("!! validateBaseRef accepted invalid ref '{s}' !!\n", .{ref});
            return error.InvalidBaseRefAccepted;
        }
    }
}

test "buildWorktreeAddArgv omits the start-point when base is empty" {
    const argv = try swt.buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "");
    defer testing.allocator.free(argv);

    const expected = [_][]const u8{ "git", "worktree", "add", "-b", "worktree/x", "/tmp/wt/x" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "buildWorktreeAddArgv appends the base as the start-point" {
    const argv = try swt.buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "origin/main");
    defer testing.allocator.free(argv);

    const expected = [_][]const u8{ "git", "worktree", "add", "-b", "worktree/x", "/tmp/wt/x", "origin/main" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "runGitWorktreeAdd receives the base from executeSetGitWorktreeToString" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The base must flow into the git call, not just be parsed.
    if (std.mem.indexOf(u8, source, "runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch, base)") == null) {
        std.debug.print("!! set_git_worktree.zig does not pass `base` to runGitWorktreeAdd !!\n", .{});
        return error.BaseNotForwardedToGit;
    }
    if (std.mem.indexOf(u8, source, "validateBaseRef(base)") == null) {
        std.debug.print("!! set_git_worktree.zig does not validate `base` !!\n", .{});
        return error.BaseNotValidated;
    }
}

test "set_git_worktree tool schema exposes the base property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"base\"") == null) {
        std.debug.print("!! set_git_worktree tool schema is missing the `base` property !!\n", .{});
        return error.BasePropertyMissing;
    }
    // The system prompt must teach the LLM where the value comes from,
    // otherwise the kanban `Base:` line stays inert text.
    if (std.mem.indexOf(u8, source, "`Base:` line") == null) {
        std.debug.print("!! set_git_worktree system prompt does not mention the `Base:` line !!\n", .{});
        return error.BaseNoteNotPrompted;
    }
}

// ─── Chunk 4: tool description recovery guidance ───────────────────────

test "set_git_worktree description mentions recovery on error" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "On error, recover by:") == null) {
        std.debug.print("!! set_git_worktree.zig description is missing the 'On error, recover by:' guidance !!\n", .{});
        return error.RecoveryGuidanceMissing;
    }
    if (std.mem.indexOf(u8, source, "pass `branch=<existing-branch>` to auto-bind to it") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention auto-bind recovery !!\n", .{});
        return error.AutoBindRecoveryMissing;
    }
}

test "set_git_worktree description warns against rm -rf" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "NEVER `rm -rf` the conflicting path") == null) {
        std.debug.print("!! set_git_worktree.zig description does not warn against 'rm -rf' !!\n", .{});
        return error.RmRfWarningMissing;
    }
    if (std.mem.indexOf(u8, source, "uncommitted work") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention uncommitted work risk !!\n", .{});
        return error.UncommittedWorkWarningMissing;
    }
}

test "success SET json includes PR hint note with set_pull_request" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "worktree_pr_note") == null) {
        std.debug.print("!! set_git_worktree.zig does not define worktree_pr_note !!\n", .{});
        return error.SuccessNoteMissing;
    }
    if (std.mem.indexOf(u8, source, "set_pull_request") == null) {
        std.debug.print("!! success note does not mention set_pull_request !!\n", .{});
        return error.SuccessNoteMissingSetPullRequest;
    }
    if (std.mem.indexOf(u8, source, "gh pr create") == null) {
        std.debug.print("!! success note does not mention `gh pr create` !!\n", .{});
        return error.SuccessNoteMissingGhPrCreate;
    }
    if (std.mem.indexOf(u8, source, "agent tool `set_pull_request`") == null) {
        std.debug.print("!! success note must explicitly say agent tool `set_pull_request` !!\n", .{});
        return error.SuccessNoteMissingAgentToolWording;
    }
}

test "set_git_worktree emits JSON (no XML envelope)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "SetGitWorktreeJSON") == null) {
        std.debug.print("!! set_git_worktree.zig does not define SetGitWorktreeJSON !!\n", .{});
        return error.JsonPayloadMissing;
    }
    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("!! set_git_worktree.zig does not serialize via std.json !!\n", .{});
        return error.JsonSerializeMissing;
    }
    if (std.mem.indexOf(u8, source, "<worktree>") != null) {
        std.debug.print("!! set_git_worktree.zig still emits <worktree> XML envelope !!\n", .{});
        return error.XmlEnvelopeStillPresent;
    }
}

test "jsonError carries message with special chars raw" {
    const payload = swt.jsonError(testing.allocator, "s1", "bad <tag> & \"quote\"");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("s1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("bad <tag> & \"quote\"", obj.get("error").?.string);
    try testing.expect(!obj.get("created").?.bool);
}

test "jsonSet carries path/branch/note" {
    const payload = swt.jsonSet(testing.allocator, "s1", "/tmp/wt", "worktree/wt", "");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("created").?.bool);
    try testing.expectEqualStrings("/tmp/wt", obj.get("path").?.string);
    try testing.expectEqualStrings("worktree/wt", obj.get("branch").?.string);
    try testing.expect(obj.get("note").?.string.len > 0);
}

test "jsonClear sets cleared flag" {
    const payload = swt.jsonClear(testing.allocator, "s1");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("cleared").?.bool);
}

// ─── Cross-separator worktree matching (Windows) ──────────────────────────
// The bug: `parseAndMatchBlock` compared git's worktree path against the
// model's with `std.mem.eql`. git for Windows prints FORWARD slashes
// (`worktree C:/Users/me/wt`); the model sends BACKSLASHES. The compare
// never matched, so a live registered worktree was classified
// `.orphaned_worktree`, and that arm's error text instructs the model to
// run `git worktree prune && rm -rf <path>` — on the directory holding the
// work in flight.
//
// These tests run on EVERY platform: `pathsDenoteSameDir` is a pure string
// comparison parameterised by host case-sensitivity, so the Windows-shaped
// input can be exercised from Linux.
test "pathsDenoteSameDir: git forward slashes match the model's backslashes" {
    try testing.expect(swt.pathsDenoteSameDir(
        "C:/Users/ginwa/.config/nalar/.worktrees/fix-login",
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    ));
}

test "pathsDenoteSameDir: trailing and duplicate separators are ignored" {
    try testing.expect(swt.pathsDenoteSameDir("C:/a/b/", "C:\\a\\b"));
    try testing.expect(swt.pathsDenoteSameDir("C:/a//b", "C:\\a\\b"));
    try testing.expect(swt.pathsDenoteSameDir("/home/ginwa/wt/", "/home/ginwa/wt"));
    try testing.expect(swt.pathsDenoteSameDir("", ""));
}

test "pathsDenoteSameDir: different directories still do not match" {
    try testing.expect(!swt.pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt2"));
    try testing.expect(!swt.pathsDenoteSameDir("C:/a/wt", "C:\\b\\wt"));
    // A prefix must not match a longer path.
    try testing.expect(!swt.pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt\\sub"));
    try testing.expect(!swt.pathsDenoteSameDir("/home/ginwa/wt", "/home/other/wt"));
    try testing.expect(!swt.pathsDenoteSameDir("C:/a/wt", ""));
}

// Case sensitivity is host-dependent on purpose: Windows filesystems ignore
// case, Linux ones do not. Asserting the POSIX behaviour everywhere and the
// Windows behaviour in a gated leg keeps the function honest on both.
test "pathsDenoteSameDir: case is ignored only on Windows" {
    if (@import("builtin").os.tag == .windows) {
        try testing.expect(swt.pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    } else {
        try testing.expect(!swt.pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    }
}

// The end-to-end leg: a real `git worktree list --porcelain` block, exactly
// as Windows git prints it, matched against the path the model would send.
test "parseAndMatchBlock: a Windows worktree listing matches the model's backslash path" {
    const block =
        \\worktree C:/Users/ginwa/.config/nalar/.worktrees/fix-login
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/fix-login
        \\
        \\
    ;
    const matched = try swt.parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    );
    try testing.expect(matched != null);
    defer if (matched) |m| {
        testing.allocator.free(m.branch_ref);
        testing.allocator.free(m.branch);
        testing.allocator.free(m.commit);
        testing.allocator.free(m.path);
    };
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", matched.?.commit);
    try testing.expectEqualStrings("worktree/fix-login", matched.?.branch);
}

test "parseAndMatchBlock: a genuinely different worktree is not matched" {
    const block =
        \\worktree C:/Users/ginwa/.config/nalar/.worktrees/other
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/other
        \\
    ;
    const matched = try swt.parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    );
    try testing.expect(matched == null);
}

// Pin the CAUSE as well as the behaviour, so a future "simplification" back
// to raw equality is caught even on a host where it happens to work.
test "static contract: parseAndMatchBlock does not compare worktree paths with std.mem.eql" {
    const source = try readSource(testing.allocator, TOOL_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "fn parseAndMatchBlock(") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pathsDenoteSameDir(wt_path, target)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn pathsDenoteSameDir(") != null);
}
