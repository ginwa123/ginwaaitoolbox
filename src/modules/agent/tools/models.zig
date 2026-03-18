pub const BashInput = struct {
    command: []const u8,
    timeout: ?u32 = 30,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    stdin_data: ?[]const u8 = null, // optional stdin input, null = close stdin
    background: bool = false, // run in background using nohup
};

pub const ReadFileInput = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
    show_line_numbers: ?bool = null,
};

pub const ToolProperty = struct {
    name: []const u8,
    type: []const u8,
    description: []const u8,
};

pub const ToolParameters = struct {
    type: []const u8,
    properties: []const ToolProperty,
    required: []const []const u8,
};

pub const AgentToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,
};

pub const AgentTool = struct {
    type: []const u8,
    function: AgentToolFunction,
};

pub const BashResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
};

pub const BashOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
};

// LSP Definition Tool Types
pub const LspDefinitionInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
};

pub const LspDefinitionOutput = struct {
    file_path: []u8, // Absolute path to definition
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    found: bool, // true if definition found
};

// Re-export agent tools for convenience
pub const agents = @import("agents.zig");
pub const list_agents = @import("list_agents.zig");
pub const get_agent = @import("get_agent.zig");
pub const lsp_definition = @import("lsp_definition.zig");

pub const listAgentsTool = list_agents.listAgentsTool;
pub const getAgentTool = get_agent.getAgentTool;
pub const lspDefinitionTool = lsp_definition.lspDefinitionTool;
