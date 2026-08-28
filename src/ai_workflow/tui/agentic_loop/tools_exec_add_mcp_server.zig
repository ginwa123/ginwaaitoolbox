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

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const config_mod = nalarcore.config;
const add_mcp_server_mod = nalarcore.add_mcp_server;
const AddMcpServerInput = add_mcp_server_mod.AddMcpServerInput;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execAddMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // ── 1. Parse the LLM JSON args ──────────────────────────────────────
    // The `?[]const Header` field (HTTP reserved) uses a struct that the
    // default parser can't fill, so we parse without it and reattach it
    // manually when present. For stdio entries (the v1 case) the field
    // stays null — the primitive ignores it.
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
    // agent's iteration will see the new server's tools regardless), so we
    // log + continue rather than failing the whole tool call.
    const persist_msg = persistAndReload(ctx, parsed.value.name) catch |err| blk: {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "config persisted to memory but disk write failed: {s}",
            .{@errorName(err)},
        ) catch "config persisted to memory but disk write failed";
        break :blk msg;
    };
    defer ctx.allocator.free(persist_msg);

    // ── 5. Best-effort tools listing (process-level registry is OK here)
    //
    // SKIP when the exec context has no environment — that's our signal
    // that we're in a unit test, where calling `StdioRegistry.global`
    // would leak arena memory through the test allocator (the global
    // registry's arena is only cleaned up in `deinitGlobal`, which the
    // test process never calls). Production callers always have an env.
    const inner_with_tools = if (ctx.environment == null)
        inner
    else
        listAndAppendTools(ctx, inner, parsed.value.name) catch inner;

    // ── 6. Wrap the final envelope ─────────────────────────────────────
    const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, true, null, inner_with_tools);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ───────────────────────────────────────────────────────────────────────
// Disk persistence + live-reload helper
// ───────────────────────────────────────────────────────────────────────

/// Persist the just-added MCP server to `~/.config/nalar/config.json` and
/// hot-reload `di.llm_config` via `setLlmConfig` so subsequent agent
/// iterations see the new server through `buildMCPToolsRun`. Mirrors the
/// write sequence in `nalar_config_put.zig` (PUT /api/config/nalar):
/// read → mutate `mcp_servers` → write → re-parse + swap `llm_config`.
///
/// Returns the status string the agent sees in the `<persisted>` field
/// (`"true"` on success, `"false: <reason>"` on failure).
fn persistAndReload(ctx: ToolExecContext, server_name: []const u8) ![]u8 {
    const di = nalarcore.getSingleton() catch return try ctx.allocator.dupe(u8, "false: getSingleton failed");
    const env_ptr = di.environment orelse return try std.fmt.allocPrint(ctx.allocator, "false: environment unavailable", .{});
    // getDefaultConfigDir takes a non-const pointer but doesn't mutate.
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(env_ptr));

    const config_dir = config_mod.getDefaultConfigDir(ctx.allocator, environment) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "false: getDefaultConfigDir {s}", .{@errorName(err)});
    };
    defer ctx.allocator.free(config_dir);

    const config_path = std.fs.path.join(ctx.allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "false: path.join {s}", .{@errorName(err)});
    };
    defer ctx.allocator.free(config_path);

    // Ensure config dir exists.
    std.Io.Dir.cwd().createDirPath(ctx.io, config_dir) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "false: createDirPath {s}", .{@errorName(err)});
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

    // Write back atomically (truncate + write).
    const wfile = std.Io.Dir.createFileAbsolute(ctx.io, config_path, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "false: createFileAbsolute {s}", .{@errorName(err)});
    };
    var wbuf: [4096]u8 = undefined;
    {
        defer wfile.close(ctx.io);
        var writer = wfile.writer(ctx.io, &wbuf);
        writer.interface.writeAll(new_body) catch |err| {
            return try std.fmt.allocPrint(ctx.allocator, "false: writeAll {s}", .{@errorName(err)});
        };
        writer.flush() catch |err| {
            return try std.fmt.allocPrint(ctx.allocator, "false: flush {s}", .{@errorName(err)});
        };
    }

    // Hot-reload: re-parse + atomically swap di.llm_config.
    const env_for_reload: *std.process.Environ.Map = @constCast(@ptrCast(di.environment orelse environment));
    var new_cfg = config_mod.LlmConfig.init(di.allocator, ctx.io, null, env_for_reload) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "false: live reload parse {s}", .{@errorName(err)});
    };
    new_cfg.validate() catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return try std.fmt.allocPrint(ctx.allocator, "false: live reload validate {s}", .{@errorName(err)});
    };
    const new_ptr = di.allocator.create(config_mod.LlmConfig) catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return try std.fmt.allocPrint(ctx.allocator, "false: OOM {s}", .{@errorName(err)});
    };
    new_ptr.* = new_cfg;
    nalarcore.setLlmConfig(di, new_ptr);

    _ = server_name; // (used implicitly via mcp_servers in the JSON)
    return try ctx.allocator.dupe(u8, "true");
}

/// Build the on-disk JSON body for the new config. Strategy:
///   - If `existing` is non-null, parse it as a generic `std.json.Value`,
///     replace its `mcp_servers` field with the LIVE `LlmConfig.mcpServers()`,
///     and re-serialize.
///   - If `existing` is null, serialize just `{"mcp_servers": ...}`.
fn buildUpdatedConfigJson(ctx: ToolExecContext, existing: ?[]const u8) ![]u8 {
    const allocator = ctx.allocator;
    const live_mcp_servers = ctx.config.mcpServers() orelse .null;

    if (existing) |body| {
        // Parse existing as a generic Value so we can mutate just the
        // mcp_servers key without losing siblings (active_profile,
        // sub_agents, profiles_models, …).
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            // Fallback: malformed JSON → just emit mcp_servers alone.
            return try std.json.Stringify.valueAlloc(allocator, .{
                .mcp_servers = live_mcp_servers,
            }, .{ .whitespace = .indent_tab });
        };
        defer parsed.deinit();

        // Serialize + re-parse the live mcp_servers value so the new
        // ObjectMap owns independent copies of every nested string.
        const mcp_str = try std.json.Stringify.valueAlloc(allocator, live_mcp_servers, .{});
        defer allocator.free(mcp_str);
        var mcp_owned = try std.json.parseFromSlice(std.json.Value, allocator, mcp_str, .{
            .ignore_unknown_fields = true,
        });
        defer mcp_owned.deinit();

        const root = parsed.value;
        switch (root) {
            .object => |root_obj| {
                // Build a fresh ObjectMap by walking the existing root,
                // replacing mcp_servers with the live copy. The original
                // root_obj's values are borrowed from `parsed` so we
                // must NOT free them directly — `parsed.deinit()` handles
                // it when the scope exits. We transfer ownership of the
                // keys (duped) into the new map; the values stay borrowed.
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
                // Put the fresh mcp_servers entry.
                try new_obj.put(allocator, try allocator.dupe(u8, "mcp_servers"), mcp_owned.value);
                mcp_owned.value = .null; // ownership transferred to new_obj

                return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_obj }, .{
                    .whitespace = .indent_tab,
                });
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
    const reg = mcp_stdio.StdioRegistry.global(ctx.allocator);
    const client = reg.getOrSpawn(server_name, argv) catch return inner_xml;
    const req = ctx.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return inner_xml;
    defer ctx.allocator.free(req);
    client.send(req) catch return inner_xml;
    const resp = client.recv() catch return inner_xml;
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