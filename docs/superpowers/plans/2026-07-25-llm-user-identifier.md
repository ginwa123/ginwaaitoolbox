# LLM end-user identifier — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a stable per-install UUID that nalar sends as the end-user identifier on every Anthropic + OpenAI chat request (`user` for OpenAI, `metadata.user_id` for Anthropic).

**Architecture:** Generate a UUID v4 once via libc `getrandom`/`getentropy`, persist in `~/.config/nalar/config.json` as `user_identifier`, plumb it through `LlmConfig` → `Agent.userIdentifier` → both request-body builders (`buildJsonOpenAIRequest`, `buildJsonAnthropicRequest`). Auto-migrate existing configs by writing back the new field when missing.

**Tech Stack:** Zig 0.16.0, libc `getrandom`/`getentropy`, std.json (no new deps).

**Design doc:** `docs/plans/2026-07-25-llm-user-identifier-design.md` (commit `679e6c7c`).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/helpers/install_id.zig` | CREATE | UUID v4 generator (libc `getrandom` / `getentropy` / Windows fallback). Fixed-size `[36]u8` buffer + `generateInstallId(buf)` function. |
| `src/helpers/install_id_test.zig` | CREATE | Tests for `generateInstallId`: format, version nibble, variant nibble, uniqueness. |
| `src/modules/agent/Agent.zig` | MODIFY | Add `userIdentifier: []const u8 = ""` field to `Agent`. Add `user: ?[]const u8` to `JsonRequest` and `metadata.user_id` to `AnthropicRequest` (via new `AnthropicMetadata` struct). Conditional emission in both builders. |
| `src/modules/agent/agent_request_user_id_test.zig` | CREATE | Static-contract tests asserting the four cases (Anthropic with/without, OpenAI with/without). |
| `src/modules/config/Config.zig` | MODIFY | Add `user_identifier: []const u8 = ""` field. Parse `user_identifier` JSON key. On parse with missing key: generate UUID, call `writeBackUserIdentifier`, then continue. Embed UUID in `defaultConfigJson` template. |
| `src/modules/config/config_user_identifier_test.zig` | CREATE | Tests: missing-field auto-migration, idempotent re-parse, default-config embedding. |
| `src/helpers/mod.zig` | MODIFY | Re-export `install_id` module. |
| `src/ai_workflow/tui/workflow.zig` | MODIFY | Set `dynamic_agent.userIdentifier = config.user_identifier` at both `Agent.init` sites (line 756 session-name, line 982 dynamic_agent). |
| `src/ai_workflow/tui/agentic_loop/compaction.zig` | MODIFY | Set `compaction_agent.userIdentifier = user_identifier` (need to thread the field through `callCompactAgent` parameter list). |
| `src/modules/agent/test_runner.zig` | MODIFY | Add `_ = @import("install_id_test.zig")` if the helper is part of agent's deps; add `_ = @import("agent_request_user_id_test.zig")`. |

---

## Chunk 1: install_id helper + tests

**Files:**
- Create: `src/helpers/install_id.zig`
- Create: `src/helpers/install_id_test.zig`
- Modify: `src/helpers/mod.zig`

### Task 1.1: Write install_id_test.zig (failing test first)

- [ ] **Step 1: Write the failing test file**

Create `src/helpers/install_id_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const install_id = @import("install_id.zig");

test "generateInstallId produces a 36-char UUID v4 string" {
    var buf: [36]u8 = undefined;
    install_id.generateInstallId(&buf);
    const out = buf[0..];

    // Length must be exactly 36 characters
    try testing.expectEqual(@as(usize, 36), out.len);

    // Hyphen positions: 8, 13, 18, 23
    try testing.expectEqual(@as(u8, '-'), out[8]);
    try testing.expectEqual(@as(u8, '-'), out[13]);
    try testing.expectEqual(@as(u8, '-'), out[18]);
    try testing.expectEqual(@as(u8, '-'), out[23]);

    // All other positions must be lowercase hex
    for (out, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }

    // Version nibble (position 14, the FIRST hex char of group 3) must be '4'
    try testing.expectEqual(@as(u8, '4'), out[14]);

    // Variant nibble (position 19, the FIRST hex char of group 4) must be 8/9/a/b
    try testing.expect(std.mem.indexOfScalar(u8, "89ab", out[19]) != null);
}

test "generateInstallId produces unique values across calls" {
    var buf1: [36]u8 = undefined;
    var buf2: [36]u8 = undefined;
    var buf3: [36]u8 = undefined;
    install_id.generateInstallId(&buf1);
    install_id.generateInstallId(&buf2);
    install_id.generateInstallId(&buf3);

    // Each pair must differ (vanishingly unlikely to collide across 122-bit random space)
    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
    try testing.expect(!std.mem.eql(u8, &buf2, &buf3));
    try testing.expect(!std.mem.eql(u8, &buf1, &buf3));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "install_id_test|error:" | head -n 20
```

Expected: `error: unable to find module 'install_id'` (file doesn't exist yet) — confirmed failing.

- [ ] **Step 3: Register the test in the helpers test runner**

Check `src/helpers/mod.zig` first; if there's a `test {...}` block at the bottom, add `_ = @import("install_id_test.zig");`. If not (helpers is re-exported as a module only), the test will be picked up by the global test runner automatically — verify with `zig build test`.

(See `src/helpers/mod.zig` line 5 — current shape: `pub const random = @import("random.zig");`. Add `pub const install_id = @import("install_id.zig");`.)

- [ ] **Step 4: Write the minimal `install_id.zig`**

Create `src/helpers/install_id.zig`:

```zig
//! UUID v4 generator for nalar's per-install LLM end-user identifier.
//!
//! Mirrors the libc-CSPRNG pattern from `src/modules/logger/RequestId.zig::SessionId.init`:
//!   - Linux: libc `getrandom` (loops on partial reads)
//!   - macOS: locally-declared `getentropy` (always fills in one call, max 256 bytes)
//!   - Windows / other: timestamp + output-buffer-address entropy (NOT crypto-grade,
//!     but matches the RequestId fallback used by the rest of nalar).
//!
//! Format: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" (36 chars), per RFC 4122 §4.4.

const std = @import("std");
const builtin = @import("builtin");

// macOS doesn't expose `getentropy` via `std.c`. Declare it locally;
// Zig's linker prunes unused extern declarations, so this is harmless
// on Linux/Windows (where the symbol is never referenced).
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

/// Generate a UUID v4 string into `buf` (must be a `[36]u8`).
/// The output is written verbatim; the caller does NOT need to NUL-terminate
/// because the length is fixed and known.
pub fn generateInstallId(buf: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);

    // Set version (4) and variant (10xx) bits per RFC 4122 §4.4.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    const hex = "0123456789abcdef";
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[b >> 4];
        buf[j + 1] = hex[b & 0x0F];
        j += 2;
    }
}

fn fillRandom(bytes: *[16]u8) void {
    if (builtin.os.tag == .linux) {
        var filled: usize = 0;
        while (filled < bytes.len) {
            const rc = std.c.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
            if (rc < 0) {
                const err = std.c.errno(rc);
                if (err == .INTR) continue;
                break;
            }
            filled += @intCast(rc);
        }
        if (filled == bytes.len) return;
        // Partial fill — fall through to the weak-entropy fallback
    } else if (builtin.os.tag == .macos) {
        if (getentropy(bytes.ptr, bytes.len) == 0) return;
        // getentropy failed — fall through to the weak-entropy fallback
    }
    // Fallback for Windows + getrandom/getentropy failures:
    // timestamp + output-buffer-address seed.
    const ts = std.Io.Timestamp.now(std.testing.io, .real);
    const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
        @as(u64, @intFromPtr(bytes));
    const truncated: u64 = @truncate(seed);
    @as(*u64, @ptrCast(@alignCast(bytes[0..8]))).* = truncated;
    @as(*u64, @ptrCast(@alignCast(bytes[8..16]))).* = @truncate(seed >> 1);
}
```

- [ ] **Step 5: Re-export `install_id` from `src/helpers/mod.zig`**

Add to `src/helpers/mod.zig` (after the existing `pub const random = @import("random.zig");`):

```zig
pub const install_id = @import("install_id.zig");
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "install_id_test|Build Summary" | head -n 10
```

Expected: 2/2 tests in `install_id_test.zig` pass; total build summary increments by 2.

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
git add src/helpers/install_id.zig src/helpers/install_id_test.zig src/helpers/mod.zig
git commit -m "feat(helpers): add UUID v4 generator for install-level identifiers"
```

---

## Chunk 2: Agent.zig — userIdentifier field + request builders

**Files:**
- Modify: `src/modules/agent/Agent.zig`
- Create: `src/modules/agent/agent_request_user_id_test.zig`
- Modify: `src/modules/agent/test_runner.zig`

### Task 2.1: Write agent_request_user_id_test.zig (failing test first)

- [ ] **Step 1: Write the failing test file**

Create `src/modules/agent/agent_request_user_id_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const Agent = @import("Agent.zig");

const TEST_USER_ID = "550e8400-e29b-41d4-a716-446655440000";

fn makeAgent(user_id: []const u8) Agent {
    var a = Agent.init(testing.allocator, testing.io) catch return unreachable;
    a.model = "test-model";
    a.userIdentifier = user_id;
    return a;
}

test "buildJsonOpenAIRequest includes 'user' field when userIdentifier is set" {
    var a = makeAgent(TEST_USER_ID);
    defer a.deinit();

    const params = Agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    // Body must contain "user":"<uuid>"
    try testing.expect(std.mem.indexOf(u8, body, "\"user\":\"" ++ TEST_USER_ID ++ "\"") != null);
}

test "buildJsonOpenAIRequest omits 'user' field when userIdentifier is empty" {
    var a = makeAgent("");
    defer a.deinit();

    const params = Agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonOpenAIRequest(params, true);
    defer testing.allocator.free(body);

    // Body must NOT contain "user" as a JSON key.
    // Note: substring search is sufficient because "user" is unlikely to
    // appear elsewhere in the request body (model/tools/messages).
    try testing.expect(std.mem.indexOf(u8, body, "\"user\":") == null);
}

test "buildJsonAnthropicRequest includes metadata.user_id when userIdentifier is set" {
    var a = makeAgent(TEST_USER_ID);
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = Agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    // Body must contain "metadata":{"user_id":"<uuid>"}
    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\":{\"user_id\":\"" ++ TEST_USER_ID ++ "\"}") != null);
}

test "buildJsonAnthropicRequest omits metadata entirely when userIdentifier is empty" {
    var a = makeAgent("");
    a.UrlStyle = "anthropic";
    defer a.deinit();

    const params = Agent.AgentCall{ .tools = &.{}, .messages = &.{} };
    const body = try a.buildJsonAnthropicRequest(params, true);
    defer testing.allocator.free(body);

    // Body must NOT contain "metadata" key.
    try testing.expect(std.mem.indexOf(u8, body, "\"metadata\"") == null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "agent_request_user_id_test|error:" | head -n 20
```

Expected: compile errors about `userIdentifier` field, `buildJsonOpenAIRequest`/`buildJsonAnthropicRequest` signature mismatches.

- [ ] **Step 3: Register the test in `src/modules/agent/test_runner.zig`**

Add `_ = @import("agent_request_user_id_test.zig");` to the `test {...}` block (next to the existing `_ = @import("call_streaming_test.zig");`).

- [ ] **Step 4: Add the `userIdentifier` field to the `Agent` struct**

In `src/modules/agent/Agent.zig` (line ~745, the `Agent` struct declaration), add a new field after `UrlStyle: []const u8 = "openai",`:

```zig
/// Per-install LLM-API end-user identifier. Empty = don't include the
/// identifier in the request body. Set from `LlmConfig.user_identifier`
/// at Agent.init() call sites. Anthropic: emitted as
/// `metadata.user_id`. OpenAI: emitted as top-level `user`.
userIdentifier: []const u8 = "",
```

- [ ] **Step 5: Add the `user` field to `JsonRequest` (OpenAI)**

In `src/modules/agent/Agent.zig` (line ~219, the `JsonRequest` struct), add:

```zig
/// Optional end-user identifier. Omitted from the JSON body when null
/// or empty. Maps to OpenAI's `user` request-body parameter. See
/// https://platform.openai.com/docs/api-reference/chat/create.
user: ?[]const u8 = null,
```

Then in the `jsonStringify` method (around line ~247), add the conditional emission (after `if (self.stream) {...}` and before `try stringify.endObject();`):

```zig
if (self.user) |u| {
    if (u.len > 0) {
        try stringify.objectField("user");
        try stringify.write(u);
    }
}
```

- [ ] **Step 6: Add the `AnthropicMetadata` struct + `metadata` field to `AnthropicRequest`**

In `src/modules/agent/Agent.zig`, BEFORE the `AnthropicRequest` struct (around line ~388), add:

```zig
/// Anthropic `metadata` block. Currently only `user_id` is supported —
/// Anthropic's Messages API accepts arbitrary key/value metadata but
/// nalar only uses `user_id` for the LLM-API end-user identifier.
const AnthropicMetadata = struct {
    user_id: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("user_id");
        try stringify.write(self.user_id);
        try stringify.endObject();
    }
};
```

Then add the `metadata` field to `AnthropicRequest`:

```zig
const AnthropicRequest = struct {
    // ... existing fields ...
    /// Optional metadata block. Currently emits `{"user_id": "..."}`
    /// from `Agent.userIdentifier`. See
    /// https://docs.claude.com/en/api/messages.
    metadata: ?AnthropicMetadata = null,
    // ...
};
```

Then in the `jsonStringify` method, add the conditional emission:

```zig
if (self.metadata) |m| {
    try stringify.objectField("metadata");
    try stringify.write(m);
}
```

- [ ] **Step 7: Plumb `userIdentifier` into both request builders**

In `buildJsonOpenAIRequest` (line ~1107), at the `const json_request = JsonRequest{...}` literal (line ~1201), add:

```zig
const json_request = JsonRequest{
    // ... existing fields ...
    .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
};
```

In `buildJsonAnthropicRequest` (line ~1004), at the `const json_request = AnthropicRequest{...}` literal (line ~1092), add:

```zig
const json_request = AnthropicRequest{
    // ... existing fields ...
    .metadata = if (self.userIdentifier.len > 0)
        .{ .user_id = self.userIdentifier }
    else
        null,
};
```

- [ ] **Step 8: Run the tests to verify they pass**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "agent_request_user_id_test|Build Summary" | head -n 10
```

Expected: 4/4 tests pass; total build summary increments by 4.

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
git add src/modules/agent/Agent.zig src/modules/agent/agent_request_user_id_test.zig src/modules/agent/test_runner.zig
git commit -m "feat(agent): emit user/metadata.user_id on every Anthropic + OpenAI call"
```

---

## Chunk 3: LlmConfig — persist user_identifier + auto-migrate existing configs

**Files:**
- Modify: `src/modules/config/Config.zig`
- Create: `src/modules/config/config_user_identifier_test.zig`

### Task 3.1: Write config_user_identifier_test.zig (failing test first)

- [ ] **Step 1: Write the failing test file**

Create `src/modules/config/config_user_identifier_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const LlmConfig = @import("Config.zig").LlmConfig;

fn loadFromString(allocator: std.mem.Allocator, io: std.Io, json_text: []const u8, config_path: []const u8) !LlmConfig {
    // Write the JSON to `config_path` so the loader can find it.
    const file = try std.Io.Dir.createFileAbsolute(io, config_path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(json_text);
    try writer.interface.flush();

    const env_map = try allocator.create(std.process.Environ.Map);
    env_map.* = .{};
    defer allocator.destroy(env_map);
    return LlmConfig.init(allocator, io, config_path, env_map);
}

test "LlmConfig.init populates user_identifier from existing config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(testing.io, &path_buf);
    const parent_path: []const u8 = path_buf[0..parent_len];
    const config_path = try std.fs.path.join(testing.allocator, &.{
        parent_path, &tmp.sub_path, "config.json",
    });
    defer testing.allocator.free(config_path);

    const json =
        \\{
        \\  "api_key": "test-key",
        \\  "model": "gpt-4o",
        \\  "base_url": "https://api.openai.com/v1",
        \\  "user_identifier": "preset-uuid-aaaa-bbbb"
        \\}
    ;
    var cfg = try loadFromString(testing.allocator, testing.io, json, config_path);
    defer cfg.deinit();

    try testing.expectEqualStrings("preset-uuid-aaaa-bbbb", cfg.user_identifier);
}

test "LlmConfig.init auto-generates user_identifier when missing and persists it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(testing.io, &path_buf);
    const parent_path: []const u8 = path_buf[0..parent_len];
    const config_path = try std.fs.path.join(testing.allocator, &.{
        parent_path, &tmp.sub_path, "config.json",
    });
    defer testing.allocator.free(config_path);

    // Existing config without user_identifier (legacy upgrade scenario).
    const legacy_json =
        \\{
        \\  "api_key": "test-key",
        \\  "model": "gpt-4o",
        \\  "base_url": "https://api.openai.com/v1"
        \\}
    ;
    var cfg = try loadFromString(testing.allocator, testing.io, legacy_json, config_path);
    // user_identifier should be auto-generated and non-empty.
    try testing.expect(cfg.user_identifier.len == 36);  // UUID v4 format length
    const first_uuid = try testing.allocator.dupe(u8, cfg.user_identifier);
    defer testing.allocator.free(first_uuid);
    cfg.deinit();

    // The file on disk should have been updated to include the new field.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, config_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "\"user_identifier\":") != null);

    // Re-parsing should yield the SAME identifier (idempotent).
    var env_map = try testing.allocator.create(std.process.Environ.Map);
    env_map.* = .{};
    defer testing.allocator.destroy(env_map);
    var cfg2 = try LlmConfig.init(testing.allocator, testing.io, config_path, env_map);
    defer cfg2.deinit();
    try testing.expectEqualStrings(first_uuid, cfg2.user_identifier);
}

test "LlmConfig.init defaultConfigJson embeds a fresh user_identifier" {
    // Verify the default-config template includes the user_identifier field.
    try testing.expect(std.mem.indexOf(u8, LlmConfig.defaultConfigJson, "\"user_identifier\":") != null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "config_user_identifier_test|error:" | head -n 20
```

Expected: compile errors about `user_identifier` field on `LlmConfig`.

- [ ] **Step 3: Add `user_identifier` field to `LlmConfig`**

In `src/modules/config/Config.zig` (line ~59, after `random_names: [][]u8 = &.{},`), add:

```zig
/// Stable per-install UUID used as the LLM-API end-user identifier
/// (`user` for OpenAI, `metadata.user_id` for Anthropic).
///
/// Auto-generated on first run via `helpers.install_id.generateInstallId`
/// and persisted in `~/.config/nalar/config.json` as `user_identifier`.
/// On upgrade (existing config missing this field), a fresh UUID is
/// generated and the config file is rewritten atomically to include it.
/// Empty only if generation failed (logged warning); in that case
/// `Agent.userIdentifier` is empty and the identifier is omitted from
/// the request body.
user_identifier: []const u8 = "",
```

- [ ] **Step 4: Embed UUID in `defaultConfigJson`**

In `src/modules/config/Config.zig` (line ~1262, the `defaultConfigJson` constant), change the JSON template to generate and embed a UUID at comptime/runtime:

```zig
pub fn defaultConfigJson(allocator: std.mem.Allocator) ![]const u8 {
    var uuid_buf: [36]u8 = undefined;
    helpers.install_id.generateInstallId(&uuid_buf);
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "api_key": "",
        \\  "model": "",
        \\  "base_url": "",
        \\  "url_style": "openai",
        \\  "model_compaction_size_kb": 100,
        \\  "notify_on_complete": false,
        \\  "retry_delay_ms": 0,
        \\  "max_capacity_token_model": null,
        \\  "compaction_threshold_percent": null,
        \\  "user_identifier": "{s}"
        \\}}
    , .{uuid_buf[0..]});
}
```

(The change replaces the `pub const defaultConfigJson: []const u8 =` form with a function. **Verify this doesn't break the existing test** `config_test.zig:1076` "writeDefaultConfig creates a valid JSON config file at the given path" — that test calls `LlmConfig.writeDefaultConfig(allocator, std.testing.io, full_path)` and the function still takes the same arguments; the only change is what string gets written. The internal call site is `writer.interface.writeAll(defaultConfigJson)` → must become `writer.interface.writeAll(try defaultConfigJson(allocator))` with the `try` propagated. **Need to also free the temp string after `writeAll` returns** — use `defer allocator.free(json)` immediately after the `try`.)

> **Note:** this is a small API change — `defaultConfigJson` goes from `[]const u8` to `fn ([]) ![]const u8`. There is **one** external caller (`writeDefaultConfig` itself, line ~1318). Update that call site to `try` and `defer allocator.free(...)`.

> **Alternative if changing the const to a function is too disruptive:** Keep `defaultConfigJson` as a constant template (no UUID), and have the `user_identifier` auto-migration path inject the UUID on first parse. This avoids the function-vs-const API change. **Recommendation: do the alternative** — simpler, fewer touch points. Skip the comptime/runtime UUID generation in the default template; let the auto-migration step handle the field. Update step 3 above: leave `defaultConfigJson` as-is, jump to Step 5 (auto-migrate).

- [ ] **Step 5: Implement `writeBackUserIdentifier` and wire it into the parse path**

In `src/modules/config/Config.zig`, add a new helper function (near `writeDefaultConfig`):

```zig
/// Atomically rewrite `~/.config/nalar/config.json` with the
/// `user_identifier` field added (preserves all other fields).
/// Uses the same `<path>.tmp` + rename(2) pattern as
/// `state_file.zig::writeStateFile` to ensure readers never see a
/// half-written file.
///
/// `user_identifier` is assumed to be a 36-char UUID v4 string.
/// Caller owns both `path` and `user_identifier`; this function
/// makes its own copies into the temporary buffer.
fn writeBackUserIdentifier(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    user_identifier: []const u8,
) !void {
    // Read the current file content.
    const current = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(current);

    // Naively inject `"user_identifier": "<uuid>",` before the closing `}`.
    // For nalar's default config (small JSON object written by us), this is
    // safe. If the JSON is malformed or doesn't end with `}`, we fall back
    // to `writeDefaultConfig` (which re-creates the file with a fresh UUID).
    const close_brace_idx = std.mem.lastIndexOfScalar(u8, current, '}') orelse {
        std.log.warn("user_identifier auto-migration: no closing brace in {s}, falling back to default config", .{path});
        return writeDefaultConfig(allocator, io, path);
    };

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);
    try new_content.appendSlice(allocator, current[0..close_brace_idx]);
    try new_content.writer(allocator).print(",\n  \"user_identifier\": \"{s}\"", .{user_identifier});
    try new_content.appendSlice(allocator, current[close_brace_idx..]);

    // Atomic write: write to <path>.tmp, then rename.
    var tmp_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len + 4 >= tmp_path_buf.len) return error.PathTooLong;
    @memcpy(tmp_path_buf[0..path.len], path);
    @memcpy(tmp_path_buf[path.len..][0..4], ".tmp");
    tmp_path_buf[path.len + 4] = 0;
    const tmp_path: []const u8 = tmp_path_buf[0..path.len + 4];

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = new_content.items });
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}
```

Then, in `LlmConfig.init` (line ~320), after the file is parsed but BEFORE the existing return / field assignments, add:

```zig
// Auto-migrate: if the loaded JSON has no `user_identifier`, generate one
// and persist it to disk. This handles users who upgrade from a version
// of nalar that didn't ship this field.
if (config_json.user_identifier.len == 0) {
    var uuid_buf: [36]u8 = undefined;
    helpers.install_id.generateInstallId(&uuid_buf);
    writeBackUserIdentifier(allocator, io, config_path, &uuid_buf) catch |err| {
        std.log.warn("Failed to persist user_identifier to {s}: {s}", .{ config_path, @errorName(err) });
        // Continue with the in-memory UUID even if the persist failed —
        // the field will still be in `LlmConfig.user_identifier` for this run.
    };
    config_json.user_identifier = try allocator.dupe(u8, &uuid_buf);
}
```

> **IMPORTANT:** this requires `config_json` to be a mutable struct (not `const`) so the `.user_identifier` field can be reassigned. Verify the existing `init` signature — `const config_json` is currently used, so the field-by-field copy below it needs to change to a mutable copy. If the parse step produces a `const` JSON value, the migration code needs to be rewritten as a "re-parse after mutation" flow. **In that case**, the simpler implementation is:
>
> ```zig
> // Auto-migrate: if missing, generate UUID, rewrite the file, and
> // duplicate it into a fresh slice.
> if (config_json.user_identifier.len == 0) {
>     var uuid_buf: [36]u8 = undefined;
>     helpers.install_id.generateInstallId(&uuid_buf);
>     const uuid_str = try allocator.dupe(u8, &uuid_buf);
>     writeBackUserIdentifier(allocator, io, config_path, uuid_str) catch |err| {
>         std.log.warn("Failed to persist user_identifier to {s}: {s}", .{ config_path, @errorName(err) });
>     };
>     // Use the freshly-allocated UUID for this run. The .user_identifier
>     // slice below picks this up via the existing `try allocator.dupe(...)`.
>     // We assign into `config_json` only if it's already mutable; otherwise
>     // we override the value AFTER the existing copy block.
> }
> ```
>
> After the existing block that builds the `LlmConfig` from `config_json`, add:
>
> ```zig
> .user_identifier = try allocator.dupe(u8, config_json.user_identifier),
> ```
>
> If the override pattern is needed, do this AFTER the `config_json` block:
>
> ```zig
> var cfg = LlmConfig{ ... .user_identifier = try allocator.dupe(u8, config_json.user_identifier) ... };
> if (config_json.user_identifier.len == 0) {
>     // Replace with the freshly-generated UUID
>     allocator.free(cfg.user_identifier);
>     var uuid_buf: [36]u8 = undefined;
>     helpers.install_id.generateInstallId(&uuid_buf);
>     cfg.user_identifier = try allocator.dupe(u8, &uuid_buf);
>     // Best-effort persist (don't fail the whole init if this fails)
>     writeBackUserIdentifier(allocator, io, config_path, cfg.user_identifier) catch |err| {
>         std.log.warn("Failed to persist user_identifier to {s}: {s}", .{ config_path, @errorName(err) });
>     };
> }
> ```

- [ ] **Step 6: Add the `user_identifier` field assignment + free in the `LlmConfig.init` + `deinit` flow**

In `LlmConfig.init` (line ~320), find the existing block that copies `config_json.url_style` etc. into the `LlmConfig` fields (around line 382) and add:

```zig
.user_identifier = try allocator.dupe(u8, config_json.user_identifier),
```

In `LlmConfig.deinit` (find the existing `allocator.free(config.url_style)` at line ~401), add:

```zig
allocator.free(config.user_identifier);
```

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "config_user_identifier_test|Build Summary" | head -n 10
```

Expected: 3/3 tests pass; total build summary increments by 3.

- [ ] **Step 8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
git add src/modules/config/Config.zig src/modules/config/config_user_identifier_test.zig
git commit -m "feat(config): persist user_identifier UUID and auto-migrate existing configs"
```

---

## Chunk 4: Wire user_identifier through to the 3 Agent call sites

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig`
- Modify: `src/ai_workflow/tui/agentic_loop/compaction.zig`

### Task 4.1: Wire userIdentifier in workflow.zig's session-name agent (line 756)

- [ ] **Step 1: Add userIdentifier assignment after the existing apiKey/model/baseUrl assignments**

In `src/ai_workflow/tui/workflow.zig` (line 756), the `name_agent` block currently looks like:

```zig
var name_agent = agent.Agent.init(allocator, io) catch return;
defer name_agent.deinit();
name_agent.apiKey = api_key;
name_agent.model = model;
name_agent.baseUrl = base_url;
```

Add a `userIdentifier` line. Need to confirm `config.user_identifier` is in scope at this call site. **Read 30 lines before line 756 to verify**, then add:

```zig
name_agent.userIdentifier = config.user_identifier;
```

If `config` is not in scope (e.g. this function takes only `api_key`/`model`/`base_url`), thread the `user_identifier` value as a new parameter:

```zig
fn generateSessionNameNew(
    // ... existing params ...
    user_identifier: []const u8,  // NEW
) void {
    // ...
    name_agent.userIdentifier = user_identifier;
}
```

Update the call site accordingly (find `generateSessionNameNew(` with the search tool).

- [ ] **Step 2: Wire userIdentifier in workflow.zig's dynamic_agent (line 982)**

Same pattern. In `callDynamicAgentNew` (line ~970-1008), after the existing `dynamic_agent.apiKey = api_key; dynamic_agent.model = model; dynamic_agent.baseUrl = base_url; dynamic_agent.UrlStyle = url_style;` (around lines 992-995), add:

```zig
dynamic_agent.userIdentifier = user_identifier;
```

Add `user_identifier: []const u8` to the function parameter list. Update the call site at line 595 (`callDynamicAgentNew(...)`) to pass `config.user_identifier`.

### Task 4.2: Wire userIdentifier in compaction.zig's compaction_agent (line 164)

- [ ] **Step 3: Add userIdentifier parameter to `callCompactAgent` and assign**

In `src/ai_workflow/tui/agentic_loop/compaction.zig`, find `callCompactAgent`'s signature (around line 100-150) and add `user_identifier: []const u8` to its parameter list (likely the `CompactAgentParams` struct or the direct argument list).

After the existing `compaction_agent.apiKey = api_key; compaction_agent.model = model; compaction_agent.baseUrl = base_url;` (around lines 170-172), add:

```zig
compaction_agent.userIdentifier = user_identifier;
```

Find the call site of `callCompactAgent` in `workflow.zig` (the one in `maybeCompactMessagesNew`, line 1046) and pass `config.user_identifier`.

- [ ] **Step 4: Run full test suite**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: Build Summary line shows the same total as before this chunk (existing tests still pass; no new tests in this chunk). If anything regresses, fix forward.

- [ ] **Step 5: Verify lazy-analysis path with `install:linux:system`**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
```

Expected: same compile output as before; cp-to-`/usr/local/bin/nalar` may fail with permission but is harmless (per project convention).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
git add src/ai_workflow/tui/workflow.zig src/ai_workflow/tui/agentic_loop/compaction.zig
git commit -m "feat(workflow): plumb LlmConfig.user_identifier through all 3 Agent call sites"
```

---

## Chunk 5: Final verification + handoff

**Files:** (no new files; this is verification only)

### Task 5.1: Full verification

- [ ] **Step 1: Run the full test suite**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: `Build Summary: N/N steps succeeded; X passed; Y skipped`. Verify X is at least baseline + 9 (2 from install_id_test + 4 from agent_request_user_id_test + 3 from config_user_identifier_test).

- [ ] **Step 2: Build the production binary**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -n 10
```

Expected: build succeeds; `zig-out/bin/nalar` exists.

- [ ] **Step 3: Smoke test against port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
./zig-out/bin/nalar --port 8080 &
sleep 5
curl -sS http://127.0.0.1:8080/api/health 2>&1 | head -n 5
curl -sS http://127.0.0.1:8080/api/nalar/config 2>&1 | python3 -c 'import sys, json; d = json.load(sys.stdin); print("user_identifier:", d.get("data", {}).get("user_identifier", "<MISSING>"))'
kill %1 2>/dev/null
```

Expected:
- `{"status":"ok",...}` from `/api/health`
- `user_identifier: <36-char UUID>` from `/api/nalar/config`

> **NOTE:** The `GET /api/nalar/config` endpoint may not exist with that exact shape; verify the actual endpoint and field by searching for `pub fn handleConfigGet` in `src/ai_workflow/tui/http_handlers/`. The goal is just to verify the field is accessible via HTTP. If the endpoint doesn't expose `user_identifier` directly, that's fine — verify by reading the config file directly with `cat ~/.config/nalar/config.json | grep user_identifier` instead.

- [ ] **Step 4: Verify the wire format with a real OpenAI/Anthropic call**

The cleanest way to verify the wire format is to write a one-shot Zig test that calls `buildJsonOpenAIRequest` and `buildJsonAnthropicRequest` and prints the JSON. Use the existing `agent_request_user_id_test.zig` from Chunk 2 — those tests already verify the format. Re-run them as a sanity check:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
timeout 120 zig build test --summary all 2>&1 | grep -E "agent_request_user_id_test" | head -n 10
```

Expected: 4 tests pass (already verified in Chunk 2 Step 8).

- [ ] **Step 5: Commit any final cleanups**

If anything needed adjustment in Steps 1-4:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/llm-user-identifier
git status  # verify what's changed
git add -u  # add any tracked-file modifications
git commit -m "chore: final cleanups after user_identifier wiring"
```

If nothing changed, skip the commit.

---

## Done

The feature is complete. Total: 9 new tests, 1 new helper, 1 new config field, 1 new Agent field, 3 call-site wirings.

**Next step:** open a PR or merge to main, per project workflow. Move the kanban task from `in_review_planning` → `in_review_pull_request` → `merged`.

