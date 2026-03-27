const std = @import("std");
const globals = @import("../globals.zig");
const utils = @import("../helpers/utils.zig");

/// Tool result structure
pub const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    result: []const u8,
};

/// Extract tool results from XML response
pub fn extract_tool_results(allocator: std.mem.Allocator, xml: []const u8) !std.ArrayList(ToolResult) {
    var results = std.ArrayList(ToolResult).empty;
    errdefer results.deinit(allocator);
    var pos: usize = 0;
    while (pos < xml.len) {
        const tool_result_start = std.mem.indexOfPos(u8, xml, pos, "<tool_result>") orelse break;
        const tool_result_end = std.mem.indexOfPos(u8, xml, tool_result_start, "</tool_result>") orelse break;
        const tool_result_block = xml[tool_result_start .. tool_result_end + "</tool_result>".len];
        pos = tool_result_end + "</tool_result>".len;
        const id = if (utils.extract_tag(tool_result_block, "tool_call_id")) |v| v else "";
        const name = if (utils.extract_tag(tool_result_block, "tool_name")) |v| v else "";
        const result = if (utils.extract_tag(tool_result_block, "result")) |v| v else "";
        if (id.len > 0) {
            try results.append(allocator, .{ .id = id, .name = name, .result = result });
        }
    }
    return results;
}

/// Display tool result based on tool name
pub fn display_tool_result_by_name(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    if (std.mem.eql(u8, tool_name, "bash")) {
        displayBashResult(result_xml, tool_name, max_result_len);
    } else if (std.mem.eql(u8, tool_name, "write_file")) {
        displayWriteFileResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "text_replace")) {
        displayTextReplaceResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "get_skill")) {
        displaySkillResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "list_skills")) {
        displayListSkillsResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "search")) {
        displaySearchResult(result_xml, tool_name, max_result_len);
    } else if (std.mem.eql(u8, tool_name, "read_file")) {
        displayReadFileResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "lsp_definition")) {
        displayLspDefinitionResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "lsp_references")) {
        displayLspReferencesResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "lsp_hover")) {
        displayLspHoverResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "lsp_workspace_symbol")) {
        displayLspWorkspaceSymbolResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "lsp_document_symbol")) {
        displayLspDocumentSymbolResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "list_agents")) {
        displayListAgentsResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "get_agent")) {
        displayGetAgentResult(result_xml, tool_name);
    } else if (std.mem.eql(u8, tool_name, "spawn_sub_agent")) {
        displaySpawnSubAgentResult(result_xml, tool_name);
    } else {
        // Generic fallback for unknown tools
        displayGenericResult(result_xml, tool_name, max_result_len);
    }
}

/// Display bash command result
pub fn displayBashResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    const std_out = std.mem.trim(u8, utils.extract_tag(result_xml, "stdout") orelse "", &std.ascii.whitespace);
    const cmd = utils.extract_tag(result_xml, "command");
    if (std.mem.eql(u8, std_out, "")) return;
    const stderr = utils.extract_tag(result_xml, "stderr");
    const truncated = std_out.len > max_result_len;
    const display = if (truncated) std_out[0..max_result_len] else std_out;
    const is_error = if (stderr) |ec| std.mem.eql(u8, ec, "0") else false;
    const color = if (is_error) "\x1b[31m" else "";
    if (cmd) |c| {
        std.debug.print(globals.crlf ++ globals.erase_line ++ "[{s}] $ {s}\n", .{ tool_name, c });
    } else {
        std.debug.print(globals.crlf ++ globals.erase_line ++ "[{s}]\n", .{tool_name});
    }
    var lines = std.mem.splitScalar(u8, display, '\n');
    while (lines.next()) |line| {
        std.debug.print("{s}  {s}{s}\n", .{ color, line, if (is_error) globals.reset else "" });
    }
    if (truncated) std.debug.print("  {s}[truncated...]{s}\n", .{ globals.cyan, globals.reset });
}

/// Display search result
pub fn displaySearchResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    _ = max_result_len;
    const results = utils.extract_tag(result_xml, "results") orelse "";
    if (std.mem.eql(u8, results, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ globals.cyan, tool_name, globals.reset });
    var remaining = results;
    var total_shown: usize = 0;
    while (total_shown < 20) {
        const match_start = std.mem.indexOf(u8, remaining, "<m>") orelse break;
        const match_end = std.mem.indexOf(u8, remaining, "</m>") orelse break;
        const match_block = remaining[match_start .. match_end + "</m>".len];
        remaining = remaining[match_end + "</m>".len ..];
        const file = utils.extract_tag(match_block, "f") orelse "";
        const line_num = utils.extract_tag(match_block, "l") orelse "0";
        const snippet = utils.extract_tag(match_block, "s") orelse "";
        std.debug.print("  {s}:{s}:{s}\n", .{ file, line_num, snippet });
        total_shown += 1;
    }
    if (std.mem.indexOf(u8, remaining, "<m>") != null) {
        std.debug.print("  {s}[more matches...]{s}\n", .{ globals.cyan, globals.reset });
    }
}

/// Display read_file result
pub fn displayReadFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extract_tag(result_xml, "path") orelse "unknown";
    if (std.mem.eql(u8, path, "")) return;

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} {s}\n", .{
        globals.cyan,
        tool_name,
        globals.reset,
        path
    });
}

/// Display write_file result
pub fn displayWriteFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extract_tag(result_xml, "path") orelse "";
    const bytes_written = utils.extract_tag(result_xml, "bytes_written") orelse "0";
    const lines_written = utils.extract_tag(result_xml, "lines_written") orelse "0";
    if (std.mem.eql(u8, path, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} wrote {s} bytes ({s} lines) → {s}\n", .{ globals.cyan, tool_name, globals.reset, bytes_written, lines_written, path });
    if (utils.extract_tag(result_xml, "before")) |before| {
        if (!std.mem.eql(u8, before, "")) std.debug.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", globals.reset, before });
    }
    if (utils.extract_tag(result_xml, "after")) |after| {
        if (!std.mem.eql(u8, after, "")) std.debug.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", globals.reset, after });
    }
}

/// Display text_replace result
pub fn displayTextReplaceResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extract_tag(result_xml, "path") orelse "";
    const replaced_at_byte = utils.extract_tag(result_xml, "replaced_at_byte") orelse "?";
    if (std.mem.eql(u8, path, "")) return;
    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} replaced at byte {s} → {s}\n", .{ globals.cyan, tool_name, globals.reset, replaced_at_byte, path });
    if (utils.extract_tag(result_xml, "old_str")) |old_str| {
        if (!std.mem.eql(u8, old_str, "")) std.debug.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", globals.reset, old_str });
    }
    if (utils.extract_tag(result_xml, "new_str")) |new_str| {
        if (!std.mem.eql(u8, new_str, "")) std.debug.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", globals.reset, new_str });
    }
}

/// Display get_skill result
pub fn displaySkillResult(result_xml: []const u8, tool_name: []const u8) void {
    const skill_name = utils.extract_tag(result_xml, "skill_name") orelse "";
    const content = utils.extract_tag(result_xml, "content") orelse "";
    const loaded = utils.extract_tag(result_xml, "loaded") orelse "false";
    const error_msg = utils.extract_tag(result_xml, "error");

    if (skill_name.len == 0) return;

    // Header with skill name and status
    const loaded_status = if (std.mem.eql(u8, loaded, "true"))
        "\x1b[32m✓\x1b[0m"
    else
        "\x1b[31m✗\x1b[0m";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} {s} {s}\n", .{ globals.cyan, tool_name, globals.reset, loaded_status, skill_name });

    // Display error if present
    if (error_msg) |err| {
        if (err.len > 0) {
            std.debug.print("  \x1b[31mError: {s}\x1b[0m\n", .{err});
            // Show available skills if present
            if (utils.extract_tag(result_xml, "available_skills")) |available| {
                if (available.len > 0) {
                    std.debug.print("  \x1b[90mAvailable skills:\x1b[0m\n", .{});
                    var pos: usize = 0;
                    while (pos < available.len) {
                        const skill_start = std.mem.indexOfPos(u8, available, pos, "<skill>") orelse break;
                        const skill_end = std.mem.indexOfPos(u8, available, skill_start, "</skill>") orelse break;
                        const skill_name_inner = available[skill_start + "<skill>".len .. skill_end];
                        pos = skill_end + "</skill>".len;
                        std.debug.print("    \x1b[32m•\x1b[0m {s}\n", .{skill_name_inner});
                    }
                }
            }
            return;
        }
    }

    // Display skill content with proper formatting
    if (content.len > 0) {
        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});

        // Show first few lines of content (preview)
        const max_preview_lines: usize = 15;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;

        while (lines.next()) |line| {
            if (count >= max_preview_lines) {
                std.debug.print("  \x1b[90m... (more lines)\x1b[0m\n", .{});
                break;
            }
            // Truncate long lines
            const display_line = if (line.len > 70) line[0..70] else line;
            std.debug.print("  {s}\n", .{display_line});
            count += 1;
        }

        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});
    }
}

/// Display list_skills result (JSON parsing)
pub fn displayListSkillsResult(result_json: []const u8, tool_name: []const u8) void {
    // Parse JSON array of skills
    const skills_start = std.mem.indexOf(u8, result_json, "[") orelse {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} No skills available\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    };
    const skills_end = std.mem.lastIndexOf(u8, result_json, "]") orelse result_json.len;
    const skills_array = result_json[skills_start .. skills_end + 1];

    if (skills_array.len <= 2) { // Empty array "[]"
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} No skills available\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    }

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} Available skills:\n", .{ globals.cyan, tool_name, globals.reset });

    // Parse each skill object
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < skills_array.len) {
        const obj_start = std.mem.indexOfPos(u8, skills_array, pos, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, skills_array, obj_start, "}") orelse break;
        const obj = skills_array[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        // Extract name
        const name_key = std.mem.indexOf(u8, obj, "\"name\"") orelse continue;
        const name_start = std.mem.indexOfPos(u8, obj, name_key, "\"") orelse continue;
        const name_start2 = std.mem.indexOfPos(u8, obj, name_start + 1, "\"") orelse continue;
        const name_end = std.mem.indexOfPos(u8, obj, name_start2 + 1, "\"") orelse continue;
        const name = obj[name_start2 + 1 .. name_end];

        // Extract description
        const desc_key = std.mem.indexOf(u8, obj, "\"description\"") orelse continue;
        const desc_start = std.mem.indexOfPos(u8, obj, desc_key, "\"") orelse continue;
        const desc_start2 = std.mem.indexOfPos(u8, obj, desc_start + 1, "\"") orelse continue;
        const desc_end = std.mem.indexOfPos(u8, obj, desc_start2 + 1, "\"") orelse continue;
        const desc = obj[desc_start2 + 1 .. desc_end];

        if (name.len > 0) {
            count += 1;
            std.debug.print("  \x1b[32m•\x1b[0m {s}", .{name});
            if (desc.len > 0) {
                // Truncate description if too long
                const short_desc = if (desc.len > 50) desc[0..50] else desc;
                std.debug.print(" \x1b[90m- {s}...\x1b[0m", .{short_desc});
            }
            std.debug.print("\n", .{});
        }
    }

    if (count == 0) {
        std.debug.print("  \x1b[90m(no skills found)\x1b[0m\n", .{});
    }
}

// =============================================================================
// Agent Management Tool Displays
// =============================================================================

/// Display list_agents result
pub fn displayListAgentsResult(result_xml: []const u8, tool_name: []const u8) void {
    const agents_xml = utils.extract_tag(result_xml, "agents") orelse "";
    if (std.mem.eql(u8, agents_xml, "")) {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} No agents available\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    }

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} Available agents:\n", .{ globals.cyan, tool_name, globals.reset });

    var pos: usize = 0;
    var count: usize = 0;
    while (pos < agents_xml.len) {
        const agent_start = std.mem.indexOfPos(u8, agents_xml, pos, "<agent>") orelse break;
        const agent_end = std.mem.indexOfPos(u8, agents_xml, agent_start, "</agent>") orelse break;
        const agent_block = agents_xml[agent_start + "<agent>".len .. agent_end];
        pos = agent_end + "</agent>".len;

        const name = utils.extract_tag(agent_block, "name") orelse "";
        const desc = utils.extract_tag(agent_block, "description") orelse "";

        if (name.len > 0) {
            count += 1;
            std.debug.print("  \x1b[36m•\x1b[0m {s}", .{name});
            if (desc.len > 0) {
                const short_desc = if (desc.len > 50) desc[0..50] else desc;
                std.debug.print(" \x1b[90m- {s}...\x1b[0m", .{short_desc});
            }
            std.debug.print("\n", .{});
        }
    }

    if (count == 0) {
        std.debug.print("  \x1b[90m(no agents found)\x1b[0m\n", .{});
    }
}

/// Display get_agent result
pub fn displayGetAgentResult(result_xml: []const u8, tool_name: []const u8) void {
    const agent_name = utils.extract_tag(result_xml, "agent_name") orelse "";
    const content = utils.extract_tag(result_xml, "content") orelse "";
    const loaded = utils.extract_tag(result_xml, "loaded") orelse "false";
    const error_msg = utils.extract_tag(result_xml, "error");

    if (agent_name.len == 0 and content.len == 0) {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} No agent content\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    }

    const loaded_status = if (std.mem.eql(u8, loaded, "true"))
        "\x1b[32m✓\x1b[0m"
    else
        "\x1b[31m✗\x1b[0m";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} {s} {s}\n", .{ globals.cyan, tool_name, globals.reset, loaded_status, if (agent_name.len > 0) agent_name else "agent" });

    if (error_msg) |err| {
        if (err.len > 0) {
            std.debug.print("  \x1b[31mError: {s}\x1b[0m\n", .{err});
            return;
        }
    }

    if (content.len > 0) {
        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});
        const max_preview_lines: usize = 15;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (count >= max_preview_lines) {
                std.debug.print("  \x1b[90m... (more lines)\x1b[0m\n", .{});
                break;
            }
            const display_line = if (line.len > 70) line[0..70] else line;
            std.debug.print("  {s}\n", .{display_line});
            count += 1;
        }
        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});
    }
}

/// Display spawn_sub_agent result
pub fn displaySpawnSubAgentResult(result_xml: []const u8, tool_name: []const u8) void {
    const sub_agent_id = utils.extract_tag(result_xml, "sub_agent_id") orelse "";
    const status = utils.extract_tag(result_xml, "status") orelse "";
    const message = utils.extract_tag(result_xml, "message") orelse "";

    if (std.mem.eql(u8, sub_agent_id, "") and std.mem.eql(u8, message, "")) {
        std.debug.print("\r\x1b[2K\n{s}[{s}]{s} Sub-agent spawned\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    }

    const status_color: []const u8 = if (std.mem.eql(u8, status, "success") or std.mem.eql(u8, status, "running"))
        "\x1b[32m"
    else
        "\x1b[31m";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });
    if (sub_agent_id.len > 0) {
        std.debug.print("{s}{s}\x1b[0m", .{ status_color, sub_agent_id });
    }
    if (message.len > 0) {
        std.debug.print(" - {s}", .{message});
    }
    std.debug.print("\n", .{});
}

// =============================================================================
// LSP Tool Displays
// =============================================================================

/// Display lsp_definition result
pub fn displayLspDefinitionResult(result_xml: []const u8, tool_name: []const u8) void {
    const found = utils.extract_tag(result_xml, "found") orelse "false";
    const definitions = utils.extract_tag(result_xml, "definitions") orelse "";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });

    if (std.mem.eql(u8, found, "true")) {
        std.debug.print("\x1b[32m✓ Found definitions:\x1b[0m\n", .{});
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < definitions.len and count < 10) {
            const loc_start = std.mem.indexOfPos(u8, definitions, pos, "<loc>") orelse break;
            const loc_end = std.mem.indexOfPos(u8, definitions, loc_start, "</loc>") orelse break;
            const loc_block = definitions[loc_start + "<loc>".len .. loc_end];
            pos = loc_end + "</loc>".len;

            const file_path = utils.extract_tag(loc_block, "file_path") orelse "";
            const line = utils.extract_tag(loc_block, "line") orelse "0";
            const character = utils.extract_tag(loc_block, "character") orelse "0";

            std.debug.print("  \x1b[33m→\x1b[0m {s}:{s}:{s}\n", .{ file_path, line, character });
            count += 1;
        }
        if (std.mem.indexOfPos(u8, definitions, pos, "<loc>") != null) {
            std.debug.print("  \x1b[90m... (more definitions)\x1b[0m\n", .{});
        }
    } else {
        std.debug.print("\x1b[31m✗ No definition found\x1b[0m\n", .{});
    }
}

/// Display lsp_references result
pub fn displayLspReferencesResult(result_xml: []const u8, tool_name: []const u8) void {
    const found = utils.extract_tag(result_xml, "found") orelse "false";
    const references = utils.extract_tag(result_xml, "references") orelse "";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });

    if (std.mem.eql(u8, found, "true")) {
        std.debug.print("\x1b[32m✓ Found {d} references:\x1b[0m\n", .{
            @as(usize, @intCast(std.mem.count(u8, references, "<loc>")))});
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < references.len and count < 15) {
            const loc_start = std.mem.indexOfPos(u8, references, pos, "<loc>") orelse break;
            const loc_end = std.mem.indexOfPos(u8, references, loc_start, "</loc>") orelse break;
            const loc_block = references[loc_start + "<loc>".len .. loc_end];
            pos = loc_end + "</loc>".len;

            const file_path = utils.extract_tag(loc_block, "file_path") orelse "";
            const line = utils.extract_tag(loc_block, "line") orelse "0";

            std.debug.print("  \x1b[36m→\x1b[0m {s}:{s}\n", .{ file_path, line });
            count += 1;
        }
        if (std.mem.indexOfPos(u8, references, pos, "<loc>") != null) {
            std.debug.print("  \x1b[90m... (more references)\x1b[0m\n", .{});
        }
    } else {
        std.debug.print("\x1b[31m✗ No references found\x1b[0m\n", .{});
    }
}

/// Display lsp_hover result
pub fn displayLspHoverResult(result_xml: []const u8, tool_name: []const u8) void {
    const found = utils.extract_tag(result_xml, "found") orelse "false";
    const contents = utils.extract_tag(result_xml, "contents") orelse "";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });

    if (std.mem.eql(u8, found, "true") and contents.len > 0) {
        std.debug.print("\x1b[32m✓ Hover info:\x1b[0m\n", .{});
        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});

        // Parse markdown/code blocks
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var count: usize = 0;
        const max_lines: usize = 12;
        while (lines.next()) |line| {
            if (count >= max_lines) {
                std.debug.print("  \x1b[90m...\x1b[0m\n", .{});
                break;
            }
            const display_line = if (line.len > 80) line[0..80] else line;
            std.debug.print("  {s}\n", .{display_line});
            count += 1;
        }
        std.debug.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});
    } else {
        std.debug.print("\x1b[31m✗ No hover info found\x1b[0m\n", .{});
    }
}

/// Display lsp_workspace_symbol result
pub fn displayLspWorkspaceSymbolResult(result_xml: []const u8, tool_name: []const u8) void {
    const found = utils.extract_tag(result_xml, "found") orelse "false";
    const symbols = utils.extract_tag(result_xml, "symbols") orelse "";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });

    if (std.mem.eql(u8, found, "true")) {
        const total = std.mem.count(u8, symbols, "<symbol>");
        std.debug.print("\x1b[32m✓ Found {d} symbols:\x1b[0m\n", .{total});
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < symbols.len and count < 15) {
            const sym_start = std.mem.indexOfPos(u8, symbols, pos, "<symbol>") orelse break;
            const sym_end = std.mem.indexOfPos(u8, symbols, sym_start, "</symbol>") orelse break;
            const sym_block = symbols[sym_start + "<symbol>".len .. sym_end];
            pos = sym_end + "</symbol>".len;

            const name = utils.extract_tag(sym_block, "name") orelse "";
            const kind = utils.extract_tag(sym_block, "kind") orelse "";
            const file_path = utils.extract_tag(sym_block, "file_path") orelse "";
            const line = utils.extract_tag(sym_block, "line") orelse "0";

            const kind_icon: []const u8 = switch (std.fmt.parseInt(u32, kind, 10) catch 0) {
                1 => "\x1b[33m⚙\x1b[0m", // File
                2 => "\x1b[36m📦\x1b[0m", // Module
                3 => "\x1b[32m🏛\x1b[0m", // Namespace
                4 => "\x1b[34m✦\x1b[0m", // Package
                5 => "\x1b[35m📁\x1b[0m", // Class
                6 => "\x1b[31m◇\x1b[0m", // Method
                7 => "\x1b[32m▷\x1b[0m", // Property
                8 => "\x1b[36m≡\x1b[0m", // Field
                9 => "\x1b[33m⊢\x1b[0m", // Constructor
                10 => "\x1b[35m∋\x1b[0m", // Enum
                11 => "\x1b[34m◈\x1b[0m", // Interface
                12 => "\x1b[31m∫\x1b[0m", // Function
                13 => "\x1b[32mλ\x1b[0m", // Variable
                14 => "\x1b[33m⌁\x1b[0m", // Constant
                else => "\x1b[90m•\x1b[0m",
            };

            std.debug.print("  {s} {s} \x1b[90m{s}:{s}\x1b[0m\n", .{ kind_icon, name, file_path, line });
            count += 1;
        }
        if (std.mem.indexOfPos(u8, symbols, pos, "<symbol>") != null) {
            std.debug.print("  \x1b[90m... (more symbols)\x1b[0m\n", .{});
        }
    } else {
        std.debug.print("\x1b[31m✗ No symbols found\x1b[0m\n", .{});
    }
}

/// Display lsp_document_symbol result
pub fn displayLspDocumentSymbolResult(result_xml: []const u8, tool_name: []const u8) void {
    const found = utils.extract_tag(result_xml, "found") orelse "false";
    const symbols = utils.extract_tag(result_xml, "symbols") orelse "";

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s} ", .{ globals.cyan, tool_name, globals.reset });

    if (std.mem.eql(u8, found, "true")) {
        const total = std.mem.count(u8, symbols, "<symbol>");
        std.debug.print("\x1b[32m✓ Document symbols ({d}):\x1b[0m\n", .{total});

        // Simple tree display
        var pos: usize = 0;
        var count: usize = 0;
        while (pos < symbols.len and count < 20) {
            const sym_start = std.mem.indexOfPos(u8, symbols, pos, "<symbol>") orelse break;
            const sym_end = std.mem.indexOfPos(u8, symbols, sym_start, "</symbol>") orelse break;
            const sym_block = symbols[sym_start + "<symbol>".len .. sym_end];
            pos = sym_end + "</symbol>".len;

            const name = utils.extract_tag(sym_block, "name") orelse "";
            const kind = utils.extract_tag(sym_block, "kind") orelse "";
            const line = utils.extract_tag(sym_block, "line") orelse "0";

            const kind_color: []const u8 = switch (std.fmt.parseInt(u32, kind, 10) catch 0) {
                1 => "\x1b[33m", // File
                5 => "\x1b[35m", // Class
                6 => "\x1b[31m", // Method
                8 => "\x1b[36m", // Field
                12 => "\x1b[32m", // Function
                13 => "\x1b[34m", // Variable
                14 => "\x1b[33m", // Constant
                else => "\x1b[90m",
            };

            std.debug.print("  \x1b[90m{s}:\x1b[0m {s}{s}\x1b[0m\n", .{
                line,
                kind_color,
                name,
            });
            count += 1;
        }
        if (std.mem.indexOfPos(u8, symbols, pos, "<symbol>") != null) {
            std.debug.print("  \x1b[90m... (more symbols)\x1b[0m\n", .{});
        }
    } else {
        std.debug.print("\x1b[31m✗ No document symbols found\x1b[0m\n", .{});
    }
}

// =============================================================================
// Generic Fallback Display
// =============================================================================

/// Generic fallback for unknown tools
pub fn displayGenericResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    const result = utils.extract_tag(result_xml, "result") orelse result_xml;
    const truncated = result.len > max_result_len;
    const display = if (truncated) result[0..max_result_len] else result;

    std.debug.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ globals.cyan, tool_name, globals.reset });
    std.debug.print("  {s}\n", .{display});

    if (truncated) {
        std.debug.print("  {s}[truncated...]{s}\n", .{ globals.cyan, globals.reset });
    }
}
