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
    mcpServers_parsed: ?json.Parsed(json.Value),
    /// Parsed profiles from profiles_models
    profiles_models: ProfilesMap,

    pub const LoadError = error{
        ConfigFileNotFound,
        ConfigFileReadError,
        InvalidJson,
        MissingRequiredField,
        OutOfMemory,
        HomeNotFound,
        ConfigDirNotFound,
    };

    /// Individual profile settings
    pub const LlmProfile = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
    };

    const ProfileJson = struct {
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        api_key: []const u8 = "",
    };

    const LlmConfigJson = struct {
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        model_compaction_size_kb: usize = 100,
        mcpServers: ?std.json.Value = null,
        /// Profiles - parsed as json.Value then converted to map
        profiles_models: ?std.json.Value = null,
    };

    /// Profiles storage after parsing from JSON
    pub const ProfilesMap = std.StringHashMap(LlmProfile);

    const ProfilesModelsJson = struct {
        profile1: ?ProfileJson = null,
        profile2: ?ProfileJson = null,
        profile3: ?ProfileJson = null,
        profile4: ?ProfileJson = null,
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
            .mcpServers_parsed = null,
            .profiles_models = ProfilesMap.init(allocator),
        };
        errdefer {
            allocator.free(config.api_key);
            allocator.free(config.model);
            allocator.free(config.base_url);
            freeProfilesMap(&config.profiles_models, allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

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
            // Store the full Parsed wrapper so we can call .deinit() on it later
            config.mcpServers_parsed = reparsed;
        }

        // Parse profiles_models into ProfilesMap
        if (config_json.profiles_models) |profiles| {
            const profiles_str = std.json.Stringify.valueAlloc(allocator, profiles, .{}) catch {
                return error.InvalidJson;
            };
            defer allocator.free(profiles_str);

            const profiles_parsed = json.parseFromSlice(ProfilesModelsJson, allocator, profiles_str, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            defer profiles_parsed.deinit();

            const profiles_data = profiles_parsed.value;

            try addProfile(&config.profiles_models, "profile1", profiles_data.profile1, allocator);
            try addProfile(&config.profiles_models, "profile2", profiles_data.profile2, allocator);
            try addProfile(&config.profiles_models, "profile3", profiles_data.profile3, allocator);
            try addProfile(&config.profiles_models, "profile4", profiles_data.profile4, allocator);
        }

        return config;
    }

    /// Free all keys and value strings inside a ProfilesMap, then deinit the map.
    fn freeProfilesMap(map: *ProfilesMap, allocator: std.mem.Allocator) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.model);
            allocator.free(entry.value_ptr.base_url);
            allocator.free(entry.value_ptr.thinking);
            allocator.free(entry.value_ptr.temperature);
            allocator.free(entry.value_ptr.api_key);
        }
        map.deinit();
    }

    /// Add a single profile to the map, duplicating all strings onto the allocator.
    fn addProfile(m: *ProfilesMap, name: []const u8, p: ?ProfileJson, alloc: std.mem.Allocator) !void {
        const profile = p orelse return;

        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);

        const model = try alloc.dupe(u8, profile.model);
        errdefer alloc.free(model);

        const base_url = try alloc.dupe(u8, profile.base_url);
        errdefer alloc.free(base_url);

        const thinking = try alloc.dupe(u8, profile.thinking);
        errdefer alloc.free(thinking);

        const temperature = try alloc.dupe(u8, profile.temperature);
        errdefer alloc.free(temperature);

        const api_key = try alloc.dupe(u8, profile.api_key);
        errdefer alloc.free(api_key);

        try m.put(key, LlmProfile{
            .model = model,
            .base_url = base_url,
            .thinking = thinking,
            .temperature = temperature,
            .api_key = api_key,
        });
    }

    pub fn deinit(self: *LlmConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.base_url);

        freeProfilesMap(&self.profiles_models, self.allocator);

        if (self.mcpServers_parsed) |*parsed| {
            parsed.deinit();
        }
    }

    pub fn clone(self: *const LlmConfig) LoadError!LlmConfig {
        var config = LlmConfig{
            .allocator = self.allocator,
            .api_key = try self.allocator.dupe(u8, self.api_key),
            .model = try self.allocator.dupe(u8, self.model),
            .base_url = try self.allocator.dupe(u8, self.base_url),
            .model_compaction_size_kb = self.model_compaction_size_kb,
            .mcpServers_parsed = null,
            .profiles_models = ProfilesMap.init(self.allocator),
        };
        errdefer {
            self.allocator.free(config.api_key);
            self.allocator.free(config.model);
            self.allocator.free(config.base_url);
            freeProfilesMap(&config.profiles_models, self.allocator);
            if (config.mcpServers_parsed) |*p| p.deinit();
        }

        if (self.mcpServers_parsed) |existing| {
            const mcp_str_owned = std.json.Stringify.valueAlloc(self.allocator, existing.value, .{}) catch {
                return error.InvalidJson;
            };
            defer self.allocator.free(mcp_str_owned);

            const reparsed = json.parseFromSlice(json.Value, self.allocator, mcp_str_owned, .{
                .ignore_unknown_fields = true,
            }) catch {
                return error.InvalidJson;
            };
            config.mcpServers_parsed = reparsed;
        }

        // Clone all profiles
        var it = self.profiles_models.iterator();
        while (it.next()) |entry| {
            try addProfile(
                &config.profiles_models,
                entry.key_ptr.*,
                ProfileJson{
                    .model = entry.value_ptr.model,
                    .base_url = entry.value_ptr.base_url,
                    .thinking = entry.value_ptr.thinking,
                    .temperature = entry.value_ptr.temperature,
                    .api_key = entry.value_ptr.api_key,
                },
                self.allocator,
            );
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

    /// Convenience accessor — returns the live json.Value or null.
    pub fn mcpServers(self: *const LlmConfig) ?json.Value {
        return if (self.mcpServers_parsed) |p| p.value else null;
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
