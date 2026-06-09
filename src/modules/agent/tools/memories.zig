const std = @import("std");

/// App name for config directory. Matches skills.zig and agents.zig.
pub const APP_NAME = "nalar";

/// Subdirectory name under the per-app config folder.
pub const MEMORIES_DIR = "memories";

/// Subdirectory name under the per-project local config folder.
/// Mirrors `LOCAL_SKILLS_DIR = ".nalar/skills"` in tools/skills.zig.
pub const LOCAL_MEMORIES_DIR = ".nalar/memories";

/// Bytes scanned from the start of a memory file when looking for the
/// title (first H1). First H1s almost always live in the first line, but
/// we allow a generous buffer for files that put the H1 after some prose.
const TITLE_SCAN_LIMIT: usize = 4096;

/// One memory file. All string fields are allocator-owned and must be
/// freed via `freeMemoriesList`.
pub const MemoryInfo = struct {
    /// Filename including the .md extension (e.g. "user-preferences.md").
    name: []const u8,
    /// Title extracted from the first H1 line, or the filename stem
    /// (without .md) if no H1 is present.
    title: []const u8,
    /// Absolute path to the memory file.
    path: []const u8,
    /// File size in bytes.
    size: u64,
};

/// Get the global memories directory path using XDG standards.
/// Linux: $XDG_CONFIG_HOME/nalar/memories/  (or ~/.config/nalar/memories/)
/// macOS: $HOME/Library/Application Support/nalar/memories/
/// Windows: %APPDATA%/nalar/memories/
///
/// Returns an allocated string the caller must free, or null if neither
/// XDG_CONFIG_HOME nor HOME is set in the environment.
pub fn get_global_memories_path(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ?[]const u8 {
    if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
        return std.fs.path.join(allocator, &[_][]const u8{
            xdg_config,
            APP_NAME,
            MEMORIES_DIR,
        }) catch null;
    }

    if (environment.get("HOME")) |home| {
        return std.fs.path.join(allocator, &[_][]const u8{
            home,
            ".config",
            APP_NAME,
            MEMORIES_DIR,
        }) catch null;
    }

    return null;
}

/// Get the local memories directory path for a specific cwd.
///
/// Returns an allocated `<cwd>/.nalar/memories` (no realpath resolution —
/// caller is responsible for passing an absolute cwd, which
/// `buildMessages` already guarantees via `realPathFileAlloc`).
///
/// Returns `null` when:
///   - `cwd` is empty (no project context to scope against)
///   - the path join fails (alloc failure)
///
/// Mirrors `get_local_skills_path_for_dir` in tools/skills.zig so the
/// "local config" convention is consistent across skills and memories.
pub fn get_local_memories_path_for_dir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ?[]const u8 {
    if (cwd.len == 0) return null;
    return std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_MEMORIES_DIR,
    }) catch null;
}

/// List all .md memory files in the global memories directory.
///
/// Returns a slice of `MemoryInfo`. Returns an empty slice (not null) when:
///   - the environment is missing
///   - the memories directory does not exist (first-run case)
///   - the directory exists but contains no .md files
///
/// **No size cap.** Every `.md` file is listed regardless of size, and
/// `listAllMemories` reads the full content of each file to extract the
/// title. The de facto limit is the LLM's context window for callers
/// that feed the results into a prompt.
///
/// All string fields in the returned slice are allocator-owned. The caller
/// must free them with `freeMemoriesList`. Memory ownership is transferred
/// on return; the caller does NOT need to free individual fields on error
/// because we use errdefer internally.
pub fn listAllMemories(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) []MemoryInfo {
    const dir_path = get_global_memories_path(allocator, environment) orelse return &.{};
    defer allocator.free(dir_path);

    // Open the memories directory. Missing directory is NOT an error —
    // it just means the user has not created any memories yet.
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer std.Io.Dir.close(dir, io);

    var list: std.ArrayList(MemoryInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.title);
            allocator.free(item.path);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only consider regular files (skip subdirectories, symlinks, etc.)
        if (entry.kind != .file) continue;

        // Only consider .md files. Memories are markdown by design.
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Build absolute path. `std.fs.path.join` may fail on bad input —
        // skip this file in that case.
        const full_path = std.fs.path.join(allocator, &[_][]const u8{
            dir_path,
            entry.name,
        }) catch continue;

        // Open the file to read metadata and a prefix for the title.
        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(full_path);
            continue;
        };

        // Read the full file to scan for the first H1. No size cap — every
        // memory is loaded in full. The de facto limit is the LLM context
        // window for downstream callers; we trust the user to keep memories
        // reasonable. Pattern matches read_file.zig / get_skill.zig which
        // also use maxInt(usize) to read the entire file.
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        // Extract title from first H1, or fall back to filename stem.
        const title = extractTitle(allocator, entry.name, content) catch {
            allocator.free(full_path);
            continue;
        };

        // Own a copy of the filename for the MemoryInfo.
        const name_copy = allocator.dupe(u8, entry.name) catch {
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };

        // Append to the list. On failure, free the strings we just allocated.
        // `errdefer` on the append block handles the error case cleanly.
        list.append(allocator, .{
            .name = name_copy,
            .title = title,
            .path = full_path,
            .size = stat.size,
        }) catch {
            allocator.free(name_copy);
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };
        // On success, the list now owns name_copy, title, and full_path.
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

/// List all .md memory files in a specific directory (no XDG resolution).
///
/// Returns a slice of `MemoryInfo` with the same ownership contract as
/// `listAllMemories` — every `MemoryInfo` has allocator-owned `name`,
/// `title`, and `path` fields, and the slice itself is allocator-owned.
/// Free with `freeMemoriesList` (shared with the global lister).
///
/// Returns an empty slice (not an error) when the directory does not
/// exist. This is the expected first-run behaviour, identical to
/// `listAllMemories`'s handling of a missing global dir.
///
/// **Body is intentionally a copy of the inner loop of `listAllMemories`.**
/// Refactoring to a single shared core would require lifting
/// `get_global_memories_path` to a `?[]const u8` parameter and threading
/// it through the call sites (`list_memory` tool, HTTP handler) — more
/// surgery than this feature warrants. Duplication is acceptable because
/// both call sites use the same `MemoryInfo` struct and the same
/// `extractTitle` helper.
pub fn listMemoriesInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) []MemoryInfo {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer std.Io.Dir.close(dir, io);

    var list: std.ArrayList(MemoryInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.title);
            allocator.free(item.path);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only consider regular files (skip subdirectories, symlinks, etc.)
        if (entry.kind != .file) continue;

        // Only consider .md files. Memories are markdown by design.
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Build full path. `std.fs.path.join` may fail on bad input —
        // skip this file in that case.
        const full_path = std.fs.path.join(allocator, &[_][]const u8{
            dir_path,
            entry.name,
        }) catch continue;

        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(full_path);
            continue;
        };

        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        const title = extractTitle(allocator, entry.name, content) catch {
            allocator.free(full_path);
            continue;
        };

        const name_copy = allocator.dupe(u8, entry.name) catch {
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };

        list.append(allocator, .{
            .name = name_copy,
            .title = title,
            .path = full_path,
            .size = stat.size,
        }) catch {
            allocator.free(name_copy);
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

/// Extract the title from memory file content.
///
/// Strategy:
///   1. Scan the first TITLE_SCAN_LIMIT bytes line by line.
///   2. Find the first line that starts with "# " (markdown H1).
///   3. Strip the leading "# " and surrounding whitespace; that's the title.
///   4. If no H1 is found, fall back to the filename stem (filename minus .md).
///
/// Returns an allocated string the caller owns.
fn extractTitle(
    allocator: std.mem.Allocator,
    filename: []const u8,
    content: []const u8,
) ![]u8 {
    const scan_limit = @min(content.len, TITLE_SCAN_LIMIT);
    var i: usize = 0;
    while (i < scan_limit) {
        // Find end of the current line.
        var line_end = i;
        while (line_end < scan_limit and content[line_end] != '\n') : (line_end += 1) {}
        const line = std.mem.trim(u8, content[i..line_end], " \t\r");

        // Markdown H1: starts with "# " (single hash followed by space).
        if (line.len >= 2 and line[0] == '#' and line[1] == ' ') {
            const rest = std.mem.trim(u8, line[2..], " \t\r");
            return allocator.dupe(u8, rest);
        }

        if (line_end >= scan_limit) break;
        i = line_end + 1;
    }

    // No H1 found — use filename stem (filename minus ".md").
    const stem = if (std.mem.endsWith(u8, filename, ".md"))
        filename[0 .. filename.len - 3]
    else
        filename;
    return allocator.dupe(u8, stem);
}

/// Free a `MemoryInfo` slice allocated by `listAllMemories`.
///
/// Frees every owned string and the backing slice itself. Safe to call
/// on an empty slice.
pub fn freeMemoriesList(allocator: std.mem.Allocator, list: []MemoryInfo) void {
    for (list) |item| {
        allocator.free(item.name);
        allocator.free(item.title);
        allocator.free(item.path);
    }
    allocator.free(list);
}
