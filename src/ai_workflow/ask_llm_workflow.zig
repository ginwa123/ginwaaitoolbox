const std = @import("std");
const agent = @import("../modules/agent/agent.zig");
const prompt = @import("../modules/agent/prompt.zig");
const context = @import("models.zig").ContextIPCTui;

pub const AskLLMWorkflow = struct {
    ctx: *context,
    allocator: std.mem.Allocator,
    message: []const u8 = "",

    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",

    conn_fd: std.posix.fd_t = -1,

    pub fn init(allocator: std.mem.Allocator) AskLLMWorkflow {
        return AskLLMWorkflow{
            .allocator = allocator,
            .agent = agent.Agent.init(allocator) catch unreachable,
        };
    }

    pub fn run(self: *AskLLMWorkflow) !void {
        const systemMessage = agent.AgentMessage{
            .role = .system,
            .content = prompt.AgenticCoding,
        };

        const userMessage = agent.AgentMessage{
            .role = .user,
            .content = self.message,
        };

        const messages = &[_]agent.AgentMessage{ systemMessage, userMessage };

        var retryCount: usize = 0;
        while (true) {
            if (retryCount > 3) return error.TooManyRetries;
            var agenttt = try agent.Agent.init(self.allocator);
            defer agenttt.deinit();

            agenttt.apiKey = self.api_key;
            agenttt.model = self.model;
            agenttt.baseUrl = self.base_url;
            // agenttt.logger = agent.AgentLogger{ .logMsg = self.logMsg };

            const agetntCall = agent.AgentCall{
                .tools = &.{},
                .messages = messages,
            };
            const response = agenttt.call(agetntCall) catch |err| {
                retryCount += 1;
                std.debug.print("Error calling agent: {s}\n", .{@errorName(err)});
                continue;
            };
            defer response.deinit();

            if (response.content) |c| {
                std.debug.print("Sending message: {s}\n", .{c});
                _ = self.sendMessage(c);
            }

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

            retryCount = 0;
        }
    }

    pub fn sendMessage(self: *AskLLMWorkflow, msg: []const u8) void {
        if (self.conn_fd < 0) return;
        _ = std.posix.write(self.conn_fd, msg) catch {};
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
