# Auto-Init Config File on First Run Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `~/.config/nalar/config.json` does not exist (default-path first-run scenarios like CI smoke tests, fresh installs, dev resets), auto-create a default `config.json` with empty placeholder values so the server can start without manual setup. Existing user-provided configs are left untouched.

**Architecture:** Add a `writeDefaultConfig()` helper to `Config.zig` that takes a path, recursively creates any missing parent directories, and writes a JSON file with placeholder values via `std.Io.Dir.createFile`. In `LlmConfig.init()`, catch `error.FileNotFound` from `openFileAbsolute`, call the helper, log an info message, and retry. In `main.zig`, change the strict `try llm_config.validate()` to a `catch |err| std.log.warn(...)` so an empty placeholder config doesn't block startup — downstream LLM calls will fail naturally with a clear "empty api_key" error until the user fills in the config.

**Tech Stack:** Zig 0.16, `std.Io.Dir.makePath` (create parent dirs), `std.Io.Dir.createFile` (write file with `.truncate = true`), `std.Io.Dir.openFileAbsolute` (read-back verification in tests).

---

## File Structure

| File | Responsibility | New / Modified |
|------|----------------|----------------|
| `src/modules/config/Config.zig` | Add `defaultConfigJson` const (the embedded template). Add `writeDefaultConfig()` helper. Catch `error.FileNotFound` in `init()` and auto-create + retry. | Modified |
| `src/modules/config/config_test.zig` | Add tests: `writeDefaultConfig creates a valid JSON file`, `init auto-creates config.json when path does not exist`, `init does NOT auto-create when file exists with parse error`. | Modified |
| `src/main.zig` | Change `try llm_config.validate()` (line 32) to a `catch |err| std.log.warn(...)` so an empty config doesn't abort startup. | Modified |

**Why this decomposition:**
- All file-IO logic stays in `Config.zig` — `main.zig` doesn't need to know about paths or directory creation. The change is invisible to callers.
- `validate()` itself stays strict (returns `error.MissingRequiredField`) for callers that want hard validation (e.g. `nalar_config_put.zig:234`, which rejects broken configs that the user just PUT-ed). Only `main.zig`'s policy changes — the strict path keeps the PUT flow safe.
- Auto-init only fires when `path = null` (the default platform path). Explicit `--config /path.json` calls still surface `error.FileNotFound` unchanged — this matches user intent: "I told you where to find it, don't second-guess me."
- The default config is a `const []u8` template — zero runtime cost, just a `writeFile` to disk.

---

## Chunk 1: Add `writeDefaultConfig()` helper

### Task 1: Add the `defaultConfigJson` const and `writeDefaultConfig()` helper

**Files:**
- Modify: `src/modules/config/Config.zig` (add helpers after `getDefaultConfigPath` at line 1141)
- Modify: `src/modules/config/config_test.zig` (add test)

- [ ] **Step 1: Read the existing helper structure to confirm placement**

`Config.zig` has `getDefaultConfigDir` (line 1104), `getDefaultConfigPath` (line 1137), and `loadDefault` (line 1143). Add `defaultConfigJson` and `writeDefaultConfig` between `getDefaultConfigPath` and `loadDefault`. The file-IO pattern to mirror is `std.Io.Dir.openFileAbsolute` (line 233 in `init`) and the read loop at lines 239-245.

- [ ] **Step 2: Write the failing test for `writeDefaultConfig`**

Append to `config_test.zig`:

```zig
test "writeDefaultConfig creates a valid JSON config file at the given path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build an absolute path inside the tmp dir; the file does not exist yet.
    const config_path = try tmp.dir.realPathAlloc(std.testing.io, allocator);
    defer allocator.free(config_path);
    const full_path = try std.fs.path.join(allocator, &.{ config_path, "config.json" });
    defer allocator.free(full_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, full_path);

    // Read it back and verify the JSON shape.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, full_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("api_key") != null);
    try std.testing.expect(obj.get("model") != null);
    try std.testing.expect(obj.get("base_url") != null);
    try std.testing.expectEqualStrings("openai", obj.get("url_style").?.string);
    try std.testing.expectEqual(@as(i64, 100), obj.get("model_compaction_size_kb").?.integer);
    try std.testing.expectEqual(@as(bool, false), obj.get("notify_on_complete").?.boolean);
}
```

- [ ] **Step 3: Run the test, confirm it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: FAIL — `error: no member named 'writeDefaultConfig' in 'config.LlmConfig'`.

- [ ] **Step 4: Add the helpers to `Config.zig`**

Between `getDefaultConfigPath` (ends at line 1141) and `loadDefault` (starts at line 1143), add:

```zig
/// The default `config.json` content written on first run (when no
/// config file exists at the platform-default path). All required
/// fields are present as empty strings — the user MUST edit this
/// file and add `api_key`, `model`, and `base_url` before LLM calls
/// will succeed. Optional fields are populated with their documented
/// defaults so a subsequent `LlmConfig.init` re-parse yields a
/// well-formed `LlmConfig`.
pub const defaultConfigJson: []const u8 =
    \\{
    \\  "api_key": "",
    \\  "model": "",
    \\  "base_url": "",
    \\  "url_style": "openai",
    \\  "model_compaction_size_kb": 100,
    \\  "notify_on_complete": false
    \\}
;

/// Write `defaultConfigJson` to `path`, creating any missing parent
/// directories (mkdir -p semantics). Overwrites any existing file at
/// the path (the caller is expected to NOT call this on an
/// already-existing config — see `LlmConfig.init` for the auto-init
/// flow that gates the call on `error.FileNotFound`).
///
/// Returns `error.ConfigFileNotFound` when the parent directory
/// cannot be created (e.g. permission denied, invalid path) or
/// `error.ConfigFileReadError` on a write failure. The caller is
/// expected to log the error and surface it as appropriate.
pub fn writeDefaultConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LlmConfig.LoadError!void {
    // Ensure the parent directory exists (mkdir -p). The std.Io
    // API on Linux is `Dir.makePath(io, sub_path)` for relative
    // paths and `Dir.makePathAbsolute(io, abs_path)` for absolute.
    // We check which form we have and dispatch accordingly.
    if (std.fs.path.dirname(path)) |parent| {
        if (std.fs.path.isAbsolute(parent)) {
            std.Io.Dir.makePathAbsolute(io, parent) catch |err| {
                std.log.err("Failed to create config dir {s}: {s}", .{ parent, @errorName(err) });
                return error.ConfigDirNotFound;
            };
        } else {
            var cwd = std.Io.Dir.cwd();
            cwd.makePath(io, parent) catch |err| {
                std.log.err("Failed to create config dir {s}: {s}", .{ parent, @errorName(err) });
                return error.ConfigDirNotFound;
            };
        }
    }

    // Write the default config. .truncate = true means any stale
    // file at `path` is replaced atomically by the kernel.
    const file = Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch |err| {
        std.log.err("Failed to create config file {s}: {s}", .{ path, @errorName(err) });
        return error.ConfigFileReadError;
    };
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(defaultConfigJson);
    try writer.interface.flush();
}
```

> **NOTE for implementer**: The exact `std.Io.Dir.makePathAbsolute` / `makePath` signatures may differ slightly in this Zig 0.16 build. If `makePathAbsolute` doesn't exist as a top-level function, use the alternative pattern: open the parent via `std.Io.Dir.openDirAbsolute(io, parent, .{})` (which asserts the path is absolute and panics otherwise), then call `.makePath(io, "")` on it (no-op if the dir already exists). Verify the actual API surface by grepping `rg "pub fn makePath" /usr/local/lib/zig/std/Io/Dir.zig` before committing.

- [ ] **Step 5: Run the test, confirm it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: PASS for the new test. All existing config tests still green.

- [ ] **Step 6: Add a test for the missing-parent-dir case**

Append to `config_test.zig`:

```zig
test "writeDefaultConfig creates parent directories that do not exist" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathAlloc(std.testing.io, allocator);
    defer allocator.free(base);

    // Path includes a 2-level deep parent that does NOT exist yet.
    const nested_path = try std.fs.path.join(allocator, &.{ base, "deep", "nested", "config.json" });
    defer allocator.free(nested_path);

    try LlmConfig.writeDefaultConfig(allocator, std.testing.io, nested_path);

    // Verify the file was written and is readable.
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, nested_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"api_key\": \"\"") != null);
}
```

- [ ] **Step 7: Run the test, confirm it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: PASS. Test count baseline + 2 new tests.

- [ ] **Step 8: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "feat(config): add writeDefaultConfig helper for first-run bootstrap"
```

---

## Chunk 2: Auto-init on `error.FileNotFound` in `LlmConfig.init()`

### Task 2: Modify the `init()` catch path

**Files:**
- Modify: `src/modules/config/Config.zig` (the `init()` function, around line 233-236)

- [ ] **Step 1: Read the current `init()` catch path**

`Config.zig:233-236`:
```zig
const file = Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| {
    std.log.err("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
    return error.ConfigFileNotFound;
};
```

We change this to:
- On `error.FileNotFound` AND `path == null`: auto-create the default config, log info, retry the open.
- On all other errors: surface `error.ConfigFileNotFound` (preserves prior behavior for `error.AccessDenied`, etc.).
- On `error.FileNotFound` AND `path != null`: surface `error.ConfigFileNotFound` (explicit paths are NOT auto-created — user knew what they were asking for).

- [ ] **Step 2: Write the failing test for auto-init**

Append to `config_test.zig`:

```zig
test "init auto-creates config.json when default path does not exist (path=null)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build an absolute path that does not yet exist.
    const base = try tmp.dir.realPathAlloc(std.testing.io, allocator);
    defer allocator.free(base);
    const fresh_path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    defer allocator.free(fresh_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base);
    try env_map.put("XDG_CONFIG_HOME", base);

    // Call init() with path = null. The default config path resolves
    // via getDefaultConfigPath to <base>/.config/nalar/config.json,
    // which does not exist — auto-init must create it.
    var cfg = try LlmConfig.init(allocator, std.testing.io, null, &env_map);
    defer cfg.deinit();

    // Post-condition: the file now exists on disk and contains the default template.
    const expected_path = try std.fs.path.join(allocator, &.{ base, ".config", "nalar", "config.json" });
    defer allocator.free(expected_path);

    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, expected_path, .{});
    defer file.close(std.testing.io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"api_key\": \"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"url_style\": \"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"model_compaction_size_kb\": 100") != null);
}
```

- [ ] **Step 3: Run the test, confirm it fails**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: FAIL — `error: ConfigFileNotFound` returned from `LlmConfig.init`.

- [ ] **Step 4: Modify the catch path in `init()`**

Replace the catch block (line 233-236) with:

```zig
const file = Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
    error.FileNotFound => blk: {
        // First-run auto-init: only for the default path. An explicit
        // path that doesn't exist is treated as a user error (they
        // asked us to read a specific file and it's missing).
        if (path != null) {
            std.log.err("Config file not found at explicit path {s}", .{config_path});
            return error.ConfigFileNotFound;
        }
        std.log.info(
            "Config file not found at {s}; auto-creating with empty placeholders. Edit this file to set api_key/model/base_url.",
            .{config_path},
        );
        writeDefaultConfig(allocator, io, config_path) catch |write_err| {
            std.log.err("Failed to auto-create config file {s}: {s}", .{ config_path, @errorName(write_err) });
            return error.ConfigFileNotFound;
        };
        // Retry the open. If THIS fails (e.g. permission denied on
        // the new file), surface the underlying error verbatim.
        break :blk try Io.Dir.openFileAbsolute(io, config_path, .{});
    },
    else => {
        std.log.err("Failed to open config file: {s} - {s}", .{ config_path, @errorName(err) });
        return error.ConfigFileNotFound;
    },
};
defer file.close(io);
```

> **Why `path != null` check matters**: The signature is `init(allocator, io, path: ?[]const u8, environment)`. The `path` parameter is the original argument from the caller (possibly null). The local `config_path` is the resolved default path (never null). We check `path` (the original) to distinguish "explicit" from "default" calls — see the existing code at line 227-230: `if (path) |p| try allocator.dupe(u8, p) else try getDefaultConfigPath(...)`. The `path` parameter is in scope here.

- [ ] **Step 5: Run the test, confirm it passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: PASS for the new auto-init test. Existing tests still green.

- [ ] **Step 6: Add a test that explicit paths are NOT auto-created**

Append to `config_test.zig`:

```zig
test "init does NOT auto-create when explicit path is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathAlloc(std.testing.io, allocator);
    defer allocator.free(base);
    const missing_path = try std.fs.path.join(allocator, &.{ base, "nope.json" });
    defer allocator.free(missing_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", base);

    // Explicit path arg (non-null) — must surface ConfigFileNotFound,
    // NOT silently auto-create.
    const result = LlmConfig.init(allocator, std.testing.io, missing_path, &env_map);
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

test "init does NOT auto-create when file exists with parse error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(config_path);

    // Write invalid JSON to the existing file.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "not json{",
        .flags = .{ .truncate = true },
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/tmp");
    try env_map.put("XDG_CONFIG_HOME", "/tmp");

    // File exists → auto-init must NOT run; the parse error surfaces.
    const result = LlmConfig.init(allocator, std.testing.io, config_path, &env_map);
    try std.testing.expectError(error.InvalidJson, result);

    // The original file content must be unchanged (no auto-create ran).
    const content_after = try tmp.dir.readFileAlloc(std.testing.io, allocator, "config.json", 64 * 1024);
    defer allocator.free(content_after);
    try std.testing.expectEqualStrings("not json{", content_after);
}
```

- [ ] **Step 7: Run the new tests, confirm they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: PASS for both new tests. Total: baseline + 4 new tests (2 from Chunk 1, 2 from this chunk).

- [ ] **Step 8: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "feat(config): auto-create default config.json on first run when missing"
```

---

## Chunk 3: Tolerate empty config in `main.zig`

### Task 3: Change `try llm_config.validate()` to log-warn-and-continue

**Files:**
- Modify: `src/main.zig:32`

- [ ] **Step 1: Read `main.zig` around line 32**

```zig
try llm_config.validate();
```

This is the only `try llm_config.validate()` call in production. `validate()` is also called at `nalar_config_put.zig:234` (intentionally strict — that handler rejects broken configs that the user just PUT-ed). We change ONLY this one call site.

- [ ] **Step 2: Make the change**

Replace line 32 in `src/main.zig`:

```zig
// Was: try llm_config.validate();
//
// Now: log warnings but don't block startup. An empty/placeholder
// config (e.g. auto-created on first run when no config.json
// exists) is allowed to start the server. The server is reachable
// for non-LLM endpoints (workspaces, kanban, memories, etc.); LLM
// calls will fail naturally with a clear "empty api_key" error
// until the user fills in config.json.
//
// The PUT handler (`nalar_config_put.zig:234`) keeps the strict
// behavior — when the user actively edits their config via the UI,
// an empty api_key is still rejected with a 200 + error body so
// they can correct it.
if (llm_config.validate()) |_| {
    // OK — config has all required fields.
} else |err| {
    std.log.warn(
        "Config validation: {s}. LLM calls will fail until api_key/model/base_url are populated in ~/.config/nalar/config.json.",
        .{@errorName(err)},
    );
}
```

- [ ] **Step 3: Run the full build, confirm it compiles**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build install:linux:system 2>&1 | tail -n 15`
Expected: 4/6 steps succeed. The `cp /usr/local/bin/nalar` step fails harmlessly with "Permission denied" (project convention). No compile errors.

- [ ] **Step 4: Verify the `validate()` strict path is unchanged**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: PASS — test count baseline + 4 new tests from Chunks 1-2.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "fix(main): tolerate empty config (auto-created on first run) — log instead of abort"
```

---

## Chunk 4: End-to-end verification

### Task 4: Run the binary against a fresh HOME to confirm the CI bug is fixed

**Files:** none (verification only — no code changes)

- [ ] **Step 1: Build the binary**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 240 zig build install:linux:system 2>&1 | tail -n 5`
Expected: 4/6 steps succeed. `zig-out/bin/nalar` exists with a recent mtime.

- [ ] **Step 2: Run the binary with a fresh HOME**

```bash
export TMPHOME=/tmp/nalar-smoketest-$$
mkdir -p "$TMPHOME"
env -i HOME="$TMPHOME" PATH=$PATH ./zig-out/bin/nalar --port 8088 &
SERVER_PID=$!
sleep 3
```

Expected: the server logs an `info: Config file not found at .../.config/nalar/config.json; auto-creating with empty placeholders...` line on stderr, then proceeds with normal startup. The `~/.config/nalar/config.json` file now exists under `$TMPHOME`.

- [ ] **Step 3: Verify the created config file matches the embedded default**

```bash
diff <(cat "$TMPHOME/.config/nalar/config.json") <(cat <<'EOF'
{
  "api_key": "",
  "model": "",
  "base_url": "",
  "url_style": "openai",
  "model_compaction_size_kb": 100,
  "notify_on_complete": false
}
EOF
)
```

Expected: diff produces no output (the two files are byte-identical).

- [ ] **Step 4: Verify the server is reachable on /health**

```bash
curl -sf http://127.0.0.1:8088/health
```

Expected: a 200 response (the server is listening, despite the empty config).

- [ ] **Step 5: Verify the server warns on LLM-bound requests (optional)**

```bash
curl -i -X POST http://127.0.0.1:8088/api/session -d '{"prompt":"hi"}' -H 'Content-Type: application/json' 2>&1 | head -n 5
```

Expected: an error response from the LLM call (e.g. 4xx with an "api_key missing" message). The exact response depends on the LLM call path, but it MUST NOT be a 500/connection-refused — the server must be alive enough to respond.

- [ ] **Step 6: Clean up**

```bash
kill $SERVER_PID 2>/dev/null
rm -rf "$TMPHOME"
```

- [ ] **Step 7: Re-run the failing CI smoke test to confirm the bug is fixed**

Identify the CI step from the original bug screenshot (the line `Smoke test: version check (Windows)` or similar). The CI pipeline's config-loading smoke test (which previously errored with `ConfigFileNotFound`) should now pass.

If CI is wired up via `feature/multi-platform-ci-cd` branch workflow, push the branch and confirm the smoke test step turns green. The user's `fix windows ci` task (running concurrently) is unrelated to this task.

### Task 5: Document the new behavior in code

**Files:**
- Modify: `src/modules/config/Config.zig` (doc comment on `init()` at line 226)

- [ ] **Step 1: Add a doc comment explaining auto-init**

At the top of `pub fn init(...)` (line 226), replace the existing doc comment with:

```zig
/// Initialize an `LlmConfig` from disk. When `path` is null (the
/// default), uses the platform-specific config path returned by
/// `getDefaultConfigPath` (e.g. `~/.config/nalar/config.json` on
/// Linux, `~/Library/Application Support/nalar/config.json` on
/// macOS, `%APPDATA%/nalar/config.json` on Windows).
///
/// **Auto-init on first run**: When `path` is null AND the file at
/// the resolved default path does not exist, this function creates
/// a default config with empty placeholder values (via
/// `writeDefaultConfig`), logs an `info:` message, and proceeds.
/// The server can then start; downstream LLM calls will fail until
/// the user edits the placeholder values.
///
/// **Explicit paths are NOT auto-created**: When `path` is non-null
/// (e.g. `--config /custom/path.json`), a missing file surfaces
/// `error.ConfigFileNotFound` unchanged — explicit paths are
/// honored literally.
///
/// **Other errors**: permission denied, invalid JSON, parse errors
/// surface to the caller unchanged.
pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8, environment: *std.process.Environ.Map) LoadError!LlmConfig {
```

(Replace the existing line-226 declaration; the body stays unchanged except for the catch-path modification in Chunk 2.)

- [ ] **Step 2: Add a brief comment on `writeDefaultConfig` mentioning the caller**

The helper's doc comment (added in Chunk 1) already says "see `LlmConfig.init` for the auto-init flow that gates the call on `error.FileNotFound`". That's sufficient — no change needed.

- [ ] **Step 3: Commit**

```bash
git add src/modules/config/Config.zig
git commit -m "docs(config): document first-run auto-init behavior on init()"
```

---

## Verification Checklist

Before declaring the plan complete, confirm:

- [ ] `timeout 240 zig build install:linux:system` succeeds (4/6 steps; the cp step fails harmlessly).
- [ ] `timeout 180 zig build test --summary all` shows the same pass count as baseline **+ 4 new tests** (2 from Chunk 1, 2 from Chunk 2). No regressions.
- [ ] The original CI smoke test from the bug screenshot (which errored with `ConfigFileNotFound`) now passes — `nalar` can start with a fresh `HOME` and no `config.json`.
- [ ] An existing user-provided `config.json` is NOT modified on subsequent runs (verified by the "init does NOT auto-create when file exists with parse error" test).
- [ ] Explicit `--config /path/to/nonexistent.json` still returns `error.ConfigFileNotFound` (verified by the "init does NOT auto-create when explicit path is missing" test).
- [ ] `LlmConfig.validate()` at `nalar_config_put.zig:234` is unchanged (PUT handler still rejects broken configs strictly).
- [ ] The auto-created config.json file is byte-identical to `defaultConfigJson` (verified by the diff in Task 4 Step 3).

---

## Out of Scope (Future Work)

These are intentionally NOT covered by this plan; file as follow-up tasks if/when needed:

1. **Atomic writes via `.tmp` + rename**: Currently `writeDefaultConfig` uses `truncate = true`, which is safe for first-run but not for concurrent edits. A future plan could switch to a `.tmp` + `rename` pattern for safer updates from the PUT handler.
2. **`nalar init` CLI subcommand**: A `nalar init` command that explicitly creates the default config (and optionally prompts for `api_key` / `model` / `base_url`) would be friendlier than the auto-init-on-startup approach. Trivial 50-line addition; defer until user feedback warrants it.
3. **Migrating away from `defaultConfigJson` const**: Once a `nalar init` exists, the default could move from a string template to a typed struct that gets serialized via `std.json.Stringify` (less risk of a typo in the JSON). Defer until the template grows beyond ~20 lines.
4. **Lock file or sentinel to prevent multi-process races**: Two `nalar` instances starting concurrently on first run both detect "missing" and both write — safe today (idempotent content), but a `.lock` file would be more robust. Defer until a real bug report.