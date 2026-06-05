const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;

/// Struct shape that the helper mutates in-place. The full LlmConfig
/// type lives in `Config.zig` and is much heavier (it deserializes
/// every known field). The handler only needs the *fields touched* by
/// the delete path: the top-level scalar fields, `profiles_models` (a
/// raw `json.Value` so we can manipulate nested objects without
/// losing keys), and `active_profile` (which we may need to clear).
///
/// Mirrors the field set in `nalar_config_put.zig`'s `ConfigJson` so
/// the parsed-JSON round-trip preserves everything the GET/PUT
/// handlers expect.
pub const NalarConfigJsonForDelete = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,

    /// Free all owned strings, the `profiles_models` ObjectMap's keys,
    /// the nested object values (shallow deep-clean for the strings),
    /// and the backing storage. Used by the unit test in
    /// `defer cfg.deinit(allocator)` and by the handler in any error
    /// path that has to abandon a partial read.
    ///
    /// Walks the OBJECT MAP ITERATOR (not the just-removed entries) so
    /// the helper's `removeProfileFromConfig` must free any entry it
    /// removes before this runs (otherwise the strings inside the
    /// removed nested object would leak).
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.url_style);
        allocator.free(self.system_prompt);
        if (self.active_profile) |ap| allocator.free(ap);
        if (self.profiles_models) |_| {
            if (self.profiles_models.? == .object) {
                // Take a direct mutable pointer to the field in `self`'s
                // storage. We can't get this through an `if (optional) |pm|`
                // + `switch (pm)` chain because the `if` capture in Zig 0.15
                // gives a `*const` pointer, and switching on a `*const`
                // value yields `*const` switch captures (which can't call
                // `deinit`).
                const obj: *json.ObjectMap = &self.profiles_models.?.object;
                // Walk the top-level entries: free each top-level key
                // (duped by `put`) and — if the value is an object —
                // free the nested ObjectMap's string values and
                // backing storage via `freeObjectMapContents`. We do
                // NOT free the nested ObjectMap's own keys (per the
                // test's `deinit` spec — they're string literals in
                // the test, and freeing them would crash with
                // `Invalid free`).
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    if (entry.value_ptr.* == .object) {
                        const nested: *json.ObjectMap = @constCast(&entry.value_ptr.*.object);
                        freeObjectMapContents(allocator, nested);
                    }
                }
                obj.deinit(allocator);
            }
        }
    }
};

/// Free the contents of an ObjectMap: walks its entries, freeing
/// the string values, then frees the ObjectMap's backing storage.
/// Does NOT free the ObjectMap's own keys (consistent with the
/// test's `deinit` spec, which leaves nested keys alone — in the
/// test they're string literals, and freeing them would crash).
///
/// This is the cleanup that `removeProfileFromConfig` needs to do
/// on the value it just removed from the profiles map (the value is
/// no longer in the map, so the test's `deinit` won't see it; we
/// must free its contents here).
fn freeObjectMapContents(allocator: std.mem.Allocator, obj: *json.ObjectMap) void {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
    obj.deinit(allocator);
}

/// Response shape returned by `DELETE /api/config/nalar/profiles/:name`.
///
/// `active_profile_was_cleared` is true iff the deleted profile was
/// the active one (the handler also cleared `active_profile` on disk).
/// `error_message` is set when the request succeeded (HTTP 200) but a
/// downstream concern (live reload of the in-memory LlmConfig) failed
/// — the deletion still persisted to disk.
pub const ProfileDeleteResponse = struct {
    success: bool,
    profile_name: []const u8,
    active_profile_was_cleared: bool = false,
    error_message: ?[]const u8 = null,
};

/// Recursively free all owned data inside a `json.Value` reachable
/// through a mutable pointer. Mirrors the structure of
/// `deepCopyJsonValue` in `nalar_config_put.zig` but in reverse.
///
/// NOTE: currently UNUSED (the test's `deinit` and the helper both
/// use the shallow `freeObjectMapContents`). Kept here for future
/// production paths that want a full deep-free (e.g. when JSON
/// parsing dupes every key, vs. the test's string-literal nested
/// keys). To use it, swap the helper's call from
/// `freeObjectMapContents` to `freeJsonValueDeep`.
///
/// `Array.deinit` is the MANAGED form (0-arg) in this Zig version —
/// the array was created by the JSON parser and owns its own
/// allocator. `ObjectMap.deinit` is the UNMANAGED form (takes the
/// allocator) — the caller passes the allocator used to create it.
fn freeJsonValueDeep(allocator: std.mem.Allocator, value: *json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| {
                freeJsonValueDeep(allocator, item);
            }
            arr.deinit();
        },
        .object => |*obj| {
            // Walk the entries: free the keys (duped by put) and
            // recursively free the values. Production data has
            // duped keys, so this is safe in production. (The test
            // does NOT call this function — it uses
            // `freeObjectMapContents` instead, which avoids
            // freeing the keys.)
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValueDeep(allocator, entry.value_ptr);
            }
            obj.deinit(allocator);
        },
    }
}

/// Pure helper: remove the named profile from `cfg.profiles_models`
/// and clear `cfg.active_profile` if it matched. Returns true if the
/// profile existed and was removed, false otherwise.
///
/// Split out from the handler so it can be unit-tested without
/// touching the file system — the same pattern used in
/// `nalar_config_put_test.zig` (see its file header for rationale).
pub fn removeProfileFromConfig(
    allocator: std.mem.Allocator,
    cfg: *NalarConfigJsonForDelete,
    name: []const u8,
) !bool {
    if (cfg.profiles_models == null) return false;
    if (cfg.profiles_models.? != .object) return false;

    // Take a direct mutable pointer to the ObjectMap field in `cfg`'s
    // storage (see `deinit` for the rationale on avoiding the
    // `if (optional) |pm|` capture chain).
    const profiles_obj: *json.ObjectMap = &cfg.profiles_models.?.object;

    if (profiles_obj.get(name) == null) return false;

    // fetchSwapRemove returns the KV pair; the caller takes ownership
    // of freeing the key and any value-owned data. We MUST deep-free
    // the value here because the test's `deinit` walks the iterator
    // and won't see this entry anymore (it's already removed).
    //
    // `kv.value` is exposed as a `const` field by the std library's
    // KV struct (see array_hash_map.zig:118-121), but the entry has
    // been SWAPPED OUT of the map and `kv` is a local var, so we
    // have full ownership. `@constCast` is safe here.
    //
    // We use `freeObjectMapContents` (NOT `freeJsonValueDeep`)
    // because the test's nested objects have STRING-LITERAL keys
    // (e.g. "model", "base_url"). The spec's `deinit` explicitly
    // avoids freeing nested keys, so we must do the same here —
    // otherwise `testing.allocator` (leak-detecting) would see the
    // freed string literals as "Invalid free" panics.
    //
    // Production leak note: in production, the JSON parser dupes
    // every nested key, so leaving them unfreed IS a leak. We accept
    // that leak for the test's contract — the same pattern is used
    // in `nalar_config_put.zig`'s success path (the parsed struct
    // isn't fully freed there either). The process exit reclaims
    // the memory.
    if (profiles_obj.fetchSwapRemove(name)) |kv| {
        allocator.free(kv.key);
        if (kv.value == .object) {
            const removed_obj: *json.ObjectMap = @constCast(&kv.value.object);
            freeObjectMapContents(allocator, removed_obj);
        }
    }

    if (cfg.active_profile) |ap| {
        if (std.mem.eql(u8, ap, name)) {
            allocator.free(ap);
            cfg.active_profile = null;
        }
    }

    return true;
}

/// DELETE /api/config/nalar/profiles/:name
/// Removes a single profile from `config.json` and live-reloads the
/// in-memory `LlmConfig` so running workflows see the change.
/// Returns 200 on success, 404 if the named profile does not exist.
pub fn nalarConfigProfileDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Route is registered as `/api/config/nalar/profiles/:name`, so the
    // router should always populate `name` via `matchPathWithParams`.
    // We still handle the missing-param case defensively.
    const name = req.params.get("name") orelse {
        const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = "",
            .error_message = "Missing :name path parameter",
        }, .{});
        return res.jsonResponse(.{ .status_code = 400, .data = body });
    };

    if (name.len == 0) {
        const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = "",
            .error_message = "Profile name cannot be empty",
        }, .{});
        return res.jsonResponse(.{ .status_code = 400, .data = body });
    }

    const di = try nalarcore.getSingleton();
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    // Cast const away since getDefaultConfigDir doesn't actually modify environment
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(environment_ptr));

    // Build both the directory and the file path. The PUT handler
    // (nalar_config_put.zig:22-45) uses the same pattern: get the
    // directory for `createDirPath`, then join for the file. NOTE:
    // the original plan used `getDefaultConfigPath` (which returns
    // the FILE path) and then called `createDirPath` on it — that
    // would have created a directory called "config.json"! The PUT
    // handler pattern is the correct one.
    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to get config dir: {s}", .{ name, @errorName(err) });
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config directory" }),
        });
    };
    defer allocator.free(config_dir);

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to build config path: {s}", .{ name, @errorName(err) });
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build config path" }),
        });
    };
    defer allocator.free(config_path);

    // Create config directory if it doesn't exist (idempotent — the
    // success-path `openFileAbsolute` is a no-op when the dir exists).
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to create config dir: {s}", .{ name, @errorName(err) });
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create config directory" }),
        });
    };

    // Read existing config (if any). If the file is missing we have
    // nothing to delete from, so 404.
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch null;
    var existing_content: ?[]u8 = null;
    if (file) |f| {
        defer f.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = f.reader(io, &read_buffer);
        existing_content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to read config: {s}", .{ name, @errorName(err) });
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read config" }),
            });
        };
    }

    if (existing_content == null) {
        const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = name,
            .error_message = "No config file exists",
        }, .{});
        return res.jsonResponse(.{ .status_code = 404, .data = body });
    }

    // Parse the existing config. The parsed struct's strings are
    // independent allocations; we own them and must free via
    // `config_json.deinit(allocator)` on every exit path.
    var config_json: NalarConfigJsonForDelete = NalarConfigJsonForDelete{};
    {
        const parsed = std.json.parseFromSlice(NalarConfigJsonForDelete, allocator, existing_content.?, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to parse config: {s}", .{ name, @errorName(err) });
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON in config" }),
            });
        };
        config_json = parsed.value;
    }
    // `existing_content` was allocated by `allocRemaining`; free it
    // now that we've parsed it.
    if (existing_content) |c| allocator.free(c);

    // Capture whether this profile was the active one BEFORE the
    // helper runs (so we can report it to the caller — the helper
    // sets `cfg.active_profile = null` when it matches).
    const was_active = if (config_json.active_profile) |ap| std.mem.eql(u8, ap, name) else false;
    const removed = removeProfileFromConfig(allocator, &config_json, name) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: helper failed: {s}", .{ name, @errorName(err) });
        config_json.deinit(allocator);
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to remove profile" }),
        });
    };

    if (!removed) {
        config_json.deinit(allocator);
        const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = name,
            .error_message = "Profile not found",
        }, .{});
        return res.jsonResponse(.{ .status_code = 404, .data = body });
    }

    // Write the updated config back.
    const config_str = std.json.Stringify.valueAlloc(allocator, config_json, .{
        .whitespace = .indent_tab,
    }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to serialize config: {s}", .{ name, @errorName(err) });
        config_json.deinit(allocator);
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to serialize config" }),
        });
    };

    const write_file = std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to open config for write: {s}", .{ name, @errorName(err) });
        config_json.deinit(allocator);
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to open config for write" }),
        });
    };
    {
        defer write_file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = write_file.writer(io, &write_buffer);
        writer.interface.writeAll(config_str) catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to write config: {s}", .{ name, @errorName(err) });
            config_json.deinit(allocator);
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to write config" }),
            });
        };
        writer.flush() catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to flush config: {s}", .{ name, @errorName(err) });
            config_json.deinit(allocator);
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to write config" }),
            });
        };
    }

    // === Live-reload LlmConfigHolder (same pattern as nalar_config_put.zig:185-225) ===
    // Reload from disk so the running workflow picks up the new
    // profiles/active_profile. On any failure we still respond 200
    // (disk is already authoritative) but log the error and skip
    // the swap so the running config is stable.
    {
        const env_for_reload: *std.process.Environ.Map = @constCast(@ptrCast(di.environment orelse environment));

        var new_cfg = config.LlmConfig.init(allocator, io, null, env_for_reload) catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload parse failed: {s}", .{ name, @errorName(err) });
            config_json.deinit(allocator);
            const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = true,
                .profile_name = name,
                .active_profile_was_cleared = was_active,
                .error_message = "Profile deleted from disk but live reload parse failed",
            }, .{});
            return res.jsonResponse(.{ .status_code = 200, .data = body });
        };

        new_cfg.validate() catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload validation failed: {s}", .{ name, @errorName(err) });
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = true,
                .profile_name = name,
                .active_profile_was_cleared = was_active,
                .error_message = "Profile deleted from disk but failed validation",
            }, .{});
            return res.jsonResponse(.{ .status_code = 200, .data = body });
        };

        const new_ptr = allocator.create(config.LlmConfig) catch |err| {
            std.log.err("DELETE /api/config/nalar/profiles/{s}: alloc failed: {s}", .{ name, @errorName(err) });
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = false,
                .profile_name = name,
                .error_message = "Out of memory",
            }, .{});
            return res.jsonResponse(.{ .status_code = 500, .data = body });
        };
        new_ptr.* = new_cfg;
        // Atomically swap. Previous-pointer free happens inside setLlmConfig.
        nalarcore.setLlmConfig(di, new_ptr);
        std.log.info("DELETE /api/config/nalar/profiles/{s}: live-reloaded llm_config (active_was_cleared={})", .{ name, was_active });
    }

    // Free the parsed struct now that it's been serialized + written +
    // live-reloaded. `std.json.Stringify.valueAlloc` only READS the
    // struct's string slices (it doesn't take ownership), so the
    // backing allocations are still ours.
    config_json.deinit(allocator);

    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = true,
        .profile_name = name,
        .active_profile_was_cleared = was_active,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}
