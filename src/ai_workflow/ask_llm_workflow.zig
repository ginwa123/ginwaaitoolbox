const std = @import("std");
const agent = @import("../modules/agent/agent.zig");

pub const AskLLMWorkflow = struct {
    allocator: std.mem.Allocator,
    agent: agent.Agent,

    pub fn init(allocator: std.mem.Allocator) AskLLMWorkflow {
        return AskLLMWorkflow{
            .allocator = allocator,
            .agent = agent.Agent.init(allocator) catch unreachable,
        };
    }

    pub fn run(self: *AskLLMWorkflow) !void {
        _ = self;
    }

    pub fn deinit(self: *AskLLMWorkflow) void {
        _ = self;
    }
};
