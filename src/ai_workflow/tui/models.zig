const sqlite = @import("nalarcore").sqlite;
const config = @import("nalarcore").config;
const logger = @import("nalarcore").logger;
const nalar_mod = @import("nalarcore");
const std = @import("std");
const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;

pub const ContextIPCTui = struct {
    io: std.Io,
    db: *sqlite.SqliteBackend,
    llm_config: *const config.LlmConfig,
    logger: *logger.Logger,
    environment: ?*const std.process.Environ.Map,
    active_loops: *nalar_mod.ai_workflow.ActiveLoops,
};

pub const TUIHistory = struct {
    id: []const u8,
    session_id: []const u8,
    model: []const u8,
    created_at: []const u8,
    response_content: []const u8,
    finish_reason: []const u8,
    role: []const u8,
    tools: []const u8,
    reasoning_content: ?[]const u8 = null,
    agent: []const u8 = "Agent",
    session_name: []const u8 = "",
    loop_index: u32 = 0,
    tool_name: []const u8 = "",
    parent_session_id: ?[]const u8 = null,
    temperature: f32 = 0.2,
    is_thinking: bool = false,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    is_input: bool = false,
    is_output: bool = false,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,

    pub fn deinit(self: *TUIHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.model);
        allocator.free(self.created_at);
        allocator.free(self.response_content);
        allocator.free(self.finish_reason);
        allocator.free(self.role);
        allocator.free(self.tools);
        if (self.reasoning_content) |rc| allocator.free(rc);
        allocator.free(self.agent);
        allocator.free(self.session_name);
        allocator.free(self.tool_name);
        if (self.parent_session_id) |psi| allocator.free(psi);
        if (self.diffview_before) |dw| allocator.free(dw);
        if (self.diffview_after) |da| allocator.free(da);
    }
};

