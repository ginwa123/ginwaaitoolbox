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
