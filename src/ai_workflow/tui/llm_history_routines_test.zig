//! Static regression checks for the routine-aware task struct in
//! `llm_history.zig`. The `WorkspaceItemTaskInfo` struct must gain
//! `task_type` + `routine` fields and a new `RoutineMeta` struct.
//! The lister must LEFT JOIN routines.
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
}

test "WorkspaceItemTaskInfo has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const struct_sig = "pub const WorkspaceItemTaskInfo = struct";
    const sig_idx = std.mem.indexOf(u8, source, struct_sig) orelse
        return error.WorkspaceItemTaskInfoNotFound;
    const after_sig = sig_idx + struct_sig.len;
    const end_marker = std.mem.indexOfPos(u8, source, after_sig, "};") orelse source.len;
    const body = source[after_sig..end_marker];

    if (std.mem.indexOf(u8, body, "task_type") == null) return error.TaskTypeFieldMissing;
    if (std.mem.indexOf(u8, body, "routine") == null) return error.RoutineFieldMissing;
}

test "RoutineMeta struct exists in llm_history" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const RoutineMeta = struct") == null) return error.RoutineMetaMissing;
}

test "listWorkspaceItemTasksWithCursor SQL joins the routines table" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const fn_sig = "pub fn listWorkspaceItemTasksWithCursor(";
    const sig_idx = std.mem.indexOf(u8, source, fn_sig) orelse return error.ListFnNotFound;
    const after_sig = sig_idx + fn_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "LEFT JOIN routines") == null) return error.JoinMissing;
}
