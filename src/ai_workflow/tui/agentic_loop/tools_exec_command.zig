const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const sqlite = nalarcore.sqlite;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;
const command_tool_mod = nalarcore.command_tool;
const background_process = @import("background_process.zig");
const wrapToolOutput = tools.wrapToolOutput;
const bash_args = @import("tools_exec_bash_args.zig");

/// Merged exec body for the unified `command` tool (Phase A+B of the unify
/// plan — shared logic moved here from `tools_exec_bash.zig` /
/// `tools_exec_pwsh.zig`, which are now thin shims over this module).
///
/// Argument parsing uses `tools_exec_bash_args.parseShellArgs` (lenient:
/// recovers LLM-hallucinated XML fragments like
/// `mandatory_timeout: "5</mandatory_timeout>"` → 5, surfaces structured
/// InvalidField info on real coercion failures).
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
            const output = try wrapToolOutput(allocator, "command", tool_call.function.arguments, false, err_msg, "");
            return output;
        },
    };
    // parseShellArgs dups every string field it produces (command / cwd /
    // stdin_data) so the caller can hold the slice past the JSON value's
    // lifetime. Free them once execute_command returns.
    defer {
        allocator.free(input.command);
        if (input.cwd) |c| allocator.free(c);
        if (input.stdin_data) |s| allocator.free(s);
    }

    const is_background = input.background;

    const command_output = try command_tool_mod.execute_command(allocator, io, input);

    // If background mode and DB is available, save the process info
    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

        // Parse PID from command output (format: "PID: {pid}\nLog: {path}")
        const stdout = command_output.stdout;
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

    const res_command = try command_tool_mod.command_result_to_string(allocator, command_output);

    return res_command;
}

pub fn execCommand(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Catch ANY remaining error from the run path (e.g. from
    // `execute_command` itself — fork failures, permission errors, etc.)
    // and wrap it in the standard tool-error envelope, matching
    // execReadFile / execWriteFile / etc.
    const inner = runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "command failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
