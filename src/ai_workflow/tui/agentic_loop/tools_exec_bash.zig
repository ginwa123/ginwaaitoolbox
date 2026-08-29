const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const sqlite = nalarcore.sqlite;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;
const bash_tool_mod = nalarcore.bash_tool;
const background_process = @import("background_process.zig");
const wrapToolOutput = tools.wrapToolOutput;
const bash_args = @import("tools_exec_bash_args.zig");

/// Run with database context for background process tracking.
/// Lives alongside execBash because it's a file-private helper used
/// only by execBash.
///
/// task_1787855066467_8 — argument parsing now uses
/// `tools_exec_bash_args.parseShellArgs` instead of a strict direct
/// typed parse into BashInput. The lenient parser:
///   1. Recovers the common LLM-hallucinated XML-fragment case
///      (`mandatory_timeout: "5</mandatory_timeout>"` → 5) so the bash
///      tool keeps working through the leak.
///   2. Surfaces structured InvalidField info (field + verbatim value
///      + expected type) on real coercion failures, so the LLM can
///      self-correct on the next turn.
pub fn runWithContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_call: agent.ToolCall,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    const input = switch (bash_args.parseShellArgs(allocator, tool_call.function.arguments)) {
        .success => |in| in,
        .failure => |info| {
            const err_msg = try bash_args.formatInvalidField(allocator, info);
            const output = try wrapToolOutput(allocator, "bash", tool_call.function.arguments, false, err_msg, "");
            return output;
        },
    };
    // parseShellArgs dups every string field it produces (command / cwd /
    // stdin_data) so the caller can hold the slice past the JSON value's
    // lifetime. Free them once execute_bash returns.
    defer {
        allocator.free(input.command);
        if (input.cwd) |c| allocator.free(c);
        if (input.stdin_data) |s| allocator.free(s);
    }

    const is_background = input.background;

    const bash_output = try bash_tool_mod.execute_bash(allocator, io, input);

    // If background mode and DB is available, save the process info
    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

        // Parse PID from bash output (format: "PID: {pid}\nLog: {path}")
        const stdout = bash_output.stdout;
        if (stdout.len > 5) {
            // Skip "PID: " prefix
            const pid_start = 5;
            var pid_end: usize = 4;
            while (pid_end < stdout.len and stdout[pid_end] != '\n') : (pid_end += 1) {}

            if (pid_end > pid_start) {
                const pid_str = stdout[pid_start..pid_end];
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch 0;

                if (pid > 0) {
                    // Extract log path from "Log: {path}" part
                    var log_start: usize = 0;
                    while (log_start < stdout.len and stdout[log_start] != '\n') : (log_start += 1) {}
                    log_start += 1; // skip newline

                    // Find "Log: " prefix
                    var log_path_start = log_start;
                    while (log_path_start < stdout.len and log_path_start < log_start + 5) : (log_path_start += 1) {}

                    if (log_path_start < stdout.len) {
                        const log_path = stdout[log_path_start..];

                        // Save to database
                        const ts = std.Io.Clock.now(.real, io);
                        const started_at: i64 = ts.toSeconds();
                        background_process.save(db_ptr, allocator, sess_id, pid, input.command, log_path, started_at) catch {
                            // Log error but don't fail the tool execution
                        };
                    }
                }
            }
        }
    }

    const res_bash = try bash_tool_mod.bash_result_to_string(allocator, bash_output);

    return res_bash;
}

pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Catch ANY remaining error from the run path (e.g. from
    // `execute_bash` itself — fork failures, permission errors, etc.)
    // and wrap it in the standard tool-error envelope, matching
    // execReadFile / execWriteFile / etc.
    const inner = runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "bash failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ============================================================================
// Tests
// ============================================================================
//
// The argument-parser logic itself (XML-fragment recovery + structured
// failure envelope) is covered by 24 unit tests in
// `tools_exec_bash_args.zig` — those exercise the exact wire payloads
// from the user's bug. This file's contract is just the import + the
// error-path wiring, both of which are verified by Zig's compiler
// (the import fails if the helper isn't wired) and by the executor
// tests in `tools_exec_bash_test.zig` (which exercise real bash runs).
//
// No additional static-contract tests here — `@embedFile`-based
// self-reference patterns are fragile and the actual unit tests in
// the helper cover the bug end-to-end.