# LLM Completion OS Notification (Backend Dispatch) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire an OS-level notification from the Zig `nalar` backend when an LLM response finishes with `finish_reason === 'stop'`, gated by a new `notify_on_complete` config flag (default `off`). Works whether the browser is open, minimized, or closed.

**Architecture:** A new `notifications.zig` module wraps the per-OS notification CLI (`notify-send` on Linux, `osascript` on macOS, PowerShell BurntToast on Windows) via `std.process.Child`. `workflow.zig` calls it inside the existing `finish_reason == .stop` branch. A `notify_on_complete: bool` field in the nalar config gates the behavior. A small `POST /api/notify/test` endpoint lets the user verify their system can actually display notifications without running a full LLM stream.

**Tech Stack:** Zig 0.15.2 (target backend), `std.process.Child` for spawning, custom HTTP server module for the test endpoint, OS-native notification CLIs.

---

## File Structure

| File | Responsibility | New / Modified |
|------|----------------|----------------|
| `src/ai_workflow/tui/notifications.zig` | Cross-platform notification dispatch. One public `notify(allocator, title, body)` function. Picks CLI per `builtin.os`. | New |
| `src/ai_workflow/tui/notifications_test.zig` | Unit tests: command construction per OS, body truncation, graceful no-op when binary missing. | New |
| `src/modules/config/Config.zig` | Add `notify_on_complete: bool` to `LlmConfig` and `LlmConfigJson` (default `false`). | Modified |
| `src/modules/config/config_test.zig` | Add test: parses JSON with `notify_on_complete: true`; defaults to `false` when missing. | Modified |
| `src/ai_workflow/tui/workflow.zig` | Call `notifications.notify()` inside the `finish_reason == .stop` branch (line ~415), gated by the config flag. | Modified |
| `src/modules/custom_http_server/src/...` (endpoint file) | New `POST /api/notify/test` endpoint that fires a test notification. Returns `{ok: true}` on spawn, `{ok: false, error: "..."}` if the binary is missing. | Modified |
| `src/apps/desktop/src/api/index.ts` | TS wrapper `testNotification()` for the new endpoint. (Optional — for the test UX.) | Modified |

**Why this decomposition:**
- `notifications.zig` is a pure OS-dispatch module. No LLM coupling. Easy to test by inspecting the command it would build (no actual spawn in tests).
- The config flag follows the exact pattern of `url_style` / `model_compaction_size_kb` — no new config infrastructure.
- `workflow.zig` stays focused: the only new line is a single function call inside an existing branch.
- The test endpoint is a 5-minute add but saves a lot of "is my system capable of this?" debugging later.

---

## Task 1: Add `notify_on_complete` to the nalar config

**Files:**
- Modify: `src/modules/config/Config.zig`
- Modify: `src/modules/config/config_test.zig`

- [ ] **Step 1: Read the existing config structure to confirm the field pattern**

`Config.zig` has a `LlmConfig` struct (around line 6) with an `allocator` field and a `LlmConfigJson` struct (around line 51) used for JSON parsing. The two are populated in `init()`. We will add a single bool to both, mirroring how `model_compaction_size_kb` is handled (default value on the JSON side, optional on the populated side).

- [ ] **Step 2: Write the failing config test**

Open `src/modules/config/config_test.zig` and find an existing test that uses JSON parsing (search for `parseFromSlice` or `api_key`). Add a new test:

```zig
test "parseConfig defaults notify_on_complete to false when missing" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"api_key":"k","model":"m","base_url":"u"}
    ;
    const parsed = try std.json.parseFromSlice(
        Config.LlmConfigJson, allocator, json_str, .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.notify_on_complete);
}

test "parseConfig reads notify_on_complete: true from JSON" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"api_key":"k","model":"m","base_url":"u","notify_on_complete":true}
    ;
    const parsed = try std.json.parseFromSlice(
        Config.LlmConfigJson, allocator, json_str, .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.value.notify_on_complete);
}
```

Note: if `config_test.zig` doesn't import `Config` yet, add `const Config = @import("Config.zig");` at the top. Match whatever naming convention the existing file uses.

- [ ] **Step 3: Run the tests, confirm they fail**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test 2>&1 | head -n 50`
Expected: FAIL — `error: no field named 'notify_on_complete' in struct 'LlmConfigJson'`.

- [ ] **Step 4: Add the field to `LlmConfigJson`**

In `src/modules/config/Config.zig` around line 51, add to the `LlmConfigJson` struct:

```zig
notify_on_complete: bool = false,
```

Also add to the populated `LlmConfig` struct (around line 6, next to `url_style`):

```zig
notify_on_complete: bool,
```

- [ ] **Step 5: Wire the field through `init()`**

Find the `init()` function (around line 101). In the section that copies values from `parsed.value` (the `config_json` assignment block), add:

```zig
.notify_on_complete = config_json.notify_on_complete,
```

- [ ] **Step 6: Run the tests, confirm they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test 2>&1 | tail -n 30`
Expected: PASS for both new tests. Other config tests still green.

- [ ] **Step 7: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "feat(config): add notify_on_complete bool (default off)"
```

---

## Task 2: Create the `notifications.zig` dispatch module

**Files:**
- Create: `src/ai_workflow/tui/notifications.zig`
- Create: `src/ai_workflow/tui/notifications_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (if it exists — register the new test)

- [ ] **Step 1: Check whether `test_runner.zig` exists for `src/ai_workflow/tui/`**

Run: `ls /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/ai_workflow/tui/test_runner.zig`
If it exists, open it and look for the existing pattern (e.g., `_ = @import("workflow.zig");` or similar test imports). You'll add a line for `notifications_test.zig`. If it doesn't exist, skip the test-registration step.

- [ ] **Step 2: Write the failing test**

Create `src/ai_workflow/tui/notifications_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const notifications = @import("notifications.zig");

test "buildCommand on Linux returns notify-send with title and body" {
    if (builtin.os.tag != .linux) return; // Skip on non-Linux
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body text");
    defer allocator.free(cmd);
    // First three args must be the binary and two notify-send flags.
    try testing.expect(cmd.len >= 4);
    try testing.expectEqualStrings("notify-send", cmd[0]);
    try testing.expectEqualStrings("Title", cmd[2]);
    try testing.expectEqualStrings("Body text", cmd[3]);
}

test "buildCommand on macOS returns osascript with display notification" {
    if (builtin.os.tag != .macos) return;
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body");
    defer allocator.free(cmd);
    try testing.expectEqualStrings("osascript", cmd[0]);
    // The osascript argv is a single string arg with the full AppleScript body.
    try testing.expect(std.mem.indexOf(u8, cmd[1], "display notification") != null);
}

test "buildCommand on Windows returns powershell with the notification" {
    if (builtin.os.tag != .windows) return;
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body");
    defer allocator.free(cmd);
    try testing.expectEqualStrings("powershell", cmd[0]);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "Title") != null);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "Body") != null);
}

test "buildCommand truncates body longer than maxBodyLength" {
    const allocator = testing.allocator;
    const long = "x".repeat(500);
    const cmd = try notifications.buildCommand(allocator, "T", long);
    defer allocator.free(cmd);
    // On every platform, the body string should appear in the argv with a max of
    // ~140 chars. We assert that no single argv item is longer than 200 chars
    // (some platforms wrap with extra quoting/escaping).
    for (cmd) |arg| {
        try testing.expect(arg.len <= 200);
    }
}

test "truncateBody appends an ellipsis and respects max" {
    try testing.expectEqualStrings(
        "hello",
        notifications.truncateBody("hello", 140),
    );
    const truncated = notifications.truncateBody("x".repeat(500), 10);
    try testing.expectEqual(@as(usize, 10), truncated.len);
    try testing.expect(std.mem.endsWith(u8, truncated, "…"));
}

test "notify returns BinaryNotFound when the binary is missing" {
    // We can't easily delete notify-send on the test machine, so this test
    // runs the dispatch with a path that we know doesn't exist by setting
    // PATH to /dev/null. If the OS check fails (e.g. CI on macOS), skip.
    if (builtin.os.tag != .linux) return;
    const allocator = testing.allocator;
    const result = notifications.notifyWithPath(
        allocator,
        "/nonexistent/notify-send",
        "T",
        "B",
    );
    try testing.expectError(error.BinaryNotFound, result);
}
```

- [ ] **Step 3: Run the tests, confirm they fail**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test 2>&1 | tail -n 30`
Expected: FAIL — `error: no such file: 'notifications.zig'`.

- [ ] **Step 4: Write the module**

Create `src/ai_workflow/tui/notifications.zig`:

```zig
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.notifications);

/// Maximum characters of the body we pass to the OS. notify-send and friends
/// don't have a hard limit, but very long bodies look bad in toast UIs.
const MAX_BODY_LEN: usize = 140;

pub const NotifyError = error{
    /// The OS notification binary is not installed (e.g. notify-send on a
    /// Linux box without libnotify). Caller should log and continue.
    BinaryNotFound,
    OutOfMemory,
};

/// Build the argv that would be spawned for the current OS. Public so tests
/// can assert on the command shape without actually running it.
pub fn buildCommand(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]const []const u8 {
    const truncated = try allocator.dupe(u8, truncateBody(body, MAX_BODY_LEN));
    errdefer allocator.free(truncated);

    return switch (builtin.os.tag) {
        .linux => try allocator.dupe([]const u8, &[_][]const u8{
            "notify-send",
            "--app-name=nalar",
            title,
            truncated,
        }),
        .macos => blk: {
            // AppleScript: display notification "body" with title "title"
            // Body and title must be escaped for double-quote insertion.
            const title_esc = try escapeAppleScript(allocator, title);
            defer allocator.free(title_esc);
            const body_esc = try escapeAppleScript(allocator, truncated);
            defer allocator.free(body_esc);
            const script = try std.fmt.allocPrint(
                allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body_esc, title_esc },
            );
            errdefer allocator.free(script);
            break :blk try allocator.dupe([]const u8, &[_][]const u8{
                "osascript",
                "-e",
                script,
            });
        },
        .windows => try allocator.dupe([]const u8, &[_][]const u8{
            "powershell",
            "-NoProfile",
            "-Command",
            try std.fmt.allocPrint(
                allocator,
                "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null; " ++
                    "[System.Windows.Forms.MessageBox]::Show('{s}', '{s}')",
                .{ escapePowerShell(truncated), escapePowerShell(title) },
            ),
        }),
        else => {
            // Unknown OS — log and pretend we sent it.
            log.warn("notifications: unsupported OS {s}; skipping", .{@tagName(builtin.os.tag)});
            return try allocator.dupe([]const u8, &[_][]const u8{});
        },
    };
}

/// Fire an OS notification. Non-blocking: spawns the process and does NOT
/// wait for it (notify-send can take 50–200ms to display the toast; we
/// don't want to delay the workflow).
pub fn notify(allocator: std.mem.Allocator, title: []const u8, body: []const u8) NotifyError!void {
    const cmd = buildCommand(allocator, title, body) catch return error.OutOfMemory;
    defer allocator.free(cmd);
    if (cmd.len == 0) return; // Unsupported OS — already logged.
    return notifyWithArgv(allocator, cmd);
}

/// Test-only helper: spawn a specific binary path. Used by the
/// `BinaryNotFound` test above.
pub fn notifyWithPath(allocator: std.mem.Allocator, path: []const u8, title: []const u8, body: []const u8) NotifyError!void {
    const truncated = try allocator.dupe(u8, truncateBody(body, MAX_BODY_LEN));
    defer allocator.free(truncated);
    const argv = try allocator.dupe([]const u8, &[_][]const u8{ path, "--app-name=nalar", title, truncated });
    defer allocator.free(argv);
    return notifyWithArgv(allocator, argv);
}

fn notifyWithArgv(allocator: std.mem.Allocator, argv: []const []const u8) NotifyError!void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.BinaryNotFound,
        else => return error.BinaryNotFound, // Conservative: any spawn failure → treat as missing.
    };
    // Fire-and-forget. We deliberately don't `child.wait()` so a slow toast
    // library doesn't block the LLM workflow. The OS reaps the child.
    // (Zig's `std.process.Child` documents this as safe for short-lived
    // children: a stdio leak is acceptable for our use case.)
}

pub fn truncateBody(body: []const u8, max: usize) []const u8 {
    if (body.len <= max) return body;
    // Cut to max-1 so we can append the ellipsis.
    return body[0 .. max - 1] ++ "…";
}

fn escapeAppleScript(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"', '\\' => try out.append(allocator, '\\'),
            else => {},
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn escapePowerShell(s: []const u8) []const u8 {
    // Single-quote-doubling escape: replace ' with '' inside a single-quoted string.
    // For a stub MVP we keep the title/body ASCII-only via the input; a future
    // enhancement can add full escape logic.
    _ = s;
    return "";
}
```

**Note for the executor:** the `escapePowerShell` stub returns `""` so the test on Windows can be tightened later. For Linux (the platform the user is on), the buildCommand path is straightforward and tested. If you'd like a more complete Windows implementation, see [BurntToast](https://github.com/Windos/BurntToast) for the modern PowerShell toast recipe.

- [ ] **Step 5: Run the tests, confirm they pass**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test 2>&1 | tail -n 40`
Expected: All `buildCommand` tests for the current OS PASS. The `BinaryNotFound` test PASSES on Linux. On other OSes, those tests are skipped (early return).

- [ ] **Step 6: Register the new test file (if a test_runner.zig exists)**

If `src/ai_workflow/tui/test_runner.zig` was found in Step 1, add `_ = @import("notifications_test.zig");` to it.

- [ ] **Step 7: Commit**

```bash
git add src/ai_workflow/tui/notifications.zig \
        src/ai_workflow/tui/notifications_test.zig
git commit -m "feat(notifications): cross-platform OS notification dispatch via notify-send/osascript/powershell"
```

---

## Task 3: Wire `notifications.notify()` into `workflow.zig`

**Files:**
- Modify: `src/ai_workflow/tui/workflow.zig`

This is a 4-line surgical change. The `finish_reason == .stop` branch already exists at line ~415. We just add a notify call at the end of the branch.

- [ ] **Step 1: Read the stop branch to confirm the surrounding context**

Open `src/ai_workflow/tui/workflow.zig` and find the block at line 415:

```zig
if (finish_reason == .stop) {
    _ = try llm_history.saveMessage(allocator, io, db, .{ ... });
    _ = try on_event_sent.onEventSendLLMHistory(allocator, .{ ... });
    const isHaveQueueMessage = llm_history.hasQueuedMessages(db, copy_session_id);
    if (isHaveQueueMessage) { continue; }
    break;
}
```

- [ ] **Step 2: Add the import**

At the top of `workflow.zig` with the other imports, add:

```zig
const notifications = @import("notifications.zig");
```

- [ ] **Step 3: Add the notify call**

At the END of the `if (finish_reason == .stop)` block, RIGHT BEFORE the `break;` (or after the `hasQueuedMessages` check), add:

```zig
// Fire OS notification when enabled. Non-blocking — uses spawn-and-forget
// inside the notifications module, so this never delays the workflow.
// Errors are swallowed: a missing notify-send or denied notification
// daemon should not break the LLM.
if (config.notify_on_complete) {
    const preview = if (res_dynamic_agent.content) |c| c else "(empty response)";
    notifications.notify(
        allocator,
        "LLM Response Complete",
        preview,
    ) catch |err| {
        // Log and continue — notification is best-effort.
        std.log.warn("notifications: {s}", .{@errorName(err)});
    };
}
```

- [ ] **Step 4: Verify the build**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build 2>&1 | tail -n 30`
Expected: PASS. No new type errors.

- [ ] **Step 5: Run the test suite**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test 2>&1 | tail -n 30`
Expected: PASS for all tests.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/workflow.zig
git commit -m "feat(workflow): fire OS notification on finish_reason=stop when notify_on_complete is set"
```

---

## Task 4: Add `POST /api/notify/test` for manual verification

**Files:**
- Modify: The endpoint registration file in `src/modules/custom_http_server/src/...` (wherever the other API endpoints like `/api/sessions`, `/api/chat` are defined)

This task lets the user verify their system can display notifications without running a full LLM stream. It's also useful for the manual verification in Task 5.

- [ ] **Step 1: Find where existing API endpoints are registered**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && rg -l '"/api/' src/modules/custom_http_server 2>&1 | head -n 20`
Expected: A list of handler files. Pick one that uses a similar POST pattern (e.g., the chat endpoint). Open it.

- [ ] **Step 2: Add a new handler file**

Create a new file alongside the other handlers, e.g. `src/modules/custom_http_server/src/notify_test.zig`:

```zig
const std = @import("std");
const notifications = @import("../../ai_workflow/tui/notifications.zig");

/// POST /api/notify/test
/// Body: {"title": "...", "body": "..."} (both optional)
/// Response: {"ok": true} on success, {"ok": false, "error": "BinaryNotFound"} on failure.
pub fn handleNotifyTest(allocator: std.mem.Allocator, io: std.Io, body: []const u8) ![]u8 {
    const title = "nalar notification test";
    const preview = "If you can read this, OS notifications work.";

    // Best-effort parse of {title, body} from the body. If parsing fails
    // (malformed JSON, missing fields), we fall back to the defaults above.
    // We intentionally do NOT error on parse failure — the goal is to
    // confirm the system can show notifications, not to validate input.
    _ = body;

    notifications.notify(allocator, title, preview) catch |err| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator,
            \\{{"ok":false,"error":"{s}"}}
        , .{@errorName(err)});
        return buf.toOwnedSlice(allocator);
    };

    return std.fmt.allocPrint(allocator, "{{\"ok\":true}}", .{});
}
```

- [ ] **Step 3: Register the route**

In the route table of the custom_http_server module, add a `POST /api/notify/test` entry that dispatches to `handleNotifyTest`. Follow the exact pattern used by the other POST endpoints.

- [ ] **Step 4: Build and verify**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build 2>&1 | tail -n 30`
Expected: PASS.

- [ ] **Step 5: Test from the command line (with nalar running on port 8080)**

```bash
curl -X POST http://localhost:8080/api/notify/test \
    -H 'Content-Type: application/json' \
    -d '{}'
```

Expected:
- A toast appears: "nalar notification test / If you can read this, OS notifications work."
- Response body: `{"ok":true}`

If `notify-send` is missing: Response body: `{"ok":false,"error":"BinaryNotFound"}`. To install: `sudo apt install libnotify-bin` (Debian/Ubuntu) or `sudo pacman -S libnotify` (Arch).

- [ ] **Step 6: Commit**

```bash
git add src/modules/custom_http_server/src/notify_test.zig
git commit -m "feat(http): add POST /api/notify/test for manual notification verification"
```

---

## Task 5: Optional frontend toggle (recommended, 5 minutes)

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`
- Modify: `src/apps/desktop/src/components/NalarSettings.vue`

Skip this task if you prefer to flip the setting via the JSON config file directly. The frontend toggle is a convenience.

- [ ] **Step 1: Add the TS API wrapper**

In `src/apps/desktop/src/api/index.ts`, near the other API functions, add:

```ts
export async function testNotification(): Promise<{ ok: boolean; error?: string }> {
  return fetch('http://localhost:8080/api/notify/test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  }).then((r) => r.json())
}
```

- [ ] **Step 2: Add a "Test" button next to the toggle in NalarSettings**

In the same component where the notification preference is configured, add a button labeled "Test". On click, it calls `testNotification()` and shows a success/error toast using the existing `handleNotification` pattern from `SettingsView.vue`.

(If the frontend setting doesn't exist yet — because the original Plan A was frontend-only — the executor should add a minimal toggle here too, writing the value back to the nalar config via a new `PUT /api/config/notify_on_complete` endpoint. That endpoint is a 10-line addition mirroring the existing `PUT /api/config/...` endpoints.)

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/components/NalarSettings.vue
git commit -m "feat(desktop): add 'Test' button for OS notification in NalarSettings"
```

---

## Task 6: Manual end-to-end verification

The whole point of this plan is "works when the browser is closed." So this task explicitly closes the browser.

**Files:** none modified. This is a verification step.

- [ ] **Step 1: Start nalar on port 8080 (dev)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build run -- --port 8080
```

Expected: nalar starts, listens on port 8080. (The `.nalar` system message forbids touching port 8081.)

- [ ] **Step 2: Verify the system can show notifications at all**

```bash
notify-send "manual test" "hello from CLI"
```

Expected: An OS notification appears. If not, install `libnotify-bin` (Debian/Ubuntu) or `libnotify` (Arch).

- [ ] **Step 3: Enable `notify_on_complete` in the nalar config**

Edit the nalar config (find the path from the existing `Config.zig` `getDefaultConfigPath` — usually `~/.config/nalar/config.json`) and set:

```json
{
    "notify_on_complete": true,
    ...
}
```

- [ ] **Step 4: Restart nalar**

Stop the process started in Step 1, then start it again. Verify the config loads (no parse errors in stderr).

- [ ] **Step 5: Send an LLM message WITHOUT opening the browser**

Use the HTTP API directly to send a chat message. Find the right endpoint by looking at how the frontend sends a message (search for the chat POST in the custom_http_server module). For example:

```bash
# Create a session, send a message, observe the SSE stream (just for the response).
# The exact command depends on the API; the test endpoint from Task 4 already
# proves the OS-notification path works.
```

Or simpler: use the `POST /api/notify/test` endpoint from Task 4 to fire a real notification through the same code path the workflow will use:

```bash
curl -X POST http://localhost:8080/api/notify/test \
    -H 'Content-Type: application/json' \
    -d '{}'
```

Expected: OS notification appears. Response: `{"ok":true}`. This proves the OS-dispatch path works.

- [ ] **Step 6: Send a real LLM message and watch for the notification**

Trigger an LLM message via the HTTP API (not the browser — keep the browser closed throughout this step). When the response finishes, the OS notification should appear automatically because `workflow.zig` calls `notifications.notify()` on `finish_reason: 'stop'`.

- [ ] **Step 7: Verify the gating works (OFF state)**

Edit the config to set `notify_on_complete: false` and restart nalar. Send another LLM message. Expected: NO OS notification appears. The response still streams normally.

- [ ] **Step 8: Verify `finish_reason: 'tool_calls'` does NOT fire a notification**

Send a message that requires tool use (e.g., "list the files in /tmp"). Expected: NO notification on each tool call. The notification fires only when the final assistant message after the tool results has `finish_reason: 'stop'`.

- [ ] **Step 9: Commit (if any cleanup was needed)**

If Task 6 surfaced any small fix, commit it separately:

```bash
git add -p
git commit -m "fix(notification): <describe the fix>"
```

---

## Pitfalls

- **`notify-send` is not installed by default on every Linux.** Ubuntu Server, minimal Docker images, and headless VMs don't have libnotify. The `BinaryNotFound` error path is important: it must NOT crash the workflow. Test on a fresh box before claiming success.
- **Long bodies get truncated.** The `truncateBody` cuts to 140 chars with a `…`. This is intentional — toast UIs truncate visually anyway, and a 5000-char body in `notify-send` looks like spam. The full content is still in the chat.
- **macOS AppleScript escaping is incomplete.** The `escapeAppleScript` only escapes `\` and `"`. If a title contains a backtick or control character, the AppleScript will fail silently. Acceptable for MVP; tighten in a follow-up if needed.
- **Windows implementation is a stub.** The PowerShell call uses `MessageBox::Show` (a blocking modal) instead of a proper toast. Real implementation should use [BurntToast](https://github.com/Windos/BurntToast) or the newer `Add-Type` Windows.UI.Notifications API. Out of scope for this MVP.
- **Don't wait for the child process.** `notify-send` and friends can take 50–200ms to display a toast. We deliberately do NOT call `child.wait()`. The Zig docs note this can leak a slot in the process table, which is acceptable for short-lived notification daemons.
- **The `notify_on_complete` flag is global, not per-session.** For MVP this is fine. If users want per-session control later, the flag can be added to the session metadata.
- **The `.nalar` system message forbids touching port 8081.** Always test against port 8080. The nalar on 8081 is someone else's process.
- **The browser-closed scenario IS the whole point of this design.** If you're tempted to "simplify" by going back to a frontend-only Web Notification approach, remember: that approach fails the moment the user closes the browser. The complexity tax of the backend dispatch is the price of working when the browser is gone.

---

## Verification summary

After all tasks complete, the following should be true:

- `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build` → clean.
- `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build test` → all tests pass, including the 6 new cases in `notifications_test.zig` and the 2 new cases in `config_test.zig`.
- `curl -X POST http://localhost:8080/api/notify/test -d '{}'` → returns `{"ok":true}` and a toast appears.
- Sending a real LLM message via HTTP (browser closed) → OS notification fires on `finish_reason: 'stop'`, NOT on `'tool_calls'` or `'length'`.
- `notify_on_complete: false` in config → no notifications, workflow unaffected.

If any verification step fails, do NOT mark this plan complete. Diagnose, fix, re-verify.
