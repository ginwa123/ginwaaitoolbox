// DEPRECATED: use the unified `command` tool (src/modules/agent/tools/command.zig) instead — this file is a thin shim keeping the `"bash"` name: `bash_tool` reuses `command_tool`'s schema and `execute_bash` delegates to `command.execute_command`.
const std = @import("std");
const command = @import("command.zig");
const schemas = @import("schemas.zig");

const BashInput = schemas.BashInput;
const BashOutput = schemas.BashOutput;
const AgentTool = schemas.AgentTool;

pub const CommandForbidden = error{
    /// Command contains forbidden patterns that produce unbounded output
    CommandForbidden,
};

/// Returned by `execute_bash` when the caller omits `mandatory_timeout`.
pub const MandatoryTimeoutMissing = error{MandatoryTimeoutMissing};

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the bash process group. (Moved to shell.zig.)
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Run a bash command. Deprecated shim over `command.execute_command`
/// (which dispatches to `bash -c` off-Windows, `pwsh` on Windows).
pub fn execute_bash(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: BashInput,
) !BashOutput {
    return command.execute_command(allocator, io, input);
}

/// JSON serialiser — re-export from the unified command module under the
/// bash name for ergonomic callers.
pub const bash_result_to_json = command.command_result_to_json;

pub const bash_tool_system_prompt = command.command_tool_system_prompt;

pub const bash_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description = command.command_tool.function.description,
        .parameters = command.command_tool.function.parameters,
        .system_prompt = bash_tool_system_prompt,
    },
};
