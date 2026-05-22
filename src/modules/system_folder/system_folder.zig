//! System folder path utilities
//! 
//! Provides utilities for resolving paths relative to home directory.

const std = @import("std");

/// Error set for system folder operations
pub const SystemFolderError = error{
    HomeNotFound,
    OutOfMemory,
    InvalidPath,
    AccessDenied,
    NotDirectory,
};

/// Directory entry for folder listing
pub const FolderEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

/// Namespace containing system folder utilities
pub const SystemFolder = struct {
    /// Get the relative path from home directory
    /// 
    /// If `full_path` starts with `home`, returns the portion after home.
    /// Otherwise, returns the original `full_path` unchanged.
    /// 
    /// Returns "/" if path equals home exactly.
    pub fn getRelativePathFromHome(allocator: std.mem.Allocator, full_path: []const u8, home: []const u8) SystemFolderError![]u8 {
        // Normalize home path (remove trailing slash)
        const normalized_home = if (std.mem.endsWith(u8, home, "/"))
            home[0..home.len-1]
        else
            home;
        
        // Normalize full_path to remove trailing slash
        const normalized_path = if (std.mem.endsWith(u8, full_path, "/"))
            full_path[0..full_path.len-1]
        else
            full_path;
        
        // Check if full_path starts with home
        if (!std.mem.startsWith(u8, normalized_path, normalized_home)) {
            // Path doesn't start with home, return absolute path unchanged
            return allocator.dupe(u8, full_path);
        }
        
        // Check if path equals home exactly
        const after_home = normalized_path[normalized_home.len..];
        
        if (after_home.len == 0) {
            // Path equals home exactly
            return allocator.dupe(u8, "/");
        }
        
        // Remove leading slash from the remainder
        const remainder = if (std.mem.startsWith(u8, after_home, "/"))
            after_home[1..]
        else
            after_home;
        
        // Build result with leading slash
        const result = try std.fmt.allocPrint(allocator, "/{s}", .{remainder});
        return result;
    }
    
    /// Get home directory from environment
    pub fn getHomeDirectory(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const env = environment orelse return SystemFolderError.HomeNotFound;
        const home = env.get("HOME") orelse {
            return SystemFolderError.HomeNotFound;
        };
        return allocator.dupe(u8, home);
    }
    
    /// Get the current working directory
    pub fn getCurrentWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
        return std.process.getCwdAlloc(allocator);
    }
    
    /// Get relative path from home for current working directory
    pub fn getCwdRelativeToHome(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        const cwd = try getCurrentWorkingDirectory(allocator);
        defer allocator.free(cwd);

        return getRelativePathFromHome(allocator, cwd, home);
    }

    /// Resolve a relative path to absolute path (relative to home)
    pub fn resolvePath(allocator: std.mem.Allocator, relative_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Check if path already starts with home directory (absolute path)
        if (std.mem.startsWith(u8, relative_path, home)) {
            return allocator.dupe(u8, relative_path);
        }

        // If path starts with /, it's an absolute Unix path - return as-is
        if (std.mem.startsWith(u8, relative_path, "/")) {
            return allocator.dupe(u8, relative_path);
        }

        // Otherwise treat as absolute path
        return allocator.dupe(u8, relative_path);
    }

    /// List directory contents (first level only)
    pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) SystemFolderError![]FolderEntry {
        var entries = std.ArrayList(FolderEntry).empty;
        errdefer entries.deinit(allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            return SystemFolderError.InvalidPath;
        };
        defer std.Io.Dir.close(dir, io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const name = entry.name;
            if (name.len == 0) break;

            // Skip hidden files/folders (starting with .)
            if (name.len > 0 and name[0] == '.') continue;

            const is_dir = entry.kind == .directory;
            const is_link = entry.kind == .sym_link;
            const is_file = entry.kind == .file;

            if (is_dir or is_file) {
                const entry_name = allocator.dupe(u8, name) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch {
                    allocator.free(entry_name);
                    continue;
                };

                // Check if path is gitignored (use -C to set working directory)
                const git_result = std.process.run(allocator, io, .{
                    .argv = &.{ "git", "-C", dir_path, "check-ignore", name },
                }) catch continue;
                if (git_result.term.exited == 0) {
                    // Path is gitignored, skip it
                    allocator.free(entry_name);
                    allocator.free(full_path);
                    continue;
                }

                entries.append(allocator, FolderEntry{
                    .name = entry_name,
                    .path = full_path,
                    .is_directory = is_dir,
                    .is_symlink = is_link,
                }) catch continue;
            }
        }

        // Sort: directories first, then files, alphabetically
        std.mem.sort(FolderEntry, entries.items, {}, struct {
            fn less(_: void, a: FolderEntry, b: FolderEntry) bool {
                if (a.is_directory != b.is_directory) {
                    return a.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);

        return entries.toOwnedSlice(allocator);
    }

    /// Get parent directory path
    pub fn getParentPath(allocator: std.mem.Allocator, dir_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError!?[]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Don't go above home
        if (std.mem.eql(u8, dir_path, home)) {
            return null;
        }

        const parent = std.fs.path.dirname(dir_path) orelse return null;
        return try allocator.dupe(u8, parent);
    }
};
