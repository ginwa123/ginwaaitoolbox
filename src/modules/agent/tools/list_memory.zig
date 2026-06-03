const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
pub const memories = @import("memories.zig");
const MemoryInfo = memories.MemoryInfo;

/// Wrapper struct used for JSON serialization of the memories list.
/// `std.json.Stringify.valueAlloc` reads field names as JSON keys, so
/// the output shape is `{"memories":[{...},{...}]}`.
pub const MemoriesListData = struct {
    memories: []const MemoryInfo,
};

/// Tool definition for `list_memory`.
///
/// This tool is intentionally parameter-less: memories live in a single
/// global config folder and there is no per-session or per-cwd variant.
/// The LLM is told (in the description) where the folder lives on each
/// platform so it can make sense of the returned paths.
pub const list_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_memory",
        .description = "List all available memory files. Memories are markdown "
            ++ "files stored in the global nalar config folder ("
            ++ "~/.config/nalar/memories/ on Linux, %APPDATA%/nalar/memories/ on "
            ++ "Windows). The listing returns each memory's filename, title "
            ++ "(from the first H1 line, or the filename stem if no H1 is "
            ++ "present), absolute path, and size in bytes. Use read_file "
            ++ "with the returned path to read a specific memory's contents. "
            ++ "This tool only lists memories — it does not create, modify, "
            ++ "or delete them.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// Escape XML special characters in `s`. Mirrors the helper in
/// list_skills.zig (duplicated locally to keep the two tools decoupled).
/// Returns an allocated string the caller must free.
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Serialize a `MemoryInfo` slice to XML for the AI agent tool output.
///
/// XML shape (mirrors list_skills.toXml for visual consistency):
///   <memories>
///     <memory>
///       <name>...</name>
///       <title>...</title>
///       <path>...</path>
///       <size>...</size>
///     </memory>
///     ...
///   </memories>
///
/// Caller owns the returned memory and must free it with `allocator.free()`.
pub fn toXml(allocator: std.mem.Allocator, list: []const MemoryInfo) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<memories>");

    for (list) |mem| {
        try xml.appendSlice(allocator, "<memory>");

        const escaped_name = try xmlEscape(allocator, mem.name);
        defer allocator.free(escaped_name);
        try xml.appendSlice(allocator, "<name>");
        try xml.appendSlice(allocator, escaped_name);
        try xml.appendSlice(allocator, "</name>");

        const escaped_title = try xmlEscape(allocator, mem.title);
        defer allocator.free(escaped_title);
        try xml.appendSlice(allocator, "<title>");
        try xml.appendSlice(allocator, escaped_title);
        try xml.appendSlice(allocator, "</title>");

        const escaped_path = try xmlEscape(allocator, mem.path);
        defer allocator.free(escaped_path);
        try xml.appendSlice(allocator, "<path>");
        try xml.appendSlice(allocator, escaped_path);
        try xml.appendSlice(allocator, "</path>");

        try xml.appendSlice(allocator, "<size>");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{mem.size}) catch "0";
        try xml.appendSlice(allocator, size_str);
        try xml.appendSlice(allocator, "</size>");

        try xml.appendSlice(allocator, "</memory>");
    }

    try xml.appendSlice(allocator, "</memories>");

    return try xml.toOwnedSlice(allocator);
}

/// Serialize a `MemoryInfo` slice to JSON for the HTTP endpoint.
///
/// Output shape: `{"memories":[{"name":"...","title":"...","path":"...","size":N}, ...]}`
///
/// Caller owns the returned memory and must free it with `allocator.free()`.
pub fn toJson(allocator: std.mem.Allocator, list: []const MemoryInfo) ![]const u8 {
    const data = MemoriesListData{ .memories = list };
    return std.json.Stringify.valueAlloc(allocator, data, .{});
}

/// Execute the `list_memory` tool. Returns an XML string for the LLM.
///
/// Returns `<memories><error>MissingEnvironment</error></memories>` when
/// the environment is not available (matches list_skills behavior).
///
/// Caller owns the returned memory and must free it with `allocator.free()`.
pub fn execute_list_memory(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    const env = environment orelse {
        return allocator.dupe(u8, "<memories><error>MissingEnvironment</error></memories>");
    };

    const list = memories.listAllMemories(allocator, io, env);
    defer memories.freeMemoriesList(allocator, list);

    return toXml(allocator, list);
}
