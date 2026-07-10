const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;

pub const LLMHistory = struct {
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
    image_urls: ?[][]const u8 = null,
    tool_call_id: ?[]const u8 = null,

    pub fn deinit(self: *LLMHistory, allocator: std.mem.Allocator) void {
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
        if (self.image_urls) |iums| {
            for (iums) |img| allocator.free(img);
            allocator.free(iums);
        }
        if (self.tool_call_id) |tci| allocator.free(tci);
    }
};

pub const GetLLMHistoriesInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
};

pub fn getLLMHistories(
    obj: GetLLMHistoriesInput,
) ![]LLMHistory {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    var results: std.ArrayList(LLMHistory) = .empty;

    const sql =
        \\SELECT
        \\    h.id, h.session_id, h.model, h.created_at,
        \\    h.response_content, h.finish_reason,
        \\    COALESCE(h.role, 'assistant'),
        \\    COALESCE(h.tool_calls_json, ''),
        \\    COALESCE(h.reasoning_content, ''),
        \\    COALESCE(h.agent, 'Agent'),
        \\    COALESCE(s.name, ''),
        \\    COALESCE(h.loop_index, 0),
        \\    COALESCE(h.tool_name, ''),
        \\    COALESCE(h.parent_session_id, ''),
        \\    COALESCE(h.temperature, 0.2),
        \\    COALESCE(h.is_thinking, 0),
        \\    COALESCE(h.prompt_tokens, 0),
        \\    COALESCE(h.completion_tokens, 0),
        \\    COALESCE(h.total_tokens, 0),
        \\    COALESCE(h.is_input, 0),
        \\    COALESCE(h.is_output, 0),
        \\    COALESCE(h.diffview_before, ''),
        \\    COALESCE(h.diffview_after, ''),
        \\    COALESCE(h.image_url, ''),
        \\    COALESCE(h.tool_call_id, '')
        \\FROM llm_history h
        \\LEFT JOIN sessions s ON h.session_id = s.id
        \\WHERE h.session_id = ?
        \\AND (h.is_feed_to_llm = 1 OR h.is_feed_to_llm IS NULL)
        \\ORDER BY h.created_at ASC
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[13];
        const diffview_before_str = row.values[21];
        const diffview_after_str = row.values[22];
        const image_url_str = row.values[23];
        const history = LLMHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .agent = try allocator.dupe(u8, row.values[9]),
            .session_name = try allocator.dupe(u8, row.values[10]),
            .loop_index = std.fmt.parseInt(u32, row.values[11], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[14]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[15], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[16], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[17], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .is_input = parseRowBool(row.values[19]),
            .is_output = parseRowBool(row.values[20]),
            .diffview_before = if (diffview_before_str.len > 0) try allocator.dupe(u8, diffview_before_str) else null,
            .diffview_after = if (diffview_after_str.len > 0) try allocator.dupe(u8, diffview_after_str) else null,
            .image_urls = if (image_url_str.len > 0) blk: {
                var urls = std.ArrayList([]const u8).empty;
                errdefer {
                    for (urls.items) |u| allocator.free(u);
                    urls.deinit(allocator);
                }
                var iter = std.mem.splitScalar(u8, image_url_str, '|');
                while (iter.next()) |url| {
                    if (url.len > 0) {
                        try urls.append(allocator, try allocator.dupe(u8, url));
                    }
                }
                break :blk if (urls.items.len > 0) urls.items else null;
            } else null,
            .tool_call_id = if (row.values[24].len > 0) try allocator.dupe(u8, row.values[24]) else null,
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

fn parseRowBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '1';
}
