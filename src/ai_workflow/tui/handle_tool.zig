const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const send_response = @import("send_response.zig");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const loop_detector = tree1_mod.loop_detector;

// Forward declaration for TUIWorkflow
const TUIWorkflow = @import("tui_workflow.zig").TUIWorkflow;

pub fn run(
    allocator: std.mem.Allocator,
    tui_workflow: *TUIWorkflow,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    current_agent: *[]const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
) !void {
    send_response.run(allocator, conn_fd, logger, res_dynamic_agent, null);
    if (res_dynamic_agent.tool_calls) |tc| {
        // Add assistant message with tool_calls to history
        var assistant_tool_calls = try allocator.alloc(agent.ToolCall, tc.len);
        for (tc, 0..) |tool_call, i| {
            assistant_tool_calls[i] = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .function = .{
                    .name = try allocator.dupe(u8, tool_call.function.name),
                    .arguments = try allocator.dupe(u8, tool_call.function.arguments),
                },
            };
        }

        // Merge reasoning_content into content of the tool call assistant message
        // const reasoningContent: ?[]u8 = if (res_dynamic_agent.reasoning_content) |rc|
        //     try allocator.dupe(u8, rc)
        // else
        //     null;

        // const contentNormal: []const u8 = if (res_dynamic_agent.content) |c|
        //     try allocator.dupe(u8, c)
        // else
        //     "";

        // const mergedContent: ?[]u8 = if (reasoningContent != null or contentNormal != null) blk: {
        //     const r = reasoningContent orelse "";
        //     const c = contentNormal orelse "";
        //     break :blk try std.mem.concat(allocator, u8, &.{ r, c });
        // } else null;

        // const assistant_msg = agent.AgentMessage{
        //     .role = .assistant,
        //     .content = "",
        //     .tool_calls = assistant_tool_calls,
        // };

        // try messages_list.append(allocator, assistant_msg);

        save_message.run(
            allocator, db, session_id, model, cwd,
            null,
            res_dynamic_agent.content,
            if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
            res_dynamic_agent.reasoning_content,
            agent.Role.assistant.toStr(), null, assistant_tool_calls, null, current_agent.*, session_name, loop_counter) catch |err| {
            logger.errFmt("saveMessage error: {s}", .{@errorName(err)}) catch {};
        };

        // Execute each tool call and add tool result messages
        for (tc) |tool_call| {
            logger.debugFmt("Executing tool: {s}   {s}", .{ tool_call.function.name, tool_call.function.arguments }) catch {};
            if (tui_workflow.loop_detector.check(tool_call.function.arguments)) {
                const warning = try std.fmt.allocPrint(
                    allocator,
                    "WARNING: Identical command repeated: {s}\n" ++
                        "Empty output means no results found — do NOT retry. Proceed with what you know.",
                    .{tool_call.function.arguments},
                );
                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = warning,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                try messages_list.append(allocator, tool_result_msg);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "change_agent_tool")) {
                try handle_change_agent_tool.run(allocator, db, logger, conn_fd, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature, isThinking, current_agent);
            }
            if (std.mem.eql(u8, tool_call.function.name, "bash")) {
                _ = handle_bash_tool.run(allocator, db, logger, conn_fd, session_id, model, cwd, current_agent.*, session_name, loop_counter, messages_list, tool_call) catch |err| {
                    logger.errFmt("Error handling bash tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "list_skills")) {
                tui_workflow.handleListSkills(allocator, messages_list, tool_call, session_id, model, cwd, conn_fd);
            }

            if (std.mem.eql(u8, tool_call.function.name, "get_skill")) {
                _ = try tui_workflow.handleGetSkill(allocator, messages_list, tool_call, session_id, model, cwd, conn_fd);
            }
        }
        logger.debugFmt("All tools executed, continuing to next LLM call. Message count: {}", .{messages_list.items.len}) catch {};
    } else {
        logger.warnFmt("Tool function not found", .{}) catch {};
    }
    // Continue to next LLM call - no break, loop continues naturally
    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{}) catch {};
}

test {
    _ = @import("handle_tool_test.zig");
}
