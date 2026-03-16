const std = @import("std");
const globals = @import("../globals.zig");
const tui_text = @import("tui-text");
const utils = @import("../helpers/utils.zig");

/// Tool result structure
pub const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    result: []const u8,
};

/// Extract tool results from XML response
pub fn extractToolResults(allocator: std.mem.Allocator, xml: []const u8) !std.ArrayList(ToolResult) {
    var results = std.ArrayList(ToolResult).empty;
    errdefer results.deinit(allocator);
    var pos: usize = 0;
    while (pos < xml.len) {
        const tool_result_start = std.mem.indexOfPos(u8, xml, pos, "<tool_result>") orelse break;
        const tool_result_end = std.mem.indexOfPos(u8, xml, tool_result_start, "</tool_result>") orelse break;
        const tool_result_block = xml[tool_result_start .. tool_result_end + "</tool_result>".len];
        pos = tool_result_end + "</tool_result>".len;
        const id = if (utils.extractTag(tool_result_block, "tool_call_id")) |v| v else "";
        const name = if (utils.extractTag(tool_result_block, "tool_name")) |v| v else "";
        const result = if (utils.extractTag(tool_result_block, "result")) |v| v else "";
        if (id.len > 0) {
            try results.append(allocator, .{ .id = id, .name = name, .result = result });
        }
    }
    return results;
}

/// Display tool result based on tool name
pub fn displayToolResultByName(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
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
    }
    // Note: search and read_file are commented out in original code
}

/// Display bash command result
pub fn displayBashResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    const std_out = std.mem.trim(u8, utils.extractTag(result_xml, "stdout") orelse "", &std.ascii.whitespace);
    const cmd = utils.extractTag(result_xml, "command");
    if (std.mem.eql(u8, std_out, "")) return;
    const stderr = utils.extractTag(result_xml, "stderr");
    const truncated = std_out.len > max_result_len;
    const display = if (truncated) std_out[0..max_result_len] else std_out;
    const is_error = if (stderr) |ec| std.mem.eql(u8, ec, "0") else false;
    const color = if (is_error) "\x1b[31m" else "";
    if (cmd) |c| {
        tui_text.print(globals.crlf ++ globals.erase_line ++ "[{s}] $ {s}\n", .{ tool_name, c });
    } else {
        tui_text.print(globals.crlf ++ globals.erase_line ++ "[{s}]\n", .{tool_name});
    }
    var lines = std.mem.splitScalar(u8, display, '\n');
    while (lines.next()) |line| {
        tui_text.print("{s}  {s}{s}\n", .{ color, line, if (is_error) globals.reset else "" });
    }
    if (truncated) tui_text.print("  {s}[truncated...]{s}\n", .{ globals.cyan, globals.reset });
}

/// Display search result
pub fn displaySearchResult(result_xml: []const u8, tool_name: []const u8, max_result_len: usize) void {
    _ = max_result_len;
    const results = utils.extractTag(result_xml, "results") orelse "";
    if (std.mem.eql(u8, results, "")) return;
    tui_text.print("\r\x1b[2K\n{s}[{s}]{s}\n", .{ globals.cyan, tool_name, globals.reset });
    var remaining = results;
    var total_shown: usize = 0;
    while (total_shown < 20) {
        const match_start = std.mem.indexOf(u8, remaining, "<m>") orelse break;
        const match_end = std.mem.indexOf(u8, remaining, "</m>") orelse break;
        const match_block = remaining[match_start .. match_end + "</m>".len];
        remaining = remaining[match_end + "</m>".len ..];
        const file = utils.extractTag(match_block, "f") orelse "";
        const line_num = utils.extractTag(match_block, "l") orelse "0";
        const snippet = utils.extractTag(match_block, "s") orelse "";
        tui_text.print("  {s}:{s}:{s}\n", .{ file, line_num, snippet });
        total_shown += 1;
    }
    if (std.mem.indexOf(u8, remaining, "<m>") != null) {
        tui_text.print("  {s}[more matches...]{s}\n", .{ globals.cyan, globals.reset });
    }
}

/// Display read_file result
pub fn displayReadFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const content = utils.extractTag(result_xml, "content") orelse "";
    const total_lines = utils.extractTag(result_xml, "total_lines") orelse "?";
    const start_line = utils.extractTag(result_xml, "start_line") orelse "0";
    const end_line = utils.extractTag(result_xml, "end_line") orelse "?";
    if (std.mem.eql(u8, content, "")) return;
    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} lines {s}-{s}/{s}\n", .{ globals.cyan, tool_name, globals.reset, start_line, end_line, total_lines });
    const max_lines: usize = 20;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (count >= max_lines) {
            tui_text.print("  {s}[...]{s}\n", .{ globals.cyan, globals.reset });
            break;
        }
        tui_text.print("  {s}\n", .{line});
        count += 1;
    }
}

/// Display write_file result
pub fn displayWriteFileResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extractTag(result_xml, "path") orelse "";
    const bytes_written = utils.extractTag(result_xml, "bytes_written") orelse "0";
    const lines_written = utils.extractTag(result_xml, "lines_written") orelse "0";
    if (std.mem.eql(u8, path, "")) return;
    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} wrote {s} bytes ({s} lines) → {s}\n", .{ globals.cyan, tool_name, globals.reset, bytes_written, lines_written, path });
    if (utils.extractTag(result_xml, "before")) |before| {
        if (!std.mem.eql(u8, before, "")) tui_text.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", globals.reset, before });
    }
    if (utils.extractTag(result_xml, "after")) |after| {
        if (!std.mem.eql(u8, after, "")) tui_text.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", globals.reset, after });
    }
}

/// Display text_replace result
pub fn displayTextReplaceResult(result_xml: []const u8, tool_name: []const u8) void {
    const path = utils.extractTag(result_xml, "path") orelse "";
    const replaced_at_byte = utils.extractTag(result_xml, "replaced_at_byte") orelse "?";
    if (std.mem.eql(u8, path, "")) return;
    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} replaced at byte {s} → {s}\n", .{ globals.cyan, tool_name, globals.reset, replaced_at_byte, path });
    if (utils.extractTag(result_xml, "old_str")) |old_str| {
        if (!std.mem.eql(u8, old_str, "")) tui_text.print("  {s}[-]{s} {s}\n", .{ "\x1b[31m", globals.reset, old_str });
    }
    if (utils.extractTag(result_xml, "new_str")) |new_str| {
        if (!std.mem.eql(u8, new_str, "")) tui_text.print("  {s}[+]{s} {s}\n", .{ "\x1b[32m", globals.reset, new_str });
    }
}

/// Display get_skill result
pub fn displaySkillResult(result_xml: []const u8, tool_name: []const u8) void {
    const skill_name = utils.extractTag(result_xml, "skill_name") orelse "";
    const content = utils.extractTag(result_xml, "content") orelse "";
    const loaded = utils.extractTag(result_xml, "loaded") orelse "false";
    const error_msg = utils.extractTag(result_xml, "error");

    if (skill_name.len == 0) return;

    // Header with skill name and status
    const loaded_status = if (std.mem.eql(u8, loaded, "true"))
        "\x1b[32m✓\x1b[0m"
    else
        "\x1b[31m✗\x1b[0m";

    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} {s} {s}\n", .{ globals.cyan, tool_name, globals.reset, loaded_status, skill_name });

    // Display error if present
    if (error_msg) |err| {
        if (err.len > 0) {
            tui_text.print("  \x1b[31mError: {s}\x1b[0m\n", .{err});
            // Show available skills if present
            if (utils.extractTag(result_xml, "available_skills")) |available| {
                if (available.len > 0) {
                    tui_text.print("  \x1b[90mAvailable skills:\x1b[0m\n", .{});
                    var pos: usize = 0;
                    while (pos < available.len) {
                        const skill_start = std.mem.indexOfPos(u8, available, pos, "<skill>") orelse break;
                        const skill_end = std.mem.indexOfPos(u8, available, skill_start, "</skill>") orelse break;
                        const skill_name_inner = available[skill_start + "<skill>".len .. skill_end];
                        pos = skill_end + "</skill>".len;
                        tui_text.print("    \x1b[32m•\x1b[0m {s}\n", .{skill_name_inner});
                    }
                }
            }
            return;
        }
    }

    // Display skill content with proper formatting
    if (content.len > 0) {
        tui_text.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});

        // Show first few lines of content (preview)
        const max_preview_lines: usize = 15;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;

        while (lines.next()) |line| {
            if (count >= max_preview_lines) {
                tui_text.print("  \x1b[90m... (more lines)\x1b[0m\n", .{});
                break;
            }
            // Truncate long lines
            const display_line = if (line.len > 70) line[0..70] else line;
            tui_text.print("  {s}\n", .{display_line});
            count += 1;
        }

        tui_text.print("  \x1b[90m───────────────────────────────\x1b[0m\n", .{});
    }
}

/// Display list_skills result (JSON parsing)
pub fn displayListSkillsResult(result_json: []const u8, tool_name: []const u8) void {
    // Parse JSON array of skills
    const skills_start = std.mem.indexOf(u8, result_json, "[") orelse {
        tui_text.print("\r\x1b[2K\n{s}[{s}]{s} No skills available\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    };
    const skills_end = std.mem.lastIndexOf(u8, result_json, "]") orelse result_json.len;
    const skills_array = result_json[skills_start .. skills_end + 1];

    if (skills_array.len <= 2) { // Empty array "[]"
        tui_text.print("\r\x1b[2K\n{s}[{s}]{s} No skills available\n", .{ globals.cyan, tool_name, globals.reset });
        return;
    }

    tui_text.print("\r\x1b[2K\n{s}[{s}]{s} Available skills:\n", .{ globals.cyan, tool_name, globals.reset });

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
            tui_text.print("  \x1b[32m•\x1b[0m {s}", .{name});
            if (desc.len > 0) {
                // Truncate description if too long
                const short_desc = if (desc.len > 50) desc[0..50] else desc;
                tui_text.print(" \x1b[90m- {s}...\x1b[0m", .{short_desc});
            }
            tui_text.print("\n", .{});
        }
    }

    if (count == 0) {
        tui_text.print("  \x1b[90m(no skills found)\x1b[0m\n", .{});
    }
}
