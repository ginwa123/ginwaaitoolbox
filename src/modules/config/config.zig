const std = @import("std");
const builtin = @import("builtin");
const json = std.json;

/// LLM configuration loaded from JSON file
pub const LlmConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    model_compaction_size_kb: usize,
    mcpServers: ?std.json.Value,

    /// Errors that can occur during config loading
    pub const LoadError = error{
        ConfigFileNotFound,
        ConfigFileReadError,
        InvalidJson,
        MissingRequiredField,
        OutOfMemory,
        HomeNotFound,
        ConfigDirNotFound,
    };

    /// Inner struct for JSON parsing (without allocator field)
    const LlmConfigJson = struct {
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        model_compaction_size_kb: usize = 100,
        mcpServers: ?std.json.Value = null,
    };

    /// Load config from JSON file
    /// If path is null, uses platform-specific default path
    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) LoadError!LlmConfig {
        const config_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try getDefaultConfigPath(allocator);
        defer allocator.free(config_path);

        // Read file
        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            std.log.err("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
            return error.ConfigFileNotFound;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            std.log.err("Failed to read config file: {s}", .{@errorName(err)});
            return error.ConfigFileReadError;
        };
        defer allocator.free(content);

        // Parse JSON
        const parsed = json.parseFromSlice(LlmConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse JSON config: {s}", .{@errorName(err)});
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const config_json = parsed.value;

        // Build LlmConfig with owned strings
        var config = LlmConfig{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config_json.api_key),
            .model = try allocator.dupe(u8, config_json.model),
            .base_url = try allocator.dupe(u8, config_json.base_url),
            .model_compaction_size_kb = config_json.model_compaction_size_kb,
            .mcpServers = null,
        };

        // Clone mcpServers if present
        if (config_json.mcpServers) |mcp| {
            // Re-serialize and re-parse to get an owned copy
            var mcp_str: std.ArrayList(u8) = .empty;
            defer mcp_str.deinit(allocator);
            
            // Use std.json.fmt for serialization
            var aw: std.io.Writer.Allocating = .init(allocator);
            aw.writer.print("{f}", .{std.json.fmt(mcp, .{})}) catch |err| {
                std.log.err("Failed to serialize mcpServers: {s}", .{@errorName(err)});
                return error.ConfigFileReadError;
            };
            const mcp_str_owned = aw.toOwnedSlice() catch |err| {
                std.log.err("Failed to get owned slice: {s}", .{@errorName(err)});
                return error.OutOfMemory;
            };
            defer allocator.free(mcp_str_owned);
            
            const reparsed = json.parseFromSlice(json.Value, allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("Failed to parse mcpServers: {s}", .{@errorName(err)});
                return error.InvalidJson;
            };
            config.mcpServers = reparsed.value;
        }

        return config;
    }

    /// Free all allocated memory
    pub fn deinit(self: *LlmConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);
        // mcpServers is owned by the parser that created it, no explicit deinit needed
        // The memory will be freed when the arena is reset
    }

    /// Validate required fields are present
    pub fn validate(self: *const LlmConfig) LoadError!void {
        if (self.api_key.len == 0) {
            std.log.err("Missing required field: api_key", .{});
            return error.MissingRequiredField;
        }
        if (self.model.len == 0) {
            std.log.err("Missing required field: model", .{});
            return error.MissingRequiredField;
        }
        if (self.base_url.len == 0) {
            std.log.err("Missing required field: base_url", .{});
            return error.MissingRequiredField;
        }
    }
};

/// Get platform-specific default config directory path
/// Caller owns returned memory
pub fn getDefaultConfigDir(allocator: std.mem.Allocator) LlmConfig.LoadError![]const u8 {
    const app_name = "zigginagentic";

    switch (builtin.os.tag) {
        .windows => {
            const appdata = std.posix.getenv("APPDATA") orelse {
                std.log.err("APPDATA environment variable not set", .{});
                return error.ConfigDirNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, app_name });
        },
        .macos => {
            const home = std.posix.getenv("HOME") orelse {
                std.log.err("HOME environment variable not set", .{});
                return error.HomeNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{
                home, "Library", "Application Support", app_name,
            });
        },
        else => { // Linux, FreeBSD, etc.
            // XDG_CONFIG_HOME or default to ~/.config
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_config| {
                return std.fs.path.join(allocator, &[_][]const u8{ xdg_config, app_name });
            }
            const home = std.posix.getenv("HOME") orelse {
                std.log.err("HOME environment variable not set", .{});
                return error.HomeNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", app_name });
        },
    }
}

/// Get full path to config.json
/// Caller owns returned memory
pub fn getDefaultConfigPath(allocator: std.mem.Allocator) LlmConfig.LoadError![]const u8 {
    const config_dir = try getDefaultConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
}

/// Convenience function for default config.json path
pub fn loadDefault(allocator: std.mem.Allocator) LlmConfig.LoadError!LlmConfig {
    return LlmConfig.init(allocator, null);
}

test {
    _ = @import("config_test.zig");
}
