const std = @import("std");
const json = std.json;
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

    fn sendResponse(self: *AskLLMWorkflow, response: agent.Agent.CallResponse) void {
        if (self.conn_fd < 0) return;

        var choices = self.allocator.alloc(agent.Choice, 1) catch return;
        defer self.allocator.free(choices);

        choices[0] = agent.Choice{
            .index = 0,
            .message = agent.Message{
                .role = agent.Role.assistant.toStr(),
                .content = response.content,
                .tool_calls = response.tool_calls,
            },
            .finish_reason = response.finish_reason,
        };

        const agentResponse = agent.AgentResponse{
            .choices = choices,
        };

        var message_buffer_out = std.io.Writer.Allocating.init(self.allocator);
        var stringifier = json.Stringify{
            .writer = &message_buffer_out.writer,
            .options = .{},
        };

        stringifier.write(agentResponse) catch {
            message_buffer_out.deinit();
            return;
        };

        const json_slice = message_buffer_out.toOwnedSlice() catch return;
        defer self.allocator.free(json_slice);

        _ = std.posix.write(self.conn_fd, json_slice) catch |err| {
            if (err != error.BrokenPipe) {
                std.debug.print("Send Response error {s}\n", .{@errorName(err)});
            }
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

            self.sendResponse(response);

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

    fn saveMessage(self: *AskLLMWorkflow, response: agent.Agent.CallResponse) !void {
        if (self.ctx.db == null) {
            std.debug.print("DB is null", .{});
        }

        const db = self.ctx.db.*;

        // try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Alice"});

        const sql = "INSERT INTO messages (message, message_type, user_id, created_at) VALUES (?, ?, ?, ?)";
        const sqlArgs = &.{ response.content, agent.MessageType.user.toStr(), self.ctx.user_id, self.ctx.created_at };
        try db.exec(self.allocator, sql, sqlArgs);
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
