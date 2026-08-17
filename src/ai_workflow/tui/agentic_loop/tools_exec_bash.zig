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

/// Run with database context for background process tracking.
/// Lives alongside execBash because it's a file-private helper used
/// only by execBash.
///
/// `input` is the already-validated + cwd-resolved BashInput — the
/// validation happens in `execBash` (which has access to the tool
/// context for the active cwd), not here.
pub fn runWithContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: tool_models.BashInput,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
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
    // 1. Parse arguments JSON so we can validate the cwd field.
    const parsed = std.json.parseFromSlice(
        tool_models.BashInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "bash failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. Security: reject absolute cwd paths. Relative paths and
    // omitted cwd are allowed.
    if (parsed.value.cwd) |cwd| {
        if (try nalarcore.path_security.rejectAbsolutePath(
            ctx.allocator, "bash", "cwd", cwd, ctx.cwd
        )) |err_msg| {
            defer ctx.allocator.free(err_msg);
            const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    // 3. Resolve cwd: relative/null/empty → ctx.cwd_override ?? ctx.cwd.
    // The validator above guarantees `parsed.value.cwd` is not absolute.
    const resolved_cwd = try nalarcore.path_security.resolveCwd(
        ctx.allocator, ctx.cwd, ctx.cwd_override, parsed.value.cwd
    );
    defer ctx.allocator.free(resolved_cwd);

    var input = parsed.value;
    input.cwd = resolved_cwd;

    const inner = try runWithContext(ctx.allocator, ctx.io, input, ctx.db, ctx.session_id);
    const output = try wrapToolOutput(ctx.allocator, "bash", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}