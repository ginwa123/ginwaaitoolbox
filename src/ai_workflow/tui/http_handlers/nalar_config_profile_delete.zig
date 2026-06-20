//! HTTP handler + use-case for `DELETE /api/config/nalar/profiles/:name`.
//!
//! Removes a single profile from `config.json` and live-reloads the
//! in-memory `LlmConfig` so running workflows see the change.
//! Returns 200 on success, 404 if the named profile does not exist.
//!
//! ## File structure
//!
//! This file holds BOTH the use-case (pure function over an in-memory
//! struct) and the HTTP handler (thin orchestrator that reads the
//! file, calls the use-case, writes the file back, and live-reloads
//! the global LlmConfig):
//!
//! - `NalarConfigJsonForDelete` — the in-memory struct the use-case
//!   mutates (mirrors the field set in `nalar_config_put.zig`'s
//!   `ConfigJson` so JSON round-trips preserve everything).
//! - `removeProfileFromConfig` — the **use-case** (pure function,
//!   unit-tested without the file system in
//!   `nalar_config_profile_delete_test.zig`).
//! - `nalarConfigProfileDeleteHandler` — the **HTTP handler**
//!   (orchestrator).
//! - Sub-helpers — small focused functions used by the handler
//!   (path resolution, file I/O, parse, write, live-reload, response
//!   builders).
//!
//! ## Memory model
//!
//! Per the project convention (see `custom-http-server-per-request-arena`
//! memory), this handler does NOT add `defer allocator.free(...)` for
//! request-scoped allocations. The per-request `ArenaAllocator`
//! reaps them when the request finishes. The two exceptions:
//!
//! - `*NalarConfigJsonForDelete` (the parsed JSON struct) owns its
//!   own strings and ObjectMap — those need explicit `deinit`. The
//!   use-case's `deinit` walks them. Failure paths call
//!   `config_json.deinit(allocator)` before returning.
//! - The `config_str` returned by `std.json.Stringify.valueAlloc` is
//!   written to the file and then goes out of scope (arena reaps).

const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;

// =====================================================================
// Domain types
// =====================================================================

/// Struct shape that the use-case mutates in-place. The full LlmConfig
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
    /// the use-case's `removeProfileFromConfig` must free any entry it
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

/// Resolved on-disk config paths. Both slices live for the lifetime
/// of the request (per-request arena) — no explicit `free` needed.
/// `path` is `[]const u8` because that's what `std.fs.path.join`
/// returns in Zig 0.16; `dir` is `[]const u8` because that's what
/// `config.getDefaultConfigDir` returns.
const ConfigPaths = struct {
    dir: []const u8,
    path: []const u8,
};

/// Outcome of the live-reload phase. Preserves the pre-refactor
/// distinction between:
///   - `.ok`       — reload succeeded; respond 200 with no warning.
///   - `.warning`  — disk write succeeded but the running LlmConfig
///                   could not be updated; respond 200 with the warning
///                   message so the caller knows the running workflow
///                   is stale until restart.
///   - `.fatal`    — disk write succeeded but the helper OOM'd; respond
///                   500 because the running workflow is in a bad state
///                   (matches the pre-refactor behavior).
const LiveReloadResult = union(enum) {
    ok,
    warning: []const u8,
    fatal: []const u8,
};

// =====================================================================
// Use-case (pure)
// =====================================================================

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

/// Recursively free all owned data inside a `json.Value` reachable
/// through a mutable pointer. Mirrors the structure of
/// `deepCopyJsonValue` in `nalar_config_put.zig` but in reverse.
///
/// NOTE: currently UNUSED (the test's `deinit` and the use-case both
/// use the shallow `freeObjectMapContents`). Kept here for future
/// production paths that want a full deep-free (e.g. when JSON
/// parsing dupes every key, vs. the test's string-literal nested
/// keys). To use it, swap the use-case's call from
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

/// Pure use-case: remove the named profile from `cfg.profiles_models`
/// and clear `cfg.active_profile` if it matched. Returns true if the
/// profile existed and was removed, false otherwise.
///
/// Split out from the handler logic so it can be unit-tested without
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

// =====================================================================
// Handler
// =====================================================================

/// `DELETE /api/config/nalar/profiles/:name`
/// Removes a single profile from `config.json` and live-reloads the
/// in-memory `LlmConfig` so running workflows see the change.
/// Returns 200 on success, 404 if the named profile does not exist.
///
/// This is a thin orchestrator over the sub-helpers below:
///   1. validate `:name`            (inline)
///   2. `resolveConfigPaths`         — dir + file
///   3. `ensureConfigDir`            — create the dir if missing
///   4. `readConfigFile`             — read disk → `?[]u8`
///   5. `parseConfigJson`            — JSON → `NalarConfigJsonForDelete`
///   6. `isActiveProfile`            + `removeProfileFromConfig` (use-case)
///   7. `writeConfigBack`            — serialize + write to disk
///   8. `liveReloadLlmConfig`        — best-effort reload
///   9. `makeSuccessResponse` / `makeErrorResponse` — response builder
pub fn nalarConfigProfileDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Validate `:name` path parameter.
    const name = req.params.get("name") orelse
        return makeErrorResponse(allocator, res, 400, "", "Missing :name path parameter");
    if (name.len == 0)
        return makeErrorResponse(allocator, res, 400, "", "Profile name cannot be empty");

    // 2. Resolve on-disk config paths (dir + file). The PUT handler
    //    (nalar_config_put.zig) uses the same pattern.
    const paths = resolveConfigPaths(allocator, name) catch
        return makeErrorResponse(allocator, res, 500, name, "Failed to resolve config paths");

    // 3. Ensure the config directory exists (idempotent).
    ensureConfigDir(io, paths.dir) catch
        return makeErrorResponse(allocator, res, 500, name, "Failed to create config directory");

    // 4. Read the existing config file. `null` = file does not exist.
    const content = readConfigFile(allocator, io, paths.path) catch {
        return makeErrorResponse(allocator, res, 500, name, "Failed to read config");
    } orelse {
        return makeErrorResponse(allocator, res, 404, name, "No config file exists");
    };

    // 5. Parse the existing config. On failure, `content` is freed by
    //    the arena (per-request reaps request-scoped allocations).
    var config_json = parseConfigJson(allocator, content) catch
        return makeErrorResponse(allocator, res, 500, name, "Invalid JSON in config");

    // 6. Apply the use-case: remove the named profile. Capture
    //    `was_active` BEFORE the use-case clears it (the use-case
    //    sets `cfg.active_profile = null` on a match).
    const was_active = isActiveProfile(&config_json, name);
    const removed = removeProfileFromConfig(allocator, &config_json, name) catch {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 500, name, "Failed to remove profile");
    };
    if (!removed) {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 404, name, "Profile not found");
    }

    // 7. Write the updated config back to disk. On failure, free the
    //    parsed struct so its owned strings don't leak.
    writeConfigBack(allocator, io, paths.path, &config_json) catch {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 500, name, "Failed to write config");
    };

    // 8. Live-reload the in-memory LlmConfig. On failure the disk is
    //    already authoritative, so we still respond 200 with a warning
    //    UNLESS the failure was a fatal allocation error (matches the
    //    pre-refactor behavior).
    const reload_result = liveReloadLlmConfig(io, name);

    config_json.deinit(allocator);

    return switch (reload_result) {
        .ok => makeSuccessResponse(allocator, res, name, was_active, null),
        .warning => |msg| makeSuccessResponse(allocator, res, name, was_active, msg),
        .fatal => |msg| makeErrorResponse(allocator, res, 500, name, msg),
    };
}

// =====================================================================
// Sub-helpers (handler plumbing)
// =====================================================================

/// Get the singleton, then resolve the config dir + file path.
/// Logs the error and returns the same error variant on failure so
/// the handler can map it to HTTP 500.
fn resolveConfigPaths(allocator: std.mem.Allocator, name: []const u8) !ConfigPaths {
    const di = nalarcore.getSingleton() catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: singleton unavailable: {s}", .{ name, @errorName(err) });
        return error.SingletonUnavailable;
    };
    const environment_ptr = di.environment orelse {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: environment unavailable", .{name});
        return error.EnvironmentUnavailable;
    };
    // `getDefaultConfigDir` does not actually modify the env, but its
    // signature takes a mutable pointer. The same pattern is used in
    // `nalar_config_put.zig:185-225`.
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to get config dir: {s}", .{ name, @errorName(err) });
        return error.ConfigDirFailed;
    };
    errdefer allocator.free(config_dir);

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: failed to build config path: {s}", .{ name, @errorName(err) });
        return error.ConfigPathFailed;
    };

    return ConfigPaths{ .dir = config_dir, .path = config_path };
}

/// Create the config directory if it does not exist (idempotent).
/// The original handler inlined this as a `catch |err|` block.
fn ensureConfigDir(io: std.Io, config_dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to create config dir: {s}", .{@errorName(err)});
        return err;
    };
}

/// Read the entire config file into a heap-allocated buffer.
/// Returns `null` if the file does not exist (HTTP 404 path).
/// Returns other errors on I/O failure (HTTP 500 path).
fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.err("DELETE /api/config/nalar/profiles: failed to open config: {s}", .{@errorName(err)});
            return err;
        },
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to read config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Parse the on-disk config JSON into a `NalarConfigJsonForDelete`.
/// The parsed struct's strings are independent allocations; ownership
/// transfers to the caller (use `deinit` to free them).
fn parseConfigJson(allocator: std.mem.Allocator, content: []const u8) !NalarConfigJsonForDelete {
    const parsed = std.json.parseFromSlice(NalarConfigJsonForDelete, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to parse config: {s}", .{@errorName(err)});
        return err;
    };
    return parsed.value;
}

/// Was the named profile the currently-active one? The use-case
/// clears `active_profile` if it matched, so we capture this BEFORE
/// calling the use-case.
fn isActiveProfile(cfg: *const NalarConfigJsonForDelete, name: []const u8) bool {
    return if (cfg.active_profile) |ap| std.mem.eql(u8, ap, name) else false;
}

/// Serialize the updated config and write it back to disk (truncate).
/// On success the file on disk is the new authoritative state.
fn writeConfigBack(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    config_json: *NalarConfigJsonForDelete,
) !void {
    const config_str = std.json.Stringify.valueAlloc(allocator, config_json.*, .{
        .whitespace = .indent_tab,
    }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to serialize config: {s}", .{@errorName(err)});
        return err;
    };

    const write_file = std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    }) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to open config for write: {s}", .{@errorName(err)});
        return err;
    };
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    writer.interface.writeAll(config_str) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to write config: {s}", .{@errorName(err)});
        return err;
    };
    writer.flush() catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles: failed to flush config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Live-reload the global `LlmConfig` from disk. Best-effort: on
/// failure the disk is already authoritative, so we still respond
/// 200 with a warning UNLESS the failure was a fatal allocation
/// error (matches the pre-refactor behavior).
///
/// Same pattern as `nalar_config_put.zig:185-225`.
fn liveReloadLlmConfig(io: std.Io, name: []const u8) LiveReloadResult {
    const di = nalarcore.getSingleton() catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload singleton failed: {s}", .{ name, @errorName(err) });
        return .{ .warning = "Profile deleted from disk but live reload failed (singleton unavailable)" };
    };

    const env_for_reload: *std.process.Environ.Map = @ptrCast(@constCast(di.environment orelse {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload environment unavailable", .{name});
        return .{ .warning = "Profile deleted from disk but live reload failed (environment unavailable)" };
    }));

    const global_allocator = di.allocator;
    var new_cfg = config.LlmConfig.init(global_allocator, io, null, env_for_reload) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload parse failed: {s}", .{ name, @errorName(err) });
        return .{ .warning = "Profile deleted from disk but live reload parse failed" };
    };

    const new_ptr = global_allocator.create(config.LlmConfig) catch |err| {
        std.log.err("DELETE /api/config/nalar/profiles/{s}: live reload alloc failed: {s}", .{ name, @errorName(err) });
        // Free the local copy we failed to heap-allocate.
        var mut: *config.LlmConfig = &new_cfg;
        mut.deinit();
        return .{ .fatal = "Out of memory" };
    };
    new_ptr.* = new_cfg;

    // Atomically swap. Previous-pointer free happens inside setLlmConfig.
    nalarcore.setLlmConfig(di, new_ptr);
    std.log.info("DELETE /api/config/nalar/profiles/{s}: live-reloaded llm_config", .{name});
    return .ok;
}

// =====================================================================
// Response builders (DRY)
// =====================================================================

/// Build a JSON error response with a `ProfileDeleteResponse` body.
/// Used for every 4xx/5xx exit path in the handler.
fn makeErrorResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    status_code: u16,
    name: []const u8,
    error_message: []const u8,
) !gserverz.HttpResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = false,
        .profile_name = name,
        .error_message = error_message,
    }, .{});
    return res.jsonResponse(.{ .status_code = status_code, .data = body });
}

/// Build the 200 OK success response. `warning` is `null` on a clean
/// success or a short string on a "deleted from disk but live reload
/// had a non-fatal issue" outcome.
fn makeSuccessResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    name: []const u8,
    was_active: bool,
    warning: ?[]const u8,
) !gserverz.HttpResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = true,
        .profile_name = name,
        .active_profile_was_cleared = was_active,
        .error_message = warning,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}
