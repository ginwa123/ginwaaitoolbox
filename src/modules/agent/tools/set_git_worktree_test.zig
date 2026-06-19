const std = @import("std");
const testing = std.testing;
const swt = @import("set_git_worktree.zig");

const TOOL_PATH = "src/modules/agent/tools/set_git_worktree.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
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

const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/tool_registry.zig";

test "tool_registry.zig imports set_git_worktree module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "set_git_worktree_mod") == null) {
        std.debug.print("!! tool_registry.zig does not import set_git_worktree_mod !!\n", .{});
        return error.SetGitWorktreeModImportMissing;
    }
    if (std.mem.indexOf(u8, source, "const set_git_worktree_mod = nalar_mod.set_git_worktree;") == null) {
        std.debug.print("!! tool_registry.zig does not bind set_git_worktree_mod = nalar_mod.set_git_worktree !!\n", .{});
        return error.SetGitWorktreeModBindingMissing;
    }
}

test "tool_registry.zig defines execSetGitWorktree" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn execSetGitWorktree(") == null) {
        std.debug.print("!! tool_registry.zig does not define pub fn execSetGitWorktree !!\n", .{});
        return error.ExecSetGitWorktreeMissing;
    }
    if (std.mem.indexOf(u8, source, "updateSessionGitWorktreeCwd") == null) {
        std.debug.print("!! execSetGitWorktree does not call updateSessionGitWorktreeCwd for DB persistence !!\n", .{});
        return error.PersistenceCallMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_git_worktree entry" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    // The registry entry should be a struct literal that wires the
    // exec function and the tool definition together.
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_git_worktree name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (std.mem.indexOf(u8, source, ".exec = execSetGitWorktree") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = execSetGitWorktree !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (std.mem.indexOf(u8, source, ".tool_def = set_git_worktree_mod.set_git_worktree_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_git_worktree tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "set_git_worktree_mod.set_git_worktree_tool,") == null) {
        std.debug.print("!! allAgentTools comptime list is missing set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "ToolExecContext has cwd_override field (Plan B forward-compat)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_REGISTRY_PATH);
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
    const add_idx = std.mem.indexOf(u8, source, "runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch)") orelse {
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
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "Valid branch names must not contain") == null) {
        std.debug.print("!! rewriteGitStderr's invalid-reference branch does not explain branch-name rules !!\n", .{});
        return error.RewriteMissingBranchRules;
    }
}

test "rewriteGitStderr passes through unknown stderr verbatim" {
    const allocator = testing.allocator;
    const unknown = "fatal: some weird edge-case error we did not anticipate\n";
    const out = try swt.rewriteGitStderr(allocator, unknown, "/x", "worktree/x");
    defer allocator.free(out);
    try testing.expectEqualStrings(unknown, out);
}

test "rewriteGitStderr returns empty for empty input" {
    const allocator = testing.allocator;
    const out = try swt.rewriteGitStderr(allocator, "", "/x", "worktree/x");
    defer allocator.free(out);
    try testing.expectEqualStrings("", out);
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
