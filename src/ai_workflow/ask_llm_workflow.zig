const std = @import("std");
const agent = @import("../modules/agent/agent.zig");
const context = @import("models.zig").ContextIPCTui;

pub const AskLLMWorkflow = struct {
    ctx: *context,
    allocator: std.mem.Allocator,

    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) AskLLMWorkflow {
        return AskLLMWorkflow{
            .allocator = allocator,
            .agent = agent.Agent.init(allocator) catch unreachable,
        };
    }

    pub fn run(self: *AskLLMWorkflow) !void {
        const systemMessage = agent.AgentMessage{
            .role = .system,
            .content = "You are a helpful assistant.",
        };

        const userMessage = agent.AgentMessage{
            .role = .user,
            .content = "Hello world",
        };

        const messages = &[_]agent.AgentMessage{ systemMessage, userMessage };

        while (true) {
            var agenttt = try agent.Agent.init(self.allocator);
            defer agenttt.deinit();

            agenttt.apiKey = self.api_key;
            agenttt.model = self.model;
            agenttt.baseUrl = self.base_url;

            const agetntCall = agent.AgentCall{
                .tools = &.{},
                .messages = messages,
            };
            const response = try agenttt.call(agetntCall);
            defer response.deinit();

            if (response.finish_reason) |finish_reason| {
                if (finish_reason == .stop) {
                    std.debug.print("FINISH REASON STOP", .{});
                    break;
                } else if (finish_reason == .length) {
                    std.debug.print("FINISH REASON LENGTH", .{});
                    break;
                } else if (finish_reason == .tool_calls) {
                    std.debug.print("FINISH REASON TOOL CALLS", .{});
                    break;
                } else if (finish_reason == .content_filter) {
                    std.debug.print("FINISH REASON CONTENT FILTER", .{});
                    break;
                }
            } else {
                std.debug.print("BREAK LLM", .{});
                break;
            }
        }
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
