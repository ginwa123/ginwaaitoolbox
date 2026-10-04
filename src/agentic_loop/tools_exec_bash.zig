// DEPRECATED: use tools_exec_command.execCommand instead — this file is a thin shim keeping the `"bash"` exec path: `execBash` delegates to `execCommand`.
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const command_exec = @import("tools_exec_command.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;

pub const runWithContext = command_exec.runWithContext;

pub fn execBash(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    return command_exec.execCommand(ctx, tc);
}
