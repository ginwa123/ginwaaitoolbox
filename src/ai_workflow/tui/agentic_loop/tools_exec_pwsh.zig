const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const sqlite = nalarcore.sqlite;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;
const pwsh_tool_mod = nalarcore.pwsh_tool;
const background_process = @import("background_process.zig");
const wrapToolOutput = tools.wrapToolOutput;

/// Mirror of `tools_exec_bash.runWithContext`. The XML envelope is the
/// same 9-tag shape (see shell.result_to_xml), so the background-mode
/// PID-parsing in `tools_exec_bash.runWithContext` works verbatim — pwsh
/// background mode also emits "PID: <n>\nLog: <path>" (D8 in the plan:
/// this is bash's nohup idiom; pwsh's `Start-Process` follow-up will
/// change it).
pub fn runWithContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_call: agent.ToolCall,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    // Parse arguments JSON to ShellInput (alias for BashInput per Task 2 —
    // the wire schema is identical, only the tool name differs).
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const is_background = parsed.value.background;
    const pwsh_output = try pwsh_tool_mod.execute_pwsh(allocator, io, parsed.value);

    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;
        const stdout = pwsh_output.stdout;
        if (stdout.len > 5) {
            const pid_start: usize = 5;
            var pid_end: usize = 4;
            while (pid_end < stdout.len and stdout[pid_end] != '\n') : (pid_end += 1) {}
            if (pid_end > pid_start) {
                const pid_str = stdout[pid_start..pid_end];
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch 0;
                if (pid > 0) {
                    var log_start: usize = 0;
                    while (log_start < stdout.len and stdout[log_start] != '\n') : (log_start += 1) {}
                    log_start += 1;
                    var log_path_start = log_start;
                    while (log_path_start < stdout.len and log_path_start < log_start + 5) : (log_path_start += 1) {}
                    if (log_path_start < stdout.len) {
                        const log_path = stdout[log_path_start..];
                        const ts = std.Io.Clock.now(.real, io);
                        const started_at: i64 = ts.toSeconds();
                        background_process.save(db_ptr, allocator, sess_id, pid, parsed.value.command, log_path, started_at) catch {};
                    }
                }
            }
        }
    }

    const res = try pwsh_tool_mod.pwsh_result_to_string(allocator, pwsh_output);
    return res;
}

pub fn execPwsh(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = try runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id);
    // wrapToolOutput tool_name arg is "pwsh" — this is what the
    // frontend's <ToolCard tool-name="…"> reads to pick a render path.
    // Distinct from the bash tool_name = "bash" used by execBash.
    const output = try wrapToolOutput(ctx.allocator, "pwsh", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}