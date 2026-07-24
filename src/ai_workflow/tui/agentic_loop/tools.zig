const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const ActiveLoops = @import("../ActiveLoops.zig").ActiveLoops;

pub const all_agent_tools = @import("tools_equipped.zig").equips;
pub const wrapToolOutput = @import("tools_wrap_output.zig").wrapToolOutput;

const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

const AgentSaveInfo = struct {
    name: []const u8,
};

pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ActiveLoops,
    selected_profile_model: []const u8 = "",
    cwd_override: ?[]const u8 = null,
};

pub const ToolExecResult = struct {
    output: []const u8,
    output_allocated: bool = false,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,

    pub fn deinit(self: *const ToolExecResult, allocator: std.mem.Allocator) void {
        if (self.output_allocated) {
            allocator.free(self.output);
        }
    }
};
