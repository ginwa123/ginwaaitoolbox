const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;

pub const LlmConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    model_compaction_size_kb: usize,
    mcpServers: ?std.json.Value,

    pub const LoadError = error{
        ConfigFileNotFound,
        ConfigFileReadError,
        InvalidJson,
        MissingRequiredField,
        OutOfMemory,
        HomeNotFound,
        ConfigDirNotFound,
    };

    const LlmConfigJson = struct {
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        model_compaction_size_kb: usize = 100,
        mcpServers: ?std.json.Value = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8, environment: *std.process.Environ.Map) LoadError!LlmConfig {
        const config_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try getDefaultConfigPath(allocator, environment);
        defer allocator.free(config_path);


        const file = Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| {
            std.log.err("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
            return error.ConfigFileNotFound;
        };
        defer file.close(io);

        var read_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
            std.log.err("Failed to read config file: {s}", .{@errorName(err)});
            return error.ConfigFileReadError;
        };
        defer allocator.free(content);

        const parsed = json.parseFromSlice(LlmConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse JSON config: {s}", .{@errorName(err)});
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const config_json = parsed.value;

        var config = LlmConfig{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config_json.api_key),
            .model = try allocator.dupe(u8, config_json.model),
            .base_url = try allocator.dupe(u8, config_json.base_url),
            .model_compaction_size_kb = config_json.model_compaction_size_kb,
            .mcpServers = null,
        };

        if (config_json.mcpServers) |mcp| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(allocator, mcp, .{}) catch |err| {
                std.log.err("Failed to serialize mcpServers: {s}", .{@errorName(err)});
                return error.ConfigFileReadError;
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

    pub fn deinit(self: *LlmConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);
    }

    pub fn clone(self: *const LlmConfig) LoadError!LlmConfig {
        var config = LlmConfig{
            .allocator = self.allocator,
            .api_key = try self.allocator.dupe(u8, self.api_key),
            .model = try self.allocator.dupe(u8, self.model),
            .base_url = try self.allocator.dupe(u8, self.base_url),
            .model_compaction_size_kb = self.model_compaction_size_kb,
            .mcpServers = null,
        };
        errdefer {
            self.allocator.free(config.api_key);
            self.allocator.free(config.model);
            self.allocator.free(config.base_url);
        }

        if (self.mcpServers) |mcp| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(config.allocator, mcp, .{}) catch {
                self.allocator.free(config.api_key);
                self.allocator.free(config.model);
                self.allocator.free(config.base_url);
                return error.InvalidJson;
            };
            errdefer self.allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, config.allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch {
                self.allocator.free(config.api_key);
                self.allocator.free(config.model);
                self.allocator.free(config.base_url);
                return error.InvalidJson;
            };
            config.mcpServers = reparsed.value;
        }

        return config;
    }

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

pub fn getDefaultConfigDir(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const app_name = "nalar";

    switch (builtin.os.tag) {
        .windows => {
            const appdata = environment.get("APPDATA") orelse {
                std.log.err("APPDATA environment variable not set", .{});
                return error.ConfigDirNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, app_name });
        },
        .macos => {
            const home = environment.get("HOME") orelse {
                std.log.err("HOME environment variable not set", .{});
                return error.HomeNotFound;
            };
            return std.fs.path.join(allocator, &[_][]const u8{
                home, "Library", "Application Support", app_name,
            });
        },
        else => {
            if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
                return std.fs.path.join(allocator, &[_][]const u8{ xdg_config, app_name });
            }
            const home = environment.get("HOME") orelse {
                std.log.err("HOME environment variable not set", .{});
                return error.MissingRequiredField;
            };
            return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", app_name });
        },
    }
}

pub fn getDefaultConfigPath(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError![]const u8 {
    const config_dir = try getDefaultConfigDir(allocator, environment);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
}

pub fn loadDefault(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) LlmConfig.LoadError!LlmConfig {
    return LlmConfig.init(allocator, null, environment);
}

test {
    _ = @import("config_test.zig");
}
