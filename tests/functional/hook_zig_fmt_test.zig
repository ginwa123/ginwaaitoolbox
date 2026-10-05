//! The project hook runs zig fmt on edited Zig files.
//!
//! The hook itself (.pabrik/hooks/register_hook.lua) is the deliverable, and it
//! runs INSIDE pabrik's vendored Lua interpreter, on every tool dispatch. There
//! is no way to reach it over HTTP without driving a whole LLM agent loop, so
//! these tests execute the real hook file through a Lua interpreter and assert
//! on what it did to the file on disk.
//!
//! Vendored Lua is 5.4.9 (vendor/lua/lua.h: LUA_VERSION_RELEASE 9) and the
//! system lua5.4 here is also 5.4.9, so running the shipped file under the
//! system interpreter exercises the same semantics pabrik gets. The test skips
//! when no system Lua is present rather than silently passing.
//!
//! Behaviour under test: a .zig file edited by the agent comes out canonically
//! formatted, and `zig fmt` rewrites the WHOLE file — pre-existing lines that
//! were not fmt-clean get reformatted too. That whole-file rewrite is intended,
//! not a bug: it is what "formatted" means for Zig, and the cleanup is wanted.
//!
//! Zig port of `tests/functional/hook_zig_fmt_test.py` (same test names, same
//! order).
//!
//! Run:
//!     PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
//!       zig test tests/functional/hook_zig_fmt_test.zig
//!
//! TWO PATH FACTS WORTH KNOWING BEFORE READING THE HELPERS
//! -------------------------------------------------------
//! 1. `HOOK` is spelled repo-root-RELATIVE here (`.pabrik/hooks/register_hook.lua`)
//!    and resolved to an ABSOLUTE path before it is embedded in the Lua
//!    driver. The Python used `str(HOOK)` on a `Path(__file__).resolve()`
//!    -derived constant, i.e. it was already absolute — and it has to be,
//!    because the driver runs with `cwd` set to the fixture project dir, where
//!    a relative hook path would resolve to nothing. Relative-to-cwd is the
//!    convention this package already relies on (`harness.resolvePabrikBin`
//!    probes `zig-out/bin/...`; `tests/functional/build.zig` pins the runner
//!    CWD to the repo root).
//! 2. `_fmt_clean` shells out to `zig fmt --check`, and the HOOK itself
//!    shells out to `zig fmt`. Neither is `requirePabrikBin`-gated: the
//!    `pabrik` binary is irrelevant here, and the Python had no such gate
//!    either.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The project hook under test, relative to the repo root. See header note 1.
const HOOK_REL = ".pabrik/hooks/register_hook.lua";

/// Python's `subprocess.run(..., timeout=60)` on the hook driver.
const HOOK_RUN_TIMEOUT_MS: i64 = 60_000;

/// Python's `subprocess.run(..., timeout=30)` on `zig fmt --check`.
const FMT_CHECK_TIMEOUT_MS: i64 = 30_000;

/// Python's `_lua()`: `shutil.which("lua5.4") or shutil.which("lua")`, and
/// `pytest.skip` when neither is present.
///
/// `which()` answers "is there an executable by this name on PATH", so the
/// port's probe is "does spawning it succeed" and NOT "does it exit 0":
/// `lua -v` writes the version banner to STDERR on some builds and its exit
/// status is not the question being asked. The returned slice is owned and
/// must be freed; it is a `name`, not a path, so `PATH` does the lookup.
fn luaExe() ![]u8 {
    for ([_][]const u8{ "lua5.4", "lua" }) |name| {
        // The probe's captured streams are still owned by the caller:
        // `RunResult` hands over `stdout` / `stderr` buffers whether or
        // not the test looks at them, and the DebugAllocator reports
        // them at the end of the test.
        const res = std.process.run(gpa, io, .{ .argv = &.{ name, "-v" } }) catch continue;
        gpa.free(res.stdout);
        gpa.free(res.stderr);
        return gpa.dupe(u8, name);
    }
    std.debug.print("no system lua available to run the project hook\n", .{});
    return error.SkipZigTest;
}

/// Absolute path of a repo-root-relative file. Owned.
///
/// `realpath` rather than `cwd`-relative concatenation: the Lua driver runs
/// with the fixture dir as its CWD, so anything it is handed has to already
/// be absolute. `realpath` also fails loudly on a missing file, which is what
/// `assert HOOK.exists()` did.
fn repoFileAbs(rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, rel, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => {
            std.debug.print("project hook missing: {s}\n", .{rel});
            return error.TestUnexpectedResult;
        },
        else => return err,
    };
    return gpa.dupe(u8, buf[0..n]);
}

/// Render `s` as a Lua SHORT-STRING literal (double-quoted).
///
/// The Python f-string interpolated `{str(HOOK)!r}` / `{arguments!r}` — a
/// Python `repr`, which for these inputs happens to be a valid Lua string but
/// escapes differently (`\'`, and `\x` for non-printables). Lua's own short
/// string escapes are the correct target, so the escapes are spelled out
/// here rather than borrowed.
fn luaString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    for (s) |c| switch (c) {
        '\\' => out.writer.writeAll("\\\\") catch return error.OutOfMemory,
        '"' => out.writer.writeAll("\\\"") catch return error.OutOfMemory,
        '\n' => out.writer.writeAll("\\n") catch return error.OutOfMemory,
        '\r' => out.writer.writeAll("\\r") catch return error.OutOfMemory,
        '\t' => out.writer.writeAll("\\t") catch return error.OutOfMemory,
        else => out.writer.writeByte(c) catch return error.OutOfMemory,
    };
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Drive the REAL hook: load it, call init("post_tool_use", data).
///
/// `subprocess.CompletedProcess` in Python; in Zig the caller gets the
/// `std.process.RunResult` and owns its `stdout` / `stderr`, which is the
/// same information (returncode + captured streams) with one fewer wrapper
/// to keep in sync.
///
/// `std.process.run`'s `.cwd = .{ .path = ... }` is Python's `cwd=`;
/// `.timeout` is Python's `timeout=` — the latter matters here because the
/// hook shells out to `zig fmt` and a wedged child would otherwise hang the
/// suite forever.
fn runHook(lua: []const u8, hook_path: []const u8, cwd: []const u8, tool_name: []const u8, arguments: []const u8) !std.process.RunResult {
    const hook_lit = try luaString(gpa, hook_path);
    defer gpa.free(hook_lit);
    const tool_lit = try luaString(gpa, tool_name);
    defer gpa.free(tool_lit);
    const args_lit = try luaString(gpa, arguments);
    defer gpa.free(args_lit);
    const cwd_lit = try luaString(gpa, cwd);
    defer gpa.free(cwd_lit);

    const driver = try std.fmt.allocPrint(gpa,
        \\local hook = assert(loadfile({s}))
        \\hook()
        \\local data = {{
        \\  tool_name = {s},
        \\  arguments = {s},
        \\  session_id = "sess_test",
        \\  cwd = {s},
        \\  model = "test",
        \\}}
        \\local ret = init("post_tool_use", data)
        \\assert(ret == nil, "hook must return nil, got " .. tostring(ret))
        \\
    , .{ hook_lit, tool_lit, args_lit, cwd_lit });
    defer gpa.free(driver);

    return std.process.run(gpa, io, .{
        .argv = &.{ lua, "-e", driver },
        .cwd = .{ .path = cwd },
        .timeout = timeoutMs(HOOK_RUN_TIMEOUT_MS),
    });
}

/// `subprocess.run(timeout=<ms>)` — Python's wall-clock-free "give the
/// child N ms" budget, as `std.process.RunOptions.timeout`.
///
/// `Io.Timeout.duration` is a `Clock.Duration`, which is a
/// (raw duration, clock) PAIR rather than a bare duration, and its
/// constructors live on the RAW half. `.awake` is monotonic: an NTP step
/// during a run must not extend or collapse the budget.
fn timeoutMs(ms: i64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
}

/// Exit code of a finished child, or null if a signal stopped it.
///
/// `Child.Term` is a tagged union, NOT an optional: `.exited` is a `u8`
/// field, so `res.term.exited orelse ...` does not compile and a bare
/// `res.term.exited != 0` would silently read the wrong field on a
/// signalled run.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// `_fmt_clean(path)` — `zig fmt --check <path>` exits 0.
///
/// Python let a missing `zig` CLI raise out of the helper. The port keeps
/// that: a machine with no `zig` on PATH cannot verify the hook's
/// behaviour, and reporting that as a PASS would be the one outcome that
/// hides a real regression.
fn fmtClean(path: []const u8) !bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "fmt", "--check", path },
        .timeout = timeoutMs(FMT_CHECK_TIMEOUT_MS),
    }) catch |err| {
        std.debug.print("`zig fmt --check` could not run ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    return exitCode(res.term) == 0;
}

/// Read a fixture file. Owned.
fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

fn writeFile(path: []const u8, content: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

/// Python's `workdir` fixture: a scratch dir holding one fmt-clean and one
/// not-fmt-clean .zig file.
///
/// A `makeScratchDir` fixture, NOT `std.testing.tmpDir`: the latter lands in
/// `<cwd>/.zig-cache/tmp/`, which for this package is inside the git
/// worktree, and the hook resolves the fixture path relative to `cwd` — a
/// fixture inside the repo would make the "did the hook touch anything
/// outside the project?" assertions read the wrong tree.
const Fixture = struct {
    scratch: []u8,
    proj: []u8,

    /// Delete the scratch tree, then the two path buffers.
    ///
    /// A single `defer` rather than three: the paths must outlive
    /// `cleanupExtraDir`, and three separate `defer`s would put that
    /// ordering at the mercy of LIFO registration order at every call
    /// site.
    fn deinit(self: *Fixture) void {
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.proj);
        gpa.free(self.scratch);
    }

    /// An ABSOLUTE path inside the fixture project. Owned by the caller.
    fn path(self: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.proj, rel });
    }
};

fn makeWorkdir() !Fixture {
    const scratch = try harness.makeScratchDir(gpa);
    errdefer gpa.free(scratch);
    const proj = try std.fs.path.join(gpa, &.{ scratch, "proj" });
    errdefer gpa.free(proj);
    const src = try std.fs.path.join(gpa, &.{ proj, "src" });
    defer gpa.free(src);
    try std.Io.Dir.cwd().createDirPath(io, src);

    const clean = try std.fs.path.join(gpa, &.{ src, "clean.zig" });
    defer gpa.free(clean);
    try writeFile(clean, "pub fn main() void {\n    const x = 1;\n}\n");

    // Multi-line call args that zig fmt collapses onto one long line.
    const legacy = try std.fs.path.join(gpa, &.{ src, "legacy.zig" });
    defer gpa.free(legacy);
    try writeFile(legacy,
        \\pub fn main() void {
        \\    call(veryLongArgumentName,
        \\        anotherRatherLongArgument,
        \\        &.{});
        \\}
        \\
    );

    return .{ .scratch = scratch, .proj = proj };
}

/// Assert the hook driver exited 0, printing stderr when it did not.
///
/// Python repeated `assert r.returncode == 0, f"hook errored: {r.stderr}"`
/// seven times. One helper keeps the message identical everywhere and
/// frees the captured streams on every path.
fn expectHookOk(res: std.process.RunResult) !void {
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook errored (rc={?}): {s}\n", .{ code, res.stderr });
    }
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    if (code == null or code.? != 0) return error.TestUnexpectedResult;
}

/// `re.search(r"&\.\{\s*1,\s*2\s*\}", text)`.
///
/// Hand-matched rather than pulled through a regex engine: the pattern is
/// three tokens with only `\s` between them, and `re.search` semantics are
/// "anywhere in the string", so the scan below is the whole of it. Zig's
/// stdlib ships no regex, and the alternative — asserting the literal
/// `&.{1, 2}` — would be asserting MY spacing rather than the behaviour,
/// which is exactly what the Python comment warned against (Zig 0.16 renders
/// `.{1, 2}` as `.{ 1, 2 }`).
fn survivesFmtEdit(text: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "&.{")) |hit| {
        if (brace12At(text, hit)) return true;
        at = hit + 1;
    }
    return false;
}

fn brace12At(text: []const u8, start: usize) bool {
    var p = skipSpace(text, start + "&.{".len);
    if (p >= text.len or text[p] != '1') return false;
    p = skipSpace(text, p + 1);
    if (p >= text.len or text[p] != ',') return false;
    p = skipSpace(text, p + 1);
    if (p >= text.len or text[p] != '2') return false;
    p = skipSpace(text, p + 1);
    return p < text.len and text[p] == '}';
}

/// `\s` in the pattern above: the Python regex class is `[ \t\r\n\f\v]`, and
/// the fixture files never contain the last two, but matching them costs
/// nothing and keeps the port honest.
fn skipSpace(text: []const u8, from: usize) usize {
    var p = from;
    while (p < text.len) : (p += 1) {
        switch (text[p]) {
            ' ', '\t', '\r', '\n', '\x0c', '\x0b' => {},
            else => break,
        }
    }
    return p;
}

// The shipped hook must parse under the same Lua pabrik embeds.
test "hook_file_is_valid_lua" {
    const lua = try luaExe();
    defer gpa.free(lua);

    // Python: `assert HOOK.exists()`.
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    const hook_lit = try luaString(gpa, hook);
    defer gpa.free(hook_lit);
    const driver = try std.fmt.allocPrint(gpa, "assert(loadfile({s}))", .{hook_lit});
    defer gpa.free(driver);

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ lua, "-e", driver },
        .timeout = timeoutMs(FMT_CHECK_TIMEOUT_MS),
    });
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook failed to parse (rc={?}): {s}\n", .{ code, res.stderr });
        return error.TestUnexpectedResult;
    }
}

// The headline behaviour: an edit lands canonically formatted.
//
// Without the hook the edit sits in whatever shape the model wrote it and
// the file is left dirty. This is the payoff of the whole change: new Zig
// comes out canonical without the model having to remember.
test "formats_the_edited_region" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn main() void {\n    const x    =    1;\n    const y = 2;\n}\n");
    // Python: `assert not _fmt_clean(target)` — the precondition, and it
    // must stay an assertion rather than a comment, or a `zig fmt` that
    // silently started accepting the dirty file would make the rest of
    // the test vacuous.
    if (try fmtClean(target)) {
        std.debug.print("precondition: the edit did not make the file dirty\n", .{});
        return error.TestUnexpectedResult;
    }

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/clean.zig\"}");
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        const text = try readFile(target);
        defer gpa.free(text);
        std.debug.print("hook left an edited file unformatted:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    // The read is hoisted out of the assertion so it can be freed: an
    // owned buffer cannot be handed straight to `expectEqualStrings`
    // AND deferred at the same time.
    const formatted = try readFile(target);
    defer gpa.free(formatted);
    try testing.expectEqualStrings(
        "pub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n",
        formatted,
    );
}

// Pre-existing unformatted lines are normalised too — by design.
//
// `zig fmt` is a whole-file rewriter. Editing a line of a file that was
// already not-fmt-clean sweeps the rest of the file canonical as well.
// That churn is intentional: it is what "this file is formatted" means,
// and it only ever lands in the file the agent just edited.
test "formats_whole_file_not_just_the_edit" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/legacy.zig");
    defer gpa.free(target);
    try writeFile(target,
        \\pub fn main() void {
        \\    call(veryLongArgumentName,
        \\        anotherRatherLongArgument,
        \\        &.{1, 2});
        \\}
        \\
    );
    if (try fmtClean(target)) {
        std.debug.print("precondition: file started out not-fmt-clean\n", .{});
        return error.TestUnexpectedResult;
    }

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/legacy.zig\"}");
    try expectHookOk(res);

    const text = try readFile(target);
    defer gpa.free(text);

    if (!try fmtClean(target)) {
        std.debug.print("hook did not bring the whole file to canonical form:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    // The edit must survive the reformat.
    if (!survivesFmtEdit(text)) {
        std.debug.print("the actual edit did not survive formatting:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, text, "veryLongArgumentName") == null) {
        std.debug.print("existing code was lost:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// A mid-edit file that does not parse must be left byte-for-byte alone.
//
// zig fmt exits non-zero without writing on a parse error, so a half-typed
// file is never mangled. This asserts the real behaviour rather than
// trusting the manual.
test "syntax_broken_file_is_not_corrupted" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    const broken = "pub fn main() void {\n    const x = ;\n}\n";
    try writeFile(target, broken);

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/clean.zig\"}");
    try expectHookOk(res);

    const text = try readFile(target);
    defer gpa.free(text);
    if (!std.mem.eql(u8, broken, text)) {
        std.debug.print("hook corrupted a syntactically broken file:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// A brand-new .zig file is formatted like any other.
test "new_file_is_formatted" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/fresh.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn f() void {\n    const a    =    1;\n}\n");

    const res = try runHook(lua, hook, fx.proj, "write_file", "{\"path\": \"src/fresh.zig\", \"content\": \"x\"}");
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        const text = try readFile(target);
        defer gpa.free(text);
        std.debug.print("a newly created .zig did not come out canonical:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// Tool arguments can carry an absolute path.
test "absolute_path_is_handled" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn main() void {\n    const q    =    3;\n}\n");

    const args = try std.fmt.allocPrint(gpa, "{{\"path\": \"{s}\"}}", .{target});
    defer gpa.free(args);

    const res = try runHook(lua, hook, fx.proj, "text_replace", args);
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        std.debug.print("absolute-path edit was not formatted\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Only .zig and the prettier set are handled; other paths/tools change nothing.
test "non_zig_and_unknown_tools_are_noops" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/notes.txt");
    defer gpa.free(target);
    const notes = "const    x=1\n";
    try writeFile(target, notes);

    {
        const res = try runHook(lua, hook, fx.proj, "write_file", "{\"path\": \"src/notes.txt\", \"content\": \"x\"}");
        try expectHookOk(res);
    }
    {
        const text = try readFile(target);
        defer gpa.free(text);
        if (!std.mem.eql(u8, notes, text)) {
            std.debug.print("hook touched a non-.zig file:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }

    // A read-only tool that happens to carry a .zig path must not format.
    const z = try fx.path("src/clean.zig");
    defer gpa.free(z);
    const before = try readFile(z);
    defer gpa.free(before);
    {
        const res = try runHook(lua, hook, fx.proj, "read_file", "{\"path\": \"src/clean.zig\"}");
        try expectHookOk(res);
    }
    {
        const text = try readFile(z);
        defer gpa.free(text);
        if (!std.mem.eql(u8, before, text)) {
            std.debug.print("hook formatted on a non-edit tool:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

// A deleted or never-written target must fail open, not raise.
test "missing_file_does_not_error" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/gone.zig\"}");
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook errored on a missing file (rc={?}): {s}\n", .{ code, res.stderr });
    }
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    if (code == null or code.? != 0) return error.TestUnexpectedResult;
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = luaExe;
    _ = repoFileAbs;
    _ = luaString;
    _ = runHook;
    _ = timeoutMs;
    _ = exitCode;
    _ = fmtClean;
    _ = readFile;
    _ = writeFile;
    _ = Fixture;
    _ = Fixture.deinit;
    _ = Fixture.path;
    _ = makeWorkdir;
    _ = expectHookOk;
    _ = survivesFmtEdit;
    _ = brace12At;
    _ = skipSpace;
    _ = Harness.boot;
}
