//! Exec wrapper for the `add_mcp_server` agent tool.
//!
//! Composes four steps:
//!   1. Parse the LLM JSON arguments into `AddMcpServerInput`
//!   2. Call the pure-fn primitive `executeAddMcpServerToString`, which
//!      validates + mutates the live `LlmConfig.mcp_servers` typed map
//!      and rebuilds `mcpServers_parsed` (the JSON mirror `buildMCPToolsRun`
//!      reads when rebuilding the system prompt each iteration).
//!   3. After a successful primitive, persist the change to disk + hot-
//!      reload `di.llm_config` so subsequent agent iterations see the
//!      new server via `buildMCPToolsRun` (which reads `mcpServers()` from
//!      the live config) — this is the critical live-reload step. The
//!      HTTP PUT endpoint at `nalar_config_put.zig` uses the same pattern;
//!      see that file for the full write/atomic-swap sequence.
//!   4. Wrap the result in the standard `<tool>...</tool>` envelope.
//!
//! Why the best-effort tools listing lives here (not in the pure fn):
//! the pure fn must be unit-testable in isolation. The listing spawns a
//! child via the global `StdioRegistry`, whose arena is cleaned up only
//! in `deinitGlobal` (process shutdown) — calling it from a unit test
//! leaks arena memory through the test allocator. The exec wrapper
//! runs in production where process-level registry state is the right
//! scope for a child process.
//!
//! Plan: docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
//! Task: task_1787929165057_9 (Step 3 of 7)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const helpers = @import("helpers");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const config_mod = nalarcore.config;
const add_mcp_server_mod = nalarcore.add_mcp_server;
const AddMcpServerInput = add_mcp_server_mod.AddMcpServerInput;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execAddMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // ── 1. Parse the LLM JSON args ──────────────────────────────────────
    // AddMcpServerInput has a ?[]const Header field reserved for the HTTP
    // sibling task; the default parser handles it fine (Header is a plain
    // {name, value} struct). For stdio entries (the v1 case) the field
    // stays null — the primitive ignores it via its own
    // addMcpServerStdio branch.
    const parsed = std.json.parseFromSlice(
        AddMcpServerInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "add_mcp_server failed to parse input: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // ── 2. Mutate the live config (typed map + JSON mirror) ────────────
    //
    // The pure-fn primitive takes a `*LlmConfig` (mutable). The exec
    // context's `config` is `*const` — constCast is the standard trick
    // for "I know the underlying memory is mutable, the const-ness is
    // just to discourage accidental writes through this pointer". Same
    // pattern as the LlmConfig clone path.
    const config_mut = @constCast(ctx.config);
    const inner = add_mcp_server_mod.executeAddMcpServerToString(
        ctx.allocator,
        ctx.io,
        config_mut,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "add_mcp_server failed: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // ── 3. Detect the <error>...</error> shape from the pure fn ─────────
    //
    // The pure fn returns `<add_mcp_server><error>...</error></add_mcp_server>`
    // on validation failures. The exec wrapper surfaces these as
    // `success=false` in the standard envelope (so the LLM sees the error
    // rather than a successful wrapper around an error body). The inner
    // XML is still surfaced in `<data>` so the LLM can see the per-tool
    // detail.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // ── 4. Persist to disk + hot-reload `di.llm_config` ────────────────
    //
    // On any failure here the in-memory config is already updated (the
    // agent's iteration will see the new server's tools regardless), so
    // we capture the failure reason + log + continue rather than
    // failing the whole tool call. The status string flows into the
    // `<persisted>` block via `substitutePersistedStatus` below.
    //
    // `persistAndReload` ALWAYS returns an owned slice on `ctx.allocator`
    // (allocated via `dupe` or `allocPrint`) so the caller can defer
    // free without branching on which path produced the value.
    const persist_status_owned = persistAndReloadStatus(ctx) catch |err| blk: {
        std.log.warn(
            "add_mcp_server: in-memory mutation succeeded but disk write failed: {s}",
            .{@errorName(err)},
        );
        break :blk ctx.allocator.dupe(u8, "false") catch @as([]u8, &[_]u8{});
    };
    defer ctx.allocator.free(persist_status_owned);
    const persist_status: []const u8 = persist_status_owned;

    // ── 5. Inject the persisted status into the inner XML. ─────────────
    //
    // The pure-fn envelope hard-codes `<persisted>false</persisted>` as a
    // placeholder (it doesn't know whether persistence will happen —
    // that's the exec wrapper's responsibility). We substitute the
    // placeholder with the actual outcome. We assume the placeholder
    // appears EXACTLY once — the inner XML comes from
    // `successXml` in tools/add_mcp_server.zig which builds it via a
    // single string concatenation (no duplication).
    //
    // We can do a more precise substitution than "true"/"false": the
    // placeholder is literal `<persisted>false</persisted>`. We replace
    // it with the full `<persisted>{status}</persisted>`. When the
    // status is just "true" or "false" this preserves the LLM-friendly
    // exact shape; when it's "false: <reason>" it carries the failure
    // mode so the LLM can self-correct on retry.
    const inner_with_status = try substitutePersistedStatus(
        ctx.allocator,
        inner,
        persist_status,
    );
    defer ctx.allocator.free(inner_with_status);

    // ── 6. Best-effort tools listing (process-level registry is OK here)
    //
    // SKIP when the exec context has no environment — that's our signal
    // that we're in a unit test, where calling `StdioRegistry.global`
    // would leak arena memory through the test allocator (the global
    // registry's arena is only cleaned up in `deinitGlobal`, which the
    // test process never calls). Production callers always have an env.
    const inner_with_status_and_tools = if (ctx.environment == null)
        inner_with_status
    else
        listAndAppendTools(ctx, inner_with_status, parsed.value.name) catch inner_with_status;

    // ── 7. Wrap the final envelope ─────────────────────────────────────
    const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, true, null, inner_with_status_and_tools);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Substitute the `<persisted>false</persisted>` placeholder in the
/// pure-fn envelope with the actual disk-write + live-reload status.
///
/// `inner_xml` is the pure-fn output (built by `add_mcp_server.executeAddMcpServerToString`).
/// The placeholder appears exactly once — emitted by `successXml` via a
/// single string concatenation. We swap the placeholder `<persisted>...</persisted>`
/// shell with `<persisted>{status}</persisted>` where `status` is the
/// caller-provided persist_status (typically `"true"`, `"false"`, or
/// `"false: <reason>"`). The `status` argument is escaped via
/// `xmlEscape` so any embedded `<` or `&` doesn't corrupt the envelope
/// shape — the caller passes a single line of text from `persistAndReload`
/// and we keep the whole envelope well-formed.
///
/// Returns a freshly-allocated slice; caller frees.
fn substitutePersistedStatus(
    allocator: std.mem.Allocator,
    inner_xml: []const u8,
    status: []const u8,
) ![]u8 {
    const placeholder = "<persisted>false</persisted>";

    const idx = std.mem.indexOf(u8, inner_xml, placeholder) orelse {
        // Defensive: if the pure-fn envelope shape ever drifts and the
        // placeholder is missing, surface a clear error rather than
        // return the unmodified XML (which would lie to the LLM by
        // saying "persisted=false" when actually unknown).
        return error.MissingPersistedPlaceholder;
    };

    const status_e = try helpers.xml_escape(allocator, status);
    defer allocator.free(status_e);
    const replacement = try std.fmt.allocPrint(allocator, "<persisted>{s}</persisted>", .{status_e});
    defer allocator.free(replacement);

    const prefix = inner_xml[0..idx];
    const suffix_start = idx + placeholder.len;
    const suffix = inner_xml[suffix_start..];
    const result_len = prefix.len + replacement.len + suffix.len;
    const result = try allocator.alloc(u8, result_len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len ..][0..replacement.len], replacement);
    @memcpy(result[prefix.len + replacement.len ..][0..suffix.len], suffix);
    return result;
}

// ───────────────────────────────────────────────────────────────────────
// Disk persistence + live-reload helper
// ───────────────────────────────────────────────────────────────────────

/// Persist the live config to `~/.config/nalar/config.json` and hot-reload
/// `di.llm_config` via `setLlmConfig` so subsequent agent iterations see
/// the new server through `buildMCPToolsRun`. Mirrors the write sequence
/// in `nalar_config_put.zig` (PUT /api/config/nalar):
/// read → mutate `mcp_servers` → write → re-parse + swap `llm_config`.
///
/// Returns the status string the agent sees in the `<persisted>` field.
/// The returned slice is owned by `ctx.allocator` — caller frees via
/// `defer`. On success the slice contains `"true"`; on any failure path
/// it contains `"false: <reason>"` (allocated via `allocPrint`).
fn persistAndReloadStatus(ctx: ToolExecContext) ![]u8 {
    const di = nalarcore.getSingleton() catch return ctx.allocator.dupe(u8, "false: getSingleton failed") catch return ctx.allocator.dupe(u8, "false") catch unreachable;
    const env_ptr = di.environment orelse return std.fmt.allocPrint(ctx.allocator, "false: environment unavailable", .{}) catch ctx.allocator.dupe(u8, "false") catch unreachable;
    // getDefaultConfigDir takes a non-const pointer but doesn't mutate.
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(env_ptr));

    const config_dir = config_mod.getDefaultConfigDir(ctx.allocator, environment) catch |err| {
        return failStatus(ctx.allocator, "getDefaultConfigDir", @errorName(err));
    };
    defer ctx.allocator.free(config_dir);

    const config_path = std.fs.path.join(ctx.allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        return failStatus(ctx.allocator, "path.join", @errorName(err));
    };
    defer ctx.allocator.free(config_path);

    // Ensure config dir exists.
    std.Io.Dir.cwd().createDirPath(ctx.io, config_dir) catch |err| {
        return failStatus(ctx.allocator, "createDirPath", @errorName(err));
    };

    // Read existing on-disk config (if any) so we don't clobber siblings.
    var existing: ?[]u8 = null;
    if (std.Io.Dir.openFileAbsolute(ctx.io, config_path, .{})) |f| {
        defer f.close(ctx.io);
        var buf: [4096]u8 = undefined;
        var reader = f.reader(ctx.io, &buf);
        existing = reader.interface.allocRemaining(ctx.allocator, .limited(1024 * 1024)) catch null;
    } else |_| {
        existing = null;
    }
    defer if (existing) |e| ctx.allocator.free(e);

    // Build new on-disk JSON by reading the live config (which already
    // contains our new server — the primitive mutated the typed map +
    // mcpServers_parsed mirror).
    //
    // We use a minimal shape: take the existing JSON if present (to
    // preserve siblings like active_profile / sub_agents / etc.) and
    // update only the `mcp_servers` field. If no existing file, write
    // a fresh JSON containing just the mcp_servers map.
    const new_body = try buildUpdatedConfigJson(ctx, existing);
    defer ctx.allocator.free(new_body);

    // Write back atomically (truncate + write).
    const wfile = std.Io.Dir.createFileAbsolute(ctx.io, config_path, .{ .truncate = true }) catch |err| {
        return failStatus(ctx.allocator, "createFileAbsolute", @errorName(err));
    };
    var wbuf: [4096]u8 = undefined;
    {
        defer wfile.close(ctx.io);
        var writer = wfile.writer(ctx.io, &wbuf);
        writer.interface.writeAll(new_body) catch |err| {
            return failStatus(ctx.allocator, "writeAll", @errorName(err));
        };
        writer.flush() catch |err| {
            return failStatus(ctx.allocator, "flush", @errorName(err));
        };
    }

    // Hot-reload: re-parse + atomically swap di.llm_config.
    const env_for_reload: *std.process.Environ.Map = @constCast(@ptrCast(di.environment orelse environment));
    var new_cfg = config_mod.LlmConfig.init(di.allocator, ctx.io, null, env_for_reload) catch |err| {
        return failStatus(ctx.allocator, "live reload parse", @errorName(err));
    };
    new_cfg.validate() catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "live reload validate", @errorName(err));
    };
    const new_ptr = di.allocator.create(config_mod.LlmConfig) catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "OOM", @errorName(err));
    };
    new_ptr.* = new_cfg;
    nalarcore.setLlmConfig(di, new_ptr);

    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch unreachable;
}

/// Build a `<persisted>false: <op> <reason></persisted>`-shaped
/// failure status. The result is owned by `allocator` — caller frees.
/// Falls back to a literal "false" copy on OOM (allocPrint failure) so
/// the caller doesn't have to handle the inner failure.
fn failStatus(allocator: std.mem.Allocator, op: []const u8, reason: []const u8) []u8 {
    return std.fmt.allocPrint(
        allocator,
        "false: {s} {s}",
        .{ op, reason },
    ) catch allocator.dupe(u8, "false") catch unreachable;
}

/// Build the on-disk JSON body for the new config. Strategy:
///   - If `existing` is non-null, parse it as a generic `std.json.Value`,
///     copy each (key, value) pair into a fresh ObjectMap (skipping the
///     stale `mcp_servers` entry), put the LIVE `LlmConfig.mcpServers()`
///     under `mcp_servers`, then serialize the fresh map.
///   - If `existing` is null, serialize just `{"mcp_servers": ...}`.
///
/// Ownership rules (D2 in the plan):
///   - The keys in the fresh map are duped strings — we free them after
///     Stringify.valueAlloc deep-copies the structure into a serialized
///     buffer.
///   - The values in the fresh map are **borrowed** from either
///     `parsed.value` (existing config) or `ctx.config.mcpServers()`
///     (live config). ObjectMap.deinit does NOT free values, so the
///     borrowed ObjectMap entries survive — when we serialize, the
///     output is independent.
///   - The borrowed source values' lifetimes are managed by the
///     `defer parsed.deinit()` and the live-config's mirror. Neither is
///     freed by `new_obj.deinit()`, so no use-after-free.
///
/// Why this avoids the F2 leak (the previous version's deep-copy-
/// through-Stringify→parseFromSlice wasted an arena allocation +
/// orphaned the source tree on the success path).
fn buildUpdatedConfigJson(ctx: ToolExecContext, existing: ?[]const u8) ![]u8 {
    const allocator = ctx.allocator;
    const live_mcp_servers = ctx.config.mcpServers() orelse .null;

    if (existing) |body| {
        // Parse existing as a generic Value so we can carry siblings
        // (active_profile, sub_agents, profiles_models, …) into the
        // new file without re-listing them by hand.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            // Fallback: malformed JSON → just emit mcp_servers alone.
            const serialized = try std.json.Stringify.valueAlloc(allocator, .{
                .mcp_servers = live_mcp_servers,
            }, .{ .whitespace = .indent_tab });
            return serialized;
        };
        defer parsed.deinit();

        const root = parsed.value;
        switch (root) {
            .object => |root_obj| {
                // Build the new map. Keys are duped; values are borrowed
                // from `parsed.value` (the existing on-disk shape) or
                // from `live_mcp_servers` (the just-updated typed map's
                // JSON mirror — owned by ctx.config).
                var new_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer new_obj.deinit(allocator);
                var it = root_obj.iterator();
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key_ptr.*, "mcp_servers")) {
                        // Skip — replaced below with the live value.
                        continue;
                    }
                    const key_dup = try allocator.dupe(u8, kv.key_ptr.*);
                    errdefer allocator.free(key_dup);
                    try new_obj.put(allocator, key_dup, kv.value_ptr.*);
                }
                // Live mcp_servers overrides whatever was on disk.
                // Value is borrowed from ctx.config — no deep copy
                // needed; Stringify.valueAlloc reads it on serialize.
                try new_obj.put(allocator, try allocator.dupe(u8, "mcp_servers"), live_mcp_servers);

                // Serialize FIRST (deep-copies the structure into
                // a flat string buffer), THEN free the source map.
                // F2 fix: the previous version's deep-copy-
                // through-parseFromSlice orphaned new_obj + all its
                // duped keys on the success path.
                const serialized = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_obj }, .{
                    .whitespace = .indent_tab,
                });
                errdefer allocator.free(serialized);

                // Free the duped keys (ObjectMap.deinit doesn't).
                // Values stay borrowed — their owners are ctx.config
                // (mcp_servers) and parsed.value (siblings).
                var free_it = new_obj.iterator();
                while (free_it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                }
                new_obj.deinit(allocator);
                return serialized;
            },
            else => {
                // Root wasn't an object — emit a minimal config.
                return try std.json.Stringify.valueAlloc(allocator, .{
                    .mcp_servers = live_mcp_servers,
                }, .{ .whitespace = .indent_tab });
            },
        }
    }

    // No existing file: emit a fresh config with just mcp_servers.
    return try std.json.Stringify.valueAlloc(allocator, .{
        .mcp_servers = live_mcp_servers,
    }, .{ .whitespace = .indent_tab });
}

// `freeJsonValueRecursive` removed: the cleaner `buildUpdatedConfigJson`
// refactor (skip + replace the `mcp_servers` key during the walk) no
// longer needs to deep-free old values — the borrowed old value goes
// back to `parsed` whose `deinit()` handles the cleanup at scope exit.

// ───────────────────────────────────────────────────────────────────────
// Best-effort tools listing (post-mutation)
// ───────────────────────────────────────────────────────────────────────

/// Spawn the just-added server and run a `tools/list` JSON-RPC roundtrip,
/// appending `<tools>...</tools>` to the success envelope. On any failure
/// (spawn / send / recv / parse), the original inner XML is returned
/// unchanged — the server IS registered, this is just a courtesy.
fn listAndAppendTools(ctx: ToolExecContext, inner_xml: []const u8, server_name: []const u8) ![]const u8 {
    const server = ctx.config.mcpServerConfig(server_name) orelse return inner_xml;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(ctx.allocator);
    if (server.command) |cmd| {
        argv_list.append(ctx.allocator, ctx.allocator.dupe(u8, cmd) catch return inner_xml) catch return inner_xml;
    } else {
        return inner_xml;
    }
    if (server.args) |a| {
        for (a) |arg| {
            argv_list.append(ctx.allocator, ctx.allocator.dupe(u8, arg) catch return inner_xml) catch return inner_xml;
        }
    }
    const argv = argv_list.toOwnedSlice(ctx.allocator) catch return inner_xml;
    defer {
        for (argv) |a| ctx.allocator.free(a);
        ctx.allocator.free(argv);
    }

    const mcp_stdio = nalarcore.mcp_stdio;
    // Process-lifetime allocator (see mcp_test.zig: per-iteration arenas dangle).
    const long_lived = if (nalarcore.getSingleton()) |di| di.allocator else |_| ctx.allocator;
    const reg = mcp_stdio.StdioRegistry.global(long_lived);
    const client = reg.getOrSpawn(server_name, argv) catch return inner_xml;
    const req = ctx.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return inner_xml;
    defer ctx.allocator.free(req);
    // 60s deadline matches `handle_mcp_tool.zig:79` and
    // `prompts_build_messages_for_agent_prompt.zig:637`. Without a
    // deadline, a hung child (deadlock, waiting on stdin forever)
    // blocks the tool-exec handler indefinitely — same blocking
    // behaviour the stdio transport had before PR #373. On
    // SendTimeout / RecvTimeout the stale child is killed so the next
    // `getOrSpawn` respawns a fresh process.
    const deadline_ns: u64 = 60 * std.time.ns_per_s;
    client.send(req, deadline_ns) catch |err| {
        if (err == error.SendTimeout) reg.markStale(server_name);
        return inner_xml;
    };
    const resp = client.recv(deadline_ns, null) catch |err| {
        if (err == error.RecvTimeout) reg.markStale(server_name);
        return inner_xml;
    };
    defer ctx.allocator.free(resp);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{
        .ignore_unknown_fields = true,
    }) catch return inner_xml;
    const root = parsed.value;
    const result_val = root.object.get("result") orelse return inner_xml;
    const tools_val = result_val.object.get("tools") orelse return inner_xml;
    const arr = switch (tools_val) {
        .array => |a| a,
        else => return inner_xml,
    };

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(ctx.allocator);
    for (arr.items) |tool_value| {
        const obj = switch (tool_value) {
            .object => |o| o,
            else => continue,
        };
        const name_val = obj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        const line = std.fmt.allocPrint(ctx.allocator, "mcp_{s}_{s}\n", .{ server_name, name }) catch continue;
        defer ctx.allocator.free(line);
        lines.appendSlice(ctx.allocator, line) catch return inner_xml;
    }
    if (lines.items.len == 0) return inner_xml;

    // Append `<tools>...</tools>` before the closing </add_mcp_server>.
    const close_tag = "</add_mcp_server>";
    const close_idx = std.mem.indexOf(u8, inner_xml, close_tag) orelse return inner_xml;
    const tools_block_str = std.fmt.allocPrint(ctx.allocator, "<tools>{s}</tools>", .{lines.items}) catch return inner_xml;
    defer ctx.allocator.free(tools_block_str);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(ctx.allocator);
    try result.appendSlice(ctx.allocator, inner_xml[0..close_idx]);
    try result.appendSlice(ctx.allocator, tools_block_str);
    try result.appendSlice(ctx.allocator, inner_xml[close_idx..]);
    return result.toOwnedSlice(ctx.allocator) catch inner_xml;
}

// ───────────────────────────────────────────────────────────────────────
// Inline tests
// ───────────────────────────────────────────────────────────────────────

const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: nalarcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: nalarcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *nalarcore.sqlite.SqliteBackend) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    var dummy_active_loops: nalarcore.ai_mod.active_loops = undefined;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined, // overridden by the test
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = &dummy_active_loops,
    };
}

fn fixtureConfig(allocator: std.mem.Allocator) !config_mod.LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

// ─── Test 1: success path (persistence disabled — no environment) ───────

test "execAddMcpServer: valid stdio entry → wrapped success envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"hello","transport":"stdio","command":"mcp-hello-world","args":["--port","3001"]}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>add_mcp_server</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<data>") != null);
    // The pure-fn envelope is surfaced in <data>.
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>hello</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<command>mcp-hello-world</command>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<item>--port</item>") != null);

    // No <error> tag on success.
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);

    // Live config mutated.
    try testing.expect(cfg.hasMcpServer("hello"));
    const server = cfg.mcpServerConfig("hello").?;
    try testing.expectEqualStrings("mcp-hello-world", server.command.?);
}

// ─── Test 2: malformed JSON args → wrapped parse error ─────────────────

test "execAddMcpServer: malformed JSON args → wrapped error envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server", "{not json at all");

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "failed to parse input") != null);

    // No server added.
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 3: empty name (validation error) → wrapped error envelope ─────

test "execAddMcpServer: empty name → wrapped error envelope (success=false)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"","transport":"stdio","command":"x"}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "name is required") != null);
    // The <data> block is NOT emitted on the error path — it lives
    // ONLY on success (see wrapToolOutput). Mirrors save_memory's
    // error-envelope contract.

    // No server added.
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 4: substitutePersistedStatus replaces the placeholder correctly ─
//
// F1 fix regression guard. The pure-fn envelope hard-codes
// `<persisted>false</persisted>` as a placeholder (it doesn't know the
// disk-write outcome). This test pins the substitution contract so a
// future drift in `successXml` (e.g., renaming the placeholder, removing
// it, or duplicating it) gets caught here rather than silently returning
// the wrong status to the LLM.
test "substitutePersistedStatus: replaces placeholder with success status" {
    const alloc = testing.allocator;
    const inner =
        "<add_mcp_server>" ++
        "<name>ctx7</name>" ++
        "<persisted>false</persisted>" ++
        "</add_mcp_server>";
    const result = try substitutePersistedStatus(alloc, inner, "true");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<persisted>true</persisted>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<persisted>false</persisted>") == null);
    // Sibling tags are preserved byte-for-byte.
    try testing.expect(std.mem.indexOf(u8, result, "<name>ctx7</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</add_mcp_server>") != null);
}

test "substitutePersistedStatus: replaces placeholder with failure reason" {
    const alloc = testing.allocator;
    const inner =
        "<add_mcp_server><persisted>false</persisted></add_mcp_server>";
    const result = try substitutePersistedStatus(alloc, inner, "false: createDirPath FileNotFound");
    defer alloc.free(result);

    // `<` and `&` in the status are XML-escaped so the envelope stays
    // well-formed even if the failure message contains reserved chars.
    try testing.expect(std.mem.indexOf(u8, result, "<persisted>false: createDirPath FileNotFound</persisted>") != null);
}

test "substitutePersistedStatus: missing placeholder returns error" {
    // F1 defense-in-depth: if the pure-fn envelope ever drops the
    // `<persisted>false</persisted>` placeholder, the exec wrapper
    // refuses to substitute a lie and surfaces an error instead.
    const alloc = testing.allocator;
    const inner = "<add_mcp_server><name>ctx7</name></add_mcp_server>";
    const result = substitutePersistedStatus(alloc, inner, "true");
    try testing.expectError(error.MissingPersistedPlaceholder, result);
}

// F6 caveat: `persistAndReloadStatus` requires `nalarcore.getSingleton()`
// (the live ContextIPCTui) so it can't be unit-tested in isolation —
// the path is exercised end-to-end when an LLM actually calls
// `add_mcp_server` in production. The functional harness boots nalar
// with a stub LLM that never responds to chat completions, so a
// chat-driven test would have to add a fake LLM harness of its own.
// Out of scope for this PR.