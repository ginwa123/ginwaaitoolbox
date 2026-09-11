// DEPRECATED: use tools_exec_command.execCommand instead — this file is a thin shim keeping the `"pwsh"` exec path: `execPwsh` delegates to `execCommand`.
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const command_exec = @import("tools_exec_command.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;

pub const runWithContext = command_exec.runWithContext;

pub fn execPwsh(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    return command_exec.execCommand(ctx, tc);
}
