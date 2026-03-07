const std = @import("std");
const TUIHistory = @import("models.zig").TUIHistory;
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;
const json = std.json;

pub fn run(allocator: std.mem.Allocator, message: TUIHistory) ![]agent.AgentMessage {
    var messages: std.ArrayList(agent.AgentMessage) = .empty;

    const role = agent.Role.fromStr(message.role) orelse .assistant;

    // Handle tool result messages (role == "tool")
    // For tool messages, the tools column contains the tool_call_id string directly
    if (role == .tool) {
        const agentMessage = agent.AgentMessage{
            .role = .tool,
            .content = try allocator.dupe(u8, message.response_content),
            .tool_call_id = try allocator.dupe(u8, message.tools),
        };
        try messages.append(allocator, agentMessage);
        return messages.toOwnedSlice(allocator);
    }

    // Handle assistant/user/system messages
    const finishReason = agent.FinishReason.fromStr(message.finish_reason);
    const isToolCalls = finishReason == .tool_calls;

    if (message.response_content.len > 0 or isToolCalls) {
        var tool_calls: ?[]agent.ToolCall = null;
        const toolSource = if (message.tools.len > 0) message.tools else message.response_content;
        const tcParsed = json.parseFromSlice(json.Value, allocator, toolSource, .{}) catch null;
        if (tcParsed) |tcp| {
            defer tcp.deinit();
            if (tcp.value == .array and tcp.value.array.items.len > 0) {
                var calls = try allocator.alloc(agent.ToolCall, tcp.value.array.items.len);
                for (tcp.value.array.items, 0..) |tc_item, i| {
                    if (tc_item == .object) {
                        const id_raw = if (tc_item.object.get("id")) |id_val| id_val.string else "";
                        const func_obj = if (tc_item.object.get("function")) |f| f.object else null;
                        const name_raw = if (func_obj) |fo| if (fo.get("name")) |n| n.string else "" else "";
                        const args_raw = if (func_obj) |fo| if (fo.get("arguments")) |a| a.string else "" else "";
                        calls[i] = .{
                            .id = try allocator.dupe(u8, id_raw),
                            .function = .{
                                .name = try allocator.dupe(u8, name_raw),
                                .arguments = try allocator.dupe(u8, args_raw),
                            },
                        };
                    } else {
                        calls[i] = .{
                            .id = try allocator.dupe(u8, ""),
                            .function = .{
                                .name = try allocator.dupe(u8, ""),
                                .arguments = try allocator.dupe(u8, ""),
                            },
                        };
                    }
                }
                tool_calls = calls;
            }
        }

        const content: ?[]const u8 = if (isToolCalls)
            (if (message.reasoning_content) |rc| try allocator.dupe(u8, rc) else null)
        else
            try allocator.dupe(u8, message.response_content);

        const reasoning_content: ?[]const u8 = if (message.reasoning_content) |rc| try allocator.dupe(u8, rc) else null;

        const agentMessage = agent.AgentMessage{
            .role = role,
            .content = content,
            .tool_calls = tool_calls,
            .reasoning_content = reasoning_content,
        };
        try messages.append(allocator, agentMessage);
    }

    return messages.toOwnedSlice(allocator);
}

test {
    _ = @import("transform_llm_history_to_agent_messages_test.zig");
}
