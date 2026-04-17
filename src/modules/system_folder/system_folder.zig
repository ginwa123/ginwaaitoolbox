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
    pub fn getHomeDirectory(allocator: std.mem.Allocator) SystemFolderError![]u8 {
        const home = std.posix.getenv("HOME") orelse {
            return SystemFolderError.HomeNotFound;
        };
        return allocator.dupe(u8, home);
    }
    
    /// Get the current working directory
    pub fn getCurrentWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
        return std.process.getCwdAlloc(allocator);
    }
    
    /// Get relative path from home for current working directory
    pub fn getCwdRelativeToHome(allocator: std.mem.Allocator) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator);
        defer allocator.free(home);
        
        const cwd = try getCurrentWorkingDirectory(allocator);
        defer allocator.free(cwd);
        
        return getRelativePathFromHome(allocator, cwd, home);
    }

    /// Resolve a relative path to absolute path (relative to home)
    pub fn resolvePath(allocator: std.mem.Allocator, relative_path: []const u8) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator);
        defer allocator.free(home);

        // If path starts with /, it's relative to home
        if (std.mem.startsWith(u8, relative_path, "/")) {
            const subpath = relative_path[1..];
            if (subpath.len == 0) {
                return allocator.dupe(u8, home);
            }
            return std.fs.path.join(allocator, &.{ home, subpath });
        }

        // Otherwise treat as absolute path
        return allocator.dupe(u8, relative_path);
    }

    /// List directory contents
    pub fn listDirectory(allocator: std.mem.Allocator, dir_path: []const u8) SystemFolderError![]FolderEntry {
        var dir = std.fs.openDirAbsolute(dir_path, .{
            .iterate = true,
        }) catch |err| {
            switch (err) {
                error.FileNotFound => return SystemFolderError.InvalidPath,
                error.AccessDenied => return SystemFolderError.AccessDenied,
                else => return SystemFolderError.OutOfMemory,
            }
        };
        defer dir.close();

        var entries = std.ArrayList(FolderEntry).empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            entries.deinit(allocator);
        }

        var walker = dir.walk(allocator) catch return SystemFolderError.OutOfMemory;
        defer walker.deinit();

        // Skip the first entry (the directory itself)
        _ = walker.next() catch {};

        while (true) {
            const entry_opt = walker.next() catch break;
            const entry = entry_opt orelse break;
            if (entry.kind == .directory or entry.kind == .file) {
                const name = try allocator.dupe(u8, entry.basename);
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.basename });
                const is_dir = entry.kind == .directory;
                const is_link = entry.kind == .sym_link;

                try entries.append(allocator, FolderEntry{
                    .name = name,
                    .path = full_path,
                    .is_directory = is_dir,
                    .is_symlink = is_link,
                });
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

        return try entries.toOwnedSlice(allocator);
    }

    /// Get parent directory path
    pub fn getParentPath(allocator: std.mem.Allocator, dir_path: []const u8) SystemFolderError!?[]u8 {
        const home = try getHomeDirectory(allocator);
        defer allocator.free(home);

        // Don't go above home
        if (std.mem.eql(u8, dir_path, home)) {
            return null;
        }

        const parent = std.fs.path.dirname(dir_path) orelse return null;
        return try allocator.dupe(u8, parent);
    }
};
