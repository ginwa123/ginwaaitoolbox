const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const bash_tool = tree1_mod.bash_tool;
const tool_models = tree1_mod.tool_models;
const background_process = @import("background_process.zig");

/// Stateless bash tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute bash command
/// Returns the bash output as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    return runWithContext(allocator, tool_call, null, null);
}

/// Run with database context for background process tracking
pub fn runWithContext(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
    db: ?*tree1_mod.sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    // Parse arguments JSON to BashInput
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const is_background = parsed.value.background;

    const bash_output = try bash_tool.executeBash(allocator, parsed.value);
    
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
                        const started_at = std.time.timestamp();
                        background_process.save(db_ptr, allocator, sess_id, pid, parsed.value.command, log_path, started_at) catch {
                            // Log error but don't fail the tool execution
                        };
                    }
                }
            }
        }
    }
    
    const res_bash = try bash_tool.bashResultToString(allocator, bash_output);
    
    return res_bash;
}

test {
    _ = @import("handle_bash_tool_test.zig");
}
