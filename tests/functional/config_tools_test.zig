// Functional tests for the config.json `tools` default checklist (plan
// 2026-09-22-tools-menu-config-default-tools, decisions D2/D4).
//
// Zig port of `tests/functional/config_tools_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional tests for the config.json `tools` default checklist (plan
//   2026-09-22-tools-menu-config-default-tools, decisions D2/D4).
//
//   Verifies the wire round-trip of the top-level `tools` array through
//   GET/PUT /api/config/pabrik with the EXACT frontend wire shapes:
//
//     1. GET returns `tools: null` when the on-disk key is absent.
//     2. PUT of the whole config WITHOUT a `tools` key (a Settings save from
//        another tab) does NOT erase `tools` from disk (the PUT-strip
//        footgun — this is the test that catches a missing write-struct
//        field).
//     3. PUT with `"tools": [...]` persists and GET reflects it.
//     4. PUT `"tools": []` persists as an explicit empty list (≠ null).
//     5. PUT with an unknown tool name → 400 + a clear InvalidToolName
//        message, disk untouched.
//     6. PUT `"tools": null` preserves the existing value (the collapse of
//        absent ≡ null on the wire).
//
//   Each test boots a fresh pabrik against an isolated tmpdir HOME via the
//   shared preboot fixture pattern (config_simplify_test.py). Ports come
//   from the harness's random picker (never 8081).
//   """
//
// THE `preboot` FIXTURE IS INLINED HERE, AND IT INLINES THE SEED TIMING
// GAP. `web_search_config_test.py` imported this fixture verbatim ("imported
// rather than redefined: it is the platform-correct seeding path, and a
// second copy would drift"), so this helper was load-bearing for a second
// suite — which is exactly why the missing seam is written up below rather
// than papered over.
//
// Python had a module-level `@pytest.fixture def preboot(cfg)` that
// wrote config.json into a fresh tempdir layout and THEN spawned the
// binary, re-implementing `FunctionalHarness.boot` steps 1-5 by hand
// because there was no seam for "a config that already exists at boot".
// Zig has no cross-file fixture import at all, so the whole fixture is
// gone — but so is the ability it existed to provide: `Harness.boot`
// ALLOCATES the tempdir internally, so there is no path to write into
// before the binary starts. The only pre-boot seam the harness exposes is
// `BootOptions.stub_llm_profile`.
//
// So every test below boots with `stub_llm_profile = true` and then
// overwrites config.json with the real seed IMMEDIATELY, before the first
// request. That is sound because BOTH handlers under test re-read the file
// on every request (`pabrik_config_get.zig` opens `getDefaultConfigPath`
// per call; `pabrik_config_put.zig` re-parses the existing file per
// call) — nothing here is served from a boot-time cache.
//
// TODO(port): `BootOptions.config_json` — a pre-boot seed seam on
// `Harness.boot` (write these bytes at the platform-correct config path
// before step 7, the spawn). That is what would let this suite keep the
// Python's "the server never saw any other config" guarantee instead of
// the "overwritten immediately after boot" approximation above. Nothing
// in the four suites being ported together needs it; the approximation
// is exact for the assertions they make.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures / helpers
// ============================================================================

/// The single profile every seed carries.
///
/// Inlined from the Python module-level `PROFILE` dict, which existed so
/// `_base_config(**extra)` could splat the same fields into both the
/// on-disk seed and the PUT body.
const PROFILE_JSON =
    \\{"model":"tools-model","base_url":"https://tools.example.com","api_key":"tools-key","url_style":"openai"}
;

/// Where `getDefaultConfigDir` (Config.zig) actually writes config.json.
///
/// Mirrors that function's platform switch:
///
///   * macOS   — `~/Library/Application Support/pabrik`. `XDG_CONFIG_HOME`
///     is NOT consulted on this branch, so the harness's `<home>/.config`
///     shadow is irrelevant.
///   * Windows — `%APPDATA%/pabrik`, which the harness points at
///     `<home>/AppData/Roaming`.
///   * else    — `$XDG_CONFIG_HOME/pabrik` else `$HOME/.config/pabrik`;
///     the harness points `XDG_CONFIG_HOME` at `<home>/.config`.
///
/// Derived from `home` alone rather than the ambient environment, so a
/// CI runner's real `XDG_CONFIG_HOME` cannot make the assertion read a
/// path the server never wrote. Python's `_platform_config_dir` probed
/// `platform.system()` for the same reason.
fn platformConfigDir(home: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => harness.harnessPath(gpa, home, &.{ "Library", "Application Support", "pabrik" }),
        .windows => harness.harnessPath(gpa, home, &.{ "AppData", "Roaming", "pabrik" }),
        else => harness.harnessPath(gpa, home, &.{ ".config", "pabrik" }),
    };
}

fn platformConfigPath(home: []const u8) ![]u8 {
    return harness.harnessPath(gpa, home, &.{ ".config", "pabrik", "config.json" });
}

/// Write `contents` to the platform-correct config.json under `home`.
fn writeSeedConfig(home: []const u8, contents: []const u8) !void {
    const dir = try platformConfigDir(home);
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const path = try std.fs.path.join(gpa, &.{ dir, "config.json" });
    defer gpa.free(path);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Boot a harness and seed `seed` into its config.json before the first
/// request. Caller frees nothing — the harness owns the tempdir.
///
/// The seed is written AFTER boot; see the header note for why that is
/// sound and what `BootOptions.config_json` would do about it.
fn bootSeeded(seed: []const u8) !Harness {
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    errdefer h.deinit(io) catch {};
    try writeSeedConfig(h.temp_dir, seed);
    return h;
}

/// The seeded on-disk config: a profile-only document so the PUT
/// live-reload validates (backfill provides the credentials
/// `validate()` requires).
///
/// `tools_json` is the RAW JSON text for the `tools` value, or null to
/// omit the key — the Python `_base_config(**extra)` splat.
fn baseConfig(tools_json: ?[]const u8) ![]u8 {
    if (tools_json) |t| {
        return std.fmt.allocPrint(
            gpa,
            "{{\"profiles_models\":{{\"p1\":{s}}},\"active_profile\":\"p1\",\"tools\":{s}}}",
            .{ PROFILE_JSON, t },
        );
    }
    return std.fmt.allocPrint(
        gpa,
        "{{\"profiles_models\":{{\"p1\":{s}}},\"active_profile\":\"p1\"}}",
        .{PROFILE_JSON},
    );
}

/// A JSON array literal for a tool list, e.g. `["command","glob"]`.
fn toolsJson(names: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('[') catch return error.OutOfMemory;
    for (names, 0..) |n, i| {
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.writeByte('"') catch return error.OutOfMemory;
        out.writer.writeAll(n) catch return error.OutOfMemory;
        out.writer.writeByte('"') catch return error.OutOfMemory;
    }
    out.writer.writeByte(']') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The EXACT whole-config shape `PabrikSettings.vue` sends on Save from
/// any tab: profiles + operational settings, no top-level LLM defaults.
///
/// `tools` is the RAW JSON text for the value, or null to OMIT the key
/// (the Python `tools_marker=...` Ellipsis sentinel, which is how
/// "another tab's save" is spelled).
fn settingsBody(tools: ?[]const u8) ![]u8 {
    const tail = if (tools) |t| try std.fmt.allocPrint(gpa, ",\"tools\":{s}", .{t}) else try gpa.dupe(u8, "");
    defer gpa.free(tail);
    return std.fmt.allocPrint(
        gpa,
        "{{\"profiles\":{{\"p1\":{s}}},\"active_profile\":\"p1\",\"mcp_servers\":null," ++
            "\"notify_on_complete\":false,\"notify_on_error\":false,\"web_launch_enabled\":false," ++
            "\"model_compaction_size_kb\":100,\"max_capacity_token_model\":null," ++
            "\"compaction_threshold_percent\":null,\"retry_delay_ms\":0{s}}}",
        .{ PROFILE_JSON, tail },
    );
}

/// The on-disk `tools` value, as a parsed `json.Value`.
///
/// A `harness.Json` borrows its Response body, so this parses the FILE
/// bytes directly (with `.alloc_always`, because the value has to outlive
/// the caller holding the bytes).
fn onDiskTools(home: []const u8) !std.json.Parsed(std.json.Value) {
    const path = try platformConfigPath(home);
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
}

/// Does a JSON value equal the tool list `want`, in order?
///
/// Python's `== seeded` compares lists element-wise; an absent key or a
/// JSON `null` compares unequal to any list, INCLUDING the empty one —
/// which is what makes test (d) a real assertion rather than a tautology.
fn toolsEqual(v: std.json.Value, want: []const []const u8) bool {
    const arr = switch (v) {
        .array => |a| a,
        else => return false,
    };
    if (arr.items.len != want.len) return false;
    for (arr.items, 0..) |item, i| {
        const s = switch (item) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, s, want[i])) return false;
    }
    return true;
}

/// Render a `json.Value` for a failure message. Owned.
///
/// Hand-written rather than `{f}`-formatted: `std.json.dynamic.Value` has
/// no `format` member, and re-serializing through `Stringify` would print
/// a SUCCESS value as `"command"` — which reads like a pass.
fn describeTools(v: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    switch (v) {
        .null => out.writer.writeAll("null") catch return error.OutOfMemory,
        .array => |arr| {
            out.writer.writeByte('[') catch return error.OutOfMemory;
            for (arr.items, 0..) |item, i| {
                if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
                switch (item) {
                    .string => |s| out.writer.print("\"{s}\"", .{s}) catch return error.OutOfMemory,
                    else => out.writer.writeAll("<non-string>") catch return error.OutOfMemory,
                }
            }
            out.writer.writeByte(']') catch return error.OutOfMemory;
        },
        else => out.writer.writeAll("<not a list>") catch return error.OutOfMemory,
    }
    return out.toOwnedSlice();
}

/// `GET /api/config/pabrik` must carry a `tools` key that is exactly
/// `want` (as a JSON array).
fn expectWireTools(doc: *const harness.Json, raw_body: []const u8, want: []const []const u8) !void {
    const v = doc.get("tools") orelse {
        std.debug.print("tools key missing from GET wire: {s}\n", .{raw_body});
        return error.TestUnexpectedResult;
    };
    if (toolsEqual(v, want)) return;
    const desc = try describeTools(v);
    defer gpa.free(desc);
    std.debug.print("GET wire tools = {s}\n", .{desc});
    return error.TestUnexpectedResult;
}

/// `GET /api/config/pabrik` must carry a PRESENT `tools` key holding
/// JSON `null` — the "legacy defaults" state.
fn expectWireToolsNull(doc: *const harness.Json, raw_body: []const u8) !void {
    const v = doc.get("tools") orelse {
        std.debug.print("tools key missing from GET wire: {s}\n", .{raw_body});
        return error.TestUnexpectedResult;
    };
    if (v == .null) return;
    const desc = try describeTools(v);
    defer gpa.free(desc);
    std.debug.print("expected tools: null, got {s}\n", .{desc});
    return error.TestUnexpectedResult;
}

/// The on-disk `tools` value must equal `want`.
fn expectDiskTools(home: []const u8, want: []const []const u8) !void {
    var parsed = try onDiskTools(home);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const v = root.get("tools") orelse {
        std.debug.print("config.json has no `tools` key at all\n", .{});
        return error.TestUnexpectedResult;
    };
    if (toolsEqual(v, want)) return;
    const desc = try describeTools(v);
    defer gpa.free(desc);
    std.debug.print("on-disk tools = {s}\n", .{desc});
    return error.TestUnexpectedResult;
}

/// `GET /api/config/pabrik`, asserted 200.
fn getConfig(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
}

// ============================================================================
// (a) GET returns tools: null when the key is absent
// ============================================================================

// A config.json without `tools` serves `tools: null` on the wire — the
// key must be PRESENT so the frontend can tell 'legacy defaults' from a
// backend that never shipped the field.
test "get_returns_tools_null_when_key_absent" {
    try harness.requirePabrikBin(io, gpa);

    const seed = try baseConfig(null);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectWireToolsNull(&doc, r.body);
}

// ============================================================================
// (b) Settings save WITHOUT a tools key must not erase it
// ============================================================================

// Seed `tools` first, then PUT the whole config from another tab (no
// `tools` key). The on-disk list and GET must both survive — this is the
// PUT-strip footgun from plan §2.2.
test "put_without_tools_key_preserves_on_disk_value" {
    try harness.requirePabrikBin(io, gpa);

    const seeded = [_][]const u8{ "command", "read_file", "glob" };
    const seeded_json = try toolsJson(&seeded);
    defer gpa.free(seeded_json);
    const seed = try baseConfig(seeded_json);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Sanity: the seed is visible before the save.
    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectWireTools(&doc, r.body, &seeded);
    }

    // Another tab's Settings save — whole config, NO tools key.
    {
        const body = try settingsBody(null);
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectWireTools(&doc, r.body, &seeded);
    }
    try expectDiskTools(h.temp_dir, &seeded);
}

// ============================================================================
// (c) PUT with a tools array persists and GET reflects it
// ============================================================================

test "put_with_tools_array_persists" {
    try harness.requirePabrikBin(io, gpa);

    const seed = try baseConfig(null);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const new_list = [_][]const u8{ "command", "write_file", "kanban_list" };
    const new_json = try toolsJson(&new_list);
    defer gpa.free(new_json);
    {
        const body = try settingsBody(new_json);
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectWireTools(&doc, r.body, &new_list);
    }
    try expectDiskTools(h.temp_dir, &new_list);
}

// ============================================================================
// (d) PUT "tools": [] persists as an explicit empty list
// ============================================================================

// `[]` is the explicit-zero checklist (D2). It must round-trip as an
// empty ARRAY — collapsing back to null would snap the UI to the 25
// legacy defaults.
test "put_empty_tools_array_persists" {
    try harness.requirePabrikBin(io, gpa);

    const seeded = [_][]const u8{"command"};
    const seeded_json = try toolsJson(&seeded);
    defer gpa.free(seeded_json);
    const seed = try baseConfig(seeded_json);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        const body = try settingsBody("[]");
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    // Python asserted three things here, and only the third is distinct:
    // the key is present, it equals `[]`, and it is NOT null. The
    // second implies the third in Zig's type system — an absent key and a
    // JSON null are both `.null`/missing, and `expectWireTools` fails on
    // both — so `[]` vs null is asserted by construction.
    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (doc.get("tools") == null) {
        std.debug.print("tools key missing from GET wire: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const empty: [0][]const u8 = .{};
    try expectWireTools(&doc, r.body, &empty);

    const empty_disk: [0][]const u8 = .{};
    try expectDiskTools(h.temp_dir, &empty_disk);
}

// ============================================================================
// (e) Unknown tool name -> 400 + clear message
// ============================================================================

test "put_unknown_tool_name_returns_400" {
    try harness.requirePabrikBin(io, gpa);

    const seeded = [_][]const u8{ "command", "read_file" };
    const seeded_json = try toolsJson(&seeded);
    defer gpa.free(seeded_json);
    const seed = try baseConfig(seeded_json);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const bad_list = [_][]const u8{ "command", "definitely_not_a_tool" };
    const bad_json = try toolsJson(&bad_list);
    defer gpa.free(bad_json);
    {
        const body = try settingsBody(bad_json);
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const err = doc.str("error") orelse "";
        if (std.mem.indexOf(u8, err, "InvalidToolName") == null) {
            std.debug.print("missing InvalidToolName in 400 body: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, err, "definitely_not_a_tool") == null) {
            std.debug.print("400 body does not name the offending tool: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // Validation runs before any write — the rejected list never lands.
    try expectDiskTools(h.temp_dir, &seeded);
}

// ============================================================================
// (f) PUT "tools": null preserves the existing value
// ============================================================================

// An explicit JSON null parses to the same `null` as an absent key (the
// desired collapse) -> no change. A Save that sends `tools: null` must
// not wipe the list.
test "put_explicit_null_preserves_existing_value" {
    try harness.requirePabrikBin(io, gpa);

    const seeded = [_][]const u8{ "command", "glob" };
    const seeded_json = try toolsJson(&seeded);
    defer gpa.free(seeded_json);
    const seed = try baseConfig(seeded_json);
    defer gpa.free(seed);

    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        const body = try settingsBody("null");
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectWireTools(&doc, r.body, &seeded);
    }
    try expectDiskTools(h.temp_dir, &seeded);
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = PROFILE_JSON;
    _ = platformConfigDir;
    _ = platformConfigPath;
    _ = writeSeedConfig;
    _ = bootSeeded;
    _ = baseConfig;
    _ = toolsJson;
    _ = settingsBody;
    _ = onDiskTools;
    _ = toolsEqual;
    _ = describeTools;
    _ = expectWireTools;
    _ = expectWireToolsNull;
    _ = expectDiskTools;
    _ = getConfig;
}
