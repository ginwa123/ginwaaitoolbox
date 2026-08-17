//! src/modules/agent/tools/path_security.zig
//!
//! Shared absolute-path validator + cwd resolver for LLM-facing agent
//! tools. Security policy: absolute paths are BANNED in agent tool
//! inputs. Agents must operate relative to the session's bound working
//! directory (or the active git-worktree binding).
//!
//! Used by every tool's exec wrapper in `src/ai_workflow/tui/agentic_loop/
//! tools_exec_<name>.zig`. The two admin-tier tools that still accept
//! absolute paths (`set_git_worktree.path`, `create_kanban_task.cwd`)
//! deliberately do NOT call into this module.
//!
//! Spec: docs/superpowers/specs/2026-08-14-ban-absolute-paths-design.md
//! Plan: docs/superpowers/plans/2026-08-14-ban-absolute-paths.md

const std = @import("std");

/// Reject absolute paths. Returns `null` when the path is relative (caller
/// proceeds); returns the pre-formatted `<error>` block when absolute
/// (caller wraps with `wrapToolOutput(..., success=false, ...)` and bails).
///
/// The error envelope names the tool, the parameter, the rejected path,
/// and the active cwd — so the LLM can compute the correct relative path
/// on its retry turn without asking the user for help.
///
/// `active_cwd` is shown verbatim in the error so the LLM can compute
/// `<active_cwd>/<intended_relative>` itself. Don't redact it.
pub fn rejectAbsolutePath(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    param_name: []const u8,
    path: []const u8,
    active_cwd: []const u8,
) !?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) return null;

    const msg = try std.fmt.allocPrint(
        allocator,
        \\absolute paths are not allowed in {s} (security policy); use a path relative to the session's working directory.
        \\param: {s}
        \\rejected: {s}
        \\active cwd: {s}
    ,
        .{ tool_name, param_name, path, active_cwd },
    );
    return @as(?[]const u8, msg);
}

/// Compute an absolute path's relative form against the active cwd.
/// Used by every tool's exec wrapper to display relative paths in
/// the LLM-facing output (instead of leaking absolute filesystem
/// paths). `base` should be `ctx.cwd_override ?? ctx.cwd`.
pub fn relativePath(
    allocator: std.mem.Allocator,
    base: []const u8,
    abs: []const u8,
) ![]u8 {
    // Fast path: abs is a child of base — strip the prefix.
    if (std.mem.startsWith(u8, abs, base)) {
        const rest = abs[base.len..];
        if (rest.len == 0) return allocator.dupe(u8, ".");
        if (rest[0] == '/') {
            if (rest.len == 1) return allocator.dupe(u8, ".");
            return allocator.dupe(u8, rest[1..]);
        }
        // abs is a sibling-prefix of base (e.g. base="/a", abs="/abc") —
        // fall through to the general algorithm.
    }

    // General algorithm: find common path prefix, count parent dirs
    // in the remaining base, prepend "../" for each, append the
    // remaining abs.
    var common_len: usize = 0;
    while (common_len < base.len and common_len < abs.len and base[common_len] == abs[common_len]) {
        common_len += 1;
    }
    // Snap common_len back to the previous '/' so we don't split a
    // segment name.
    while (common_len > 0 and common_len < base.len and base[common_len] != '/') {
        common_len -= 1;
    }

    var up_count: usize = 0;
    var i: usize = common_len;
    while (i < base.len) {
        if (base[i] == '/') up_count += 1;
        i += 1;
    }
    if (common_len < base.len) up_count += 1;

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var u: usize = 0;
    while (u < up_count) : (u += 1) {
        try result.appendSlice(allocator, "../");
    }
    try result.appendSlice(allocator, abs[common_len..]);
    return result.toOwnedSlice(allocator);
}

/// Resolve a tool-call's cwd parameter against the active session cwd.
///
/// Rules:
/// - `raw == null` OR `raw == ""` → returns `ctx_cwd_override ?? ctx_cwd`.
/// - `raw` is a relative path → joins `ctx_cwd_override ?? ctx_cwd` + `raw`.
/// - `raw` is absolute → `unreachable` (the caller MUST have already run
///   `rejectAbsolutePath` to enforce the no-absolute-paths policy).
///
/// The result is heap-allocated; the caller owns it and must `free` it.
pub fn resolveCwd(
    allocator: std.mem.Allocator,
    ctx_cwd: []const u8,
    ctx_cwd_override: ?[]const u8,
    raw: ?[]const u8,
) ![]u8 {
    const base = ctx_cwd_override orelse ctx_cwd;

    const path = raw orelse return allocator.dupe(u8, base);
    if (path.len == 0) return allocator.dupe(u8, base);
    if (std.fs.path.isAbsolute(path)) unreachable; // rejectAbsolutePath MUST run first

    return std.fs.path.join(allocator, &.{ base, path });
}
