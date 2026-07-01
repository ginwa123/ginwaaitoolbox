# Standardize `is_input` / `is_output` Wire Format on JSON Boolean

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `is_input` and `is_output` use a single consistent representation end-to-end: **SQLite `INTEGER` (0/1) on disk**, **`bool` in Zig**, **`true`/`false` JSON booleans on the wire** (REST + SSE), and **`boolean` in TypeScript**.

**Why:** Today the same logical value uses **four different types** depending on which layer you touch, and the REST API emits the field as a **JSON string** (`"is_input":"1"`) while the SSE emits it as a **JSON boolean** (`"is_input":true`). The frontend declares the type as `string` and compares with `=== '1'`. This makes the wire format unpredictable and forces every reader to know which convention applies.

| Layer | Today (inconsistent) | After refactor |
|---|---|---|
| SQLite column | `INTEGER` (0/1) ✓ | unchanged |
| Zig internal API (`TUIHistory`, `SaveMessageInput`, `OnEventInputLLMHistory`, `SseEventLLMHistory`, `models.TUIHistory`, `handle_tool` params) | `bool` ✓ | `bool` (unchanged — natural type) |
| Zig REST wire-format struct (`llm_history.SessionMessage`, `http_response.SessionMessage`) | `[]const u8` ✗ | `bool` |
| Zig SSE wire-format struct (`SseEventLLMHistory`) | `bool` ✓ | `bool` (unchanged) |
| REST JSON output (`buildSessionMessagesJson`) | `"is_input":"1"` (string) ✗ | `"is_input":true` (bool) |
| SSE JSON output (`onEventSendLLMHistory` via `std.json.fmt`) | `"is_input":true` ✓ | `"is_input":true` (unchanged) |
| XML output (`buildSessionMessagesXml`) | `<is_input>1</is_input>` (text) | `<is_input>true</is_input>` (text "true"/"false") |
| TypeScript `Message` / `SseEventLLMHistory` interface | `is_input?: string` ✗ | `is_input?: boolean` |
| Vue runtime comparison (`m.is_output === '1'`) | string compare ✗ | `m.is_output === true` (boolean compare) |

**Architecture decision:** Pick **JSON boolean `true`/`false`** as the wire-format type. Rationale:
- **Smaller refactor**: SSE path is already emitting booleans (`SseEventLLMHistory.is_input: bool` → `std.json.fmt` → JSON `true`/`false`). Only REST needs to catch up.
- **No `bool` ↔ `u8` round-trip**: the in-memory type is `bool` everywhere; only the SQL bind layer converts to "0"/"1" string for `db.exec` (a private, no-format-change-needed step).
- **Natural TypeScript shape**: `boolean` is self-documenting; `m.is_output === true` is the idiomatic Vue/TS check.
- **Trade-off accepted**: DB column is `INTEGER` (0/1) but wire is `bool` (true/false). The conversion happens at the SQL read/write boundary (already does, today). This is invisible to the consumer — both representations are valid SQLite "truthy" values.

**Tech Stack:** Zig 0.16, SQLite, Vue 3 + TypeScript, Vitest

---

## Files Touched (8)

### Backend Zig (3 files)
1. `src/ai_workflow/tui/llm_history.zig` — `SessionMessage` struct, DB read sites, `buildSessionMessagesJson`, `buildSessionMessagesXml`
2. `src/ai_workflow/tui/http_handlers/http_response.zig` — `SessionMessage` wire-format struct (for `makeSessionMessagesResponse` via `std.json.Stringify.valueAlloc`)
3. `src/ai_workflow/tui/http_handlers/session_messages_get.zig` — no logic change, just type compat

### Frontend (2 files)
4. `src/apps/desktop/src/api/index.ts` — `Message` and `SseEventLLMHistory` interfaces
5. `src/apps/desktop/src/components/ChatView.vue` — `Message` interface + `=== '1'` → `=== true`

### Tests (3 new or updated)
6. `src/ai_workflow/tui/llm_history_is_input_output_test.zig` (new) — wire-format contract tests
7. `src/apps/desktop/src/__tests__/sseIsInputOutput.spec.ts` (new) — frontend type + comparison contract
8. *(no test changes needed in `on_event_sent_sanitize_test.zig` — SSE was already bool)*

---

## Chunk 1: Backend wire-format struct + serialization

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:442-498, 605-615, 774-779, 858-870, 1140-1150, 1390-1400`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:156-172`

### Task 1.1: Change `SessionMessage.is_input` / `is_output` from `[]const u8` to `bool`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:449-450, 466-467`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:162-163`

- [ ] **Step 1: Update the struct field types in `llm_history.zig`**

In `src/ai_workflow/tui/llm_history.zig:442-480` (the `SessionMessage` struct), replace:

```zig
pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: []const u8,
    // New columns
    is_input: []const u8,
    is_output: []const u8,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    ...

    pub fn deinit(self: *const SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        ...
        allocator.free(self.is_input);  // ← remove
        allocator.free(self.is_output); // ← remove
        ...
    }
};
```

with:

```zig
pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    timestamp: []const u8,
    /// Wire-format boolean. Emitted as JSON `true`/`false` by
    /// `buildSessionMessagesJson` (manual format) and by
    /// `makeSessionMessagesResponse` (via `std.json.Stringify.valueAlloc`).
    /// Matches the SSE `SseEventLLMHistory.is_input` shape and the
    /// TypeScript `is_input?: boolean` type. The DB column is
    /// `INTEGER` (0/1); the SQL read site converts with `parseRowBool`.
    /// See docs/plans/2026-07-01-is-input-output-bool-consistency.md.
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    ...

    pub fn deinit(self: *const SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        ...
        // is_input / is_output are bool (not slices) — no free needed
        ...
    }
};
```

- [ ] **Step 2: Update the wire-format struct in `http_response.zig`**

In `src/ai_workflow/tui/http_handlers/http_response.zig:156-172` (the `SessionMessage` struct used by `makeSessionMessagesResponse`), apply the same change:

```zig
pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at: []const u8,
    is_input: bool,   // was: []const u8
    is_output: bool,  // was: []const u8
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: []const u8 = "",
    diffview_after: []const u8 = "",
    image_url: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_calls_json: []const u8 = "",
};
```

The conversion in `src/ai_workflow/tui/http_handlers/session_messages_get.zig:74-75` (`.is_input = msg.is_input, .is_output = msg.is_output`) needs no change — both sides are now `bool`.

- [ ] **Step 3: Verify build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 20
```

Expected: `compile exe nalar` succeeds. The `deinit` signature change may surface downstream errors that Tasks 1.2 + 1.3 fix.

### Task 1.2: Update DB read paths in `llm_history.zig` to populate `bool`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:613-614, 1146-1147, 1396-1397`

- [ ] **Step 1: Add a `parseRowBool` helper**

In `src/ai_workflow/tui/llm_history.zig` (insert just before the first `getMessages`-style function — anywhere above the first `row.values[...]` use of `is_input`/`is_output` columns), add:

```zig
/// Parse a SQLite INTEGER column value (returned by the SQL binder
/// as a `[]const u8` slice) into a bool. Empty string is `false`
/// (matches `COALESCE(col, 0)` semantics). Used for `is_input` /
/// `is_output` which the SQL binder returns as `[]const u8` slices
/// but the in-memory struct expects as `bool`.
fn parseRowBool(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == '1';
}
```

(Defensive against empty / unexpected values. The column is documented as 0/1 — `s[0] == '1'` matches SQLite's "0" / "1" canonical form.)

- [ ] **Step 2: Update `getSessionMessagesSorted` row assembly (line 607-615)**

Replace:

```zig
const msg = SessionMessage{
    ...
    .is_input = try allocator.dupe(u8, row.values[5]),
    .is_output = try allocator.dupe(u8, row.values[6]),
    ...
};
```

with:

```zig
const msg = SessionMessage{
    ...
    .is_input = parseRowBool(row.values[5]),
    .is_output = parseRowBool(row.values[6]),
    ...
};
```

- [ ] **Step 3: Update `getMessages` (TUIHistory) row assembly (line 1146-1147)**

The `TUIHistory` struct already has `is_input: bool` (in `src/ai_workflow/tui/models.zig:31-32`) — keep it `bool`, just swap the source from the brittle `std.mem.eql(..., "1")` to the new helper:

Replace:

```zig
.is_input = std.mem.eql(u8, row.values[19], "1"),
.is_output = std.mem.eql(u8, row.values[20], "1"),
```

with:

```zig
.is_input = parseRowBool(row.values[19]),
.is_output = parseRowBool(row.values[20]),
```

- [ ] **Step 4: Update `getLatestMessage` (line 1396-1397)**

Same change as Step 3 (the `TUIHistory` assembly in `getLatestMessage` mirrors `getMessages`).

- [ ] **Step 5: Verify build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 20
```

Expected: compiles clean. If you see `error: no field named 'is_input' in struct 'http_response.SessionMessage'`, Task 1.1 Step 2 wasn't applied.

### Task 1.3: Update JSON + XML serialization in `llm_history.zig`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:774-779, 858-870`

- [ ] **Step 1: Update `buildSessionMessagesJson` (line 774-779)**

The current code emits the value as a JSON string with quotes (`"is_input":"{s}"`). We need to drop the inner quotes and emit `true`/`false` literals. The cleanest approach is to build the "true"/"false" string at the call site and pass it to the `{s}` format specifier (no quotes in the format string itself):

Replace the `msg_json` block in `buildSessionMessagesJson`:

```zig
const msg_json = try std.fmt.allocPrint(allocator,
    \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
    \\"is_input":"{s}","is_output":"{s}","tool_name":"{s}","finish_reason":"{s}","reasoning_content":"{s}"}}
, .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, msg.is_input, msg.is_output, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
```

with (note the format-string change: `"is_input":{s}` and `"is_output":{s}` — no inner quotes around the format placeholder):

```zig
// is_input / is_output are bool — emit as JSON booleans (not strings).
// `"is_input":"1"` is the old wrong format; `"is_input":true` is correct.
const is_input_str = if (msg.is_input) "true" else "false";
const is_output_str = if (msg.is_output) "true" else "false";
const msg_json = try std.fmt.allocPrint(allocator,
    \\{{"id":"{s}","session_id":"{s}","role":"{s}","content":"{s}","timestamp":"{s}",
    \\"is_input":{s},"is_output":{s},"tool_name":"{s}","finish_reason":"{s}","reasoning_content":"{s}"}}
, .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
```

Key change: `"is_input":"{s}"` → `"is_input":{s}` (no quotes around the value). The Zig `bool` is converted to the JSON literal string at the call site.

- [ ] **Step 2: Update `buildSessionMessagesXml` (line 858-870)**

XML text content is just text — no JSON quote semantics. We can keep the `{s}` placeholder and just feed it `"true"`/`"false"` from the same conversion:

Replace the `msg_xml` block in `buildSessionMessagesXml`:

```zig
const msg_xml = try std.fmt.allocPrint(allocator,
    \\<message id="{s}">
    \\<session_id>{s}</session_id>
    \\<role>{s}</role>
    \\<content>{s}</content>
    \\<timestamp>{s}</timestamp>
    \\<is_input>{s}</is_input>
    \\<is_output>{s}</is_output>
    \\<tool_name>{s}</tool_name>
    \\<finish_reason>{s}</finish_reason>
    \\<reasoning_content>{s}</reasoning_content>
    \\</message>
, .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, msg.is_input, msg.is_output, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
```

with:

```zig
// is_input / is_output as XML text content. Match the JSON wire
// format: emit "true" / "false" (not "1" / "0") so the LLM
// consumers (read_messages tool etc.) see the same shape on both
// the JSON and the XML paths.
const is_input_str = if (msg.is_input) "true" else "false";
const is_output_str = if (msg.is_output) "true" else "false";
const msg_xml = try std.fmt.allocPrint(allocator,
    \\<message id="{s}">
    \\<session_id>{s}</session_id>
    \\<role>{s}</role>
    \\<content>{s}</content>
    \\<timestamp>{s}</timestamp>
    \\<is_input>{s}</is_input>
    \\<is_output>{s}</is_output>
    \\<tool_name>{s}</tool_name>
    \\<finish_reason>{s}</finish_reason>
    \\<reasoning_content>{s}</reasoning_content>
    \\</message>
, .{ escaped_id, escaped_session_id, escaped_role, escaped_content, escaped_timestamp, is_input_str, is_output_str, escaped_tool_name, escaped_finish_reason, escaped_reasoning_content });
```

Key change: the args `msg.is_input` / `msg.is_output` (still `[]const u8`-like in format — but now they're `bool`!) become `is_input_str` / `is_output_str` (the precomputed "true"/"false" strings). The format string itself is unchanged — only the args change.

- [ ] **Step 3: Verify build + run existing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 20
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected:
- `install:linux:system`: `compile exe nalar` succeeds.
- `build test`: same pass count as the pre-change baseline (876/876 + 3 skipped per the 2026-06-28 CI matrix memory; verify by comparing to `git stash && timeout 180 zig build test --summary all 2>&1 | tail -n 5`).

If a test fails with `expected '"is_input":"1"' but got '"is_input":true'`, the test was asserting the old (string) format — that test gets updated in Chunk 3.

---

## Chunk 2: Frontend (TypeScript + Vue)

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:558-559, 736-737`
- Modify: `src/apps/desktop/src/components/ChatView.vue:114-115, 607, 1146-1147, 1763-1764`

### Task 2.1: Update TypeScript interfaces

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:558-559, 736-737`

- [ ] **Step 1: Update the `Message` interface**

In `src/apps/desktop/src/api/index.ts:558-559`, change:

```ts
is_input?: string,
is_output?: string
```

to:

```ts
is_input?: boolean,
is_output?: boolean
```

- [ ] **Step 2: Update the `SseEventLLMHistory` interface**

In `src/apps/desktop/src/api/index.ts:736-737`, same change:

```ts
is_input?: boolean,
is_output?: boolean,
```

- [ ] **Step 3: Verify the type check passes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean build. If `vue-tsc` complains about "Property 'is_input' is not assignable to type 'boolean'", the consumer site (ChatView, see next task) wasn't updated.

### Task 2.2: Update Vue `Message` interface + comparison

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:114-115, 607`

- [ ] **Step 1: Update the local `Message` interface in ChatView.vue**

In `src/apps/desktop/src/components/ChatView.vue:114-115`, change:

```ts
is_input?: string,
is_output?: string,
```

to:

```ts
is_input?: boolean,
is_output?: boolean,
```

- [ ] **Step 2: Update the `=== '1'` comparison**

In `src/apps/desktop/src/components/ChatView.vue:607` (the `showPreviewMessages` computed), change:

```ts
const showPreviewMessages = computed(() =>
  messages.value.filter((m) => m.tool_name === 'show_preview' && m.is_output === '1')
)
```

to:

```ts
const showPreviewMessages = computed(() =>
  messages.value.filter((m) => m.tool_name === 'show_preview' && m.is_output === true)
)
```

- [ ] **Step 3: Verify the build + tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected:
- `bun run build`: clean (no `vue-tsc` errors, no `oxlint`/`eslint` errors).
- `bunx vitest run`: same pass count as the pre-change baseline. (Vitest in this project doesn't run `vue-tsc`, so it can pass even with type errors — but the build step catches those. **Always run both** per project memory `desktop-typescript-bun-build-as-typecheck.md`.)

### Task 2.3: Verify the forwarding sites still work

**Files:**
- Read-only check: `src/apps/desktop/src/components/ChatView.vue:1146-1147, 1763-1764`

- [ ] **Step 1: Read both forwarding sites and confirm no logic change is needed**

```bash
sed -n '1140,1150p;1755,1770p' \
  /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop/src/components/ChatView.vue
```

Expected output (no changes):
```ts
// Line 1146-1147 (REST path, loadChatHistory):
is_input: msg.is_input,
is_output: msg.is_output

// Line 1763-1764 (SSE path, full event):
is_input: event.is_input,
is_output: event.is_output
```

These are direct field passthroughs — no value transformation, no string conversion. Since the source type and target type are now both `boolean`, no change is needed.

- [ ] **Step 2: Build + test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

---

## Chunk 3: Backend regression tests

**Files:**
- New: `src/ai_workflow/tui/llm_history_is_input_output_test.zig`

### Task 3.1: Add a static-contract test for `buildSessionMessagesJson` and `buildSessionMessagesXml`

- [ ] **Step 1: Find an appropriate test file (or create one)**

```bash
ls /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/ai_workflow/tui/llm_history*_test.zig
```

If none exist, create `src/ai_workflow/tui/llm_history_is_input_output_test.zig`. Otherwise, append the new test to the existing file.

- [ ] **Step 2: Add the tests**

```zig
const std = @import("std");
const testing = std.testing;
const llm_history = @import("llm_history.zig");

test "buildSessionMessagesJson emits is_input/is_output as JSON booleans" {
    const allocator = testing.allocator;

    // Build a minimal SessionMessageResponse with known values.
    // is_input: true, is_output: false — assert these render as booleans.
    const response = llm_history.SessionMessageResponse{
        .messages = &[_]llm_history.SessionMessage{
            .{
                .id = "m1",
                .session_id = "s1",
                .role = "user",
                .content = "hi",
                .timestamp = "1700000000",
                .is_input = true,
                .is_output = false,
                .tool_name = "",
                .finish_reason = "",
                .reasoning_content = "",
            },
        },
        .has_more = false,
        .next_cursor = null,
        .max_total_tokens = 0,
        .max_capacity_total_tokens = 0,
    };

    const json = try llm_history.buildSessionMessagesJson(allocator, &response);
    defer allocator.free(json);

    // Must contain boolean form (no quotes around true/false):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":false") != null);
    // Must NOT contain string form (the old wrong format):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\":\"1\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\":\"0\"") == null);
    // Must NOT contain number form (the alternative refactor that was rejected):
    try testing.expect(std.mem.indexOf(u8, json, "\"is_input\": 1") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_output\": 0") == null);
}

test "buildSessionMessagesXml emits is_input/is_output as text 'true'/'false'" {
    const allocator = testing.allocator;

    const response = llm_history.SessionMessageResponse{
        .messages = &[_]llm_history.SessionMessage{
            .{
                .id = "m1",
                .session_id = "s1",
                .role = "user",
                .content = "hi",
                .timestamp = "1700000000",
                .is_input = true,
                .is_output = false,
                .tool_name = "",
                .finish_reason = "",
                .reasoning_content = "",
            },
        },
        .has_more = false,
        .next_cursor = null,
        .max_total_tokens = 0,
        .max_capacity_total_tokens = 0,
    };

    const xml = try llm_history.buildSessionMessagesXml(allocator, &response);
    defer allocator.free(xml);

    // XML text content: <is_input>true</is_input> (bool rendered as text).
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>true</is_input>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>false</is_output>") != null);
    // Must NOT contain the old "1"/"0" text form:
    try testing.expect(std.mem.indexOf(u8, xml, "<is_input>1</is_input>") == null);
    try testing.expect(std.mem.indexOf(u8, xml, "<is_output>0</is_output>") == null);
}
```

- [ ] **Step 3: Register the test file (if new) in `test_runner.zig`**

If you created `llm_history_is_input_output_test.zig`, add to `src/ai_workflow/tui/test_runner.zig`:

```zig
_ = @import("llm_history_is_input_output_test.zig");
```

If you appended to an existing file, no registration change needed.

- [ ] **Step 4: Run the test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: +2 tests pass (the JSON boolean test + the XML boolean test). Total: previous baseline + 2.

### Task 3.2: Add a static-contract test for the SSE wire format (defense-in-depth)

The SSE path was already emitting booleans (no code change in this plan), but we should lock in the contract with a test so a future refactor doesn't regress it to numbers or strings.

**Files:**
- Modify: `src/ai_workflow/tui/on_event_sent_sanitize_test.zig` (append a new test)

- [ ] **Step 1: Add a regression test**

Append to `src/ai_workflow/tui/on_event_sent_sanitize_test.zig`:

```zig
test "SseEventLLMHistory emits is_input/is_output as JSON booleans" {
    const allocator = std.testing.allocator;
    const tree1_mod = @import("nalarcore");
    const on_event_sent = tree1_mod.on_event_sent;
    const SseEventLLMHistory = on_event_sent.SseEventLLMHistory;

    // Build a minimal payload.
    const payload = SseEventLLMHistory{
        .content = "hi",
        .session_id = "s1",
        .model = "m1",
        .cwd = "/",
        .role = "assistant",
        .finish_reason = null,
        .tool_calls_json = null,
        .tool_call_id = null,
        .tool_name = null,
        .agent_name = null,
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = true,   // <-- bool (not u8, not string)
        .is_output = false, // <-- bool
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .indent_4 })});

    // Must contain boolean form:
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_input\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_output\": false") != null);
    // Must NOT contain string form:
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_input\":\"1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_output\":\"0\"") == null);
    // Must NOT contain number form:
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_input\": 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"is_output\": 0") == null);
}
```

- [ ] **Step 2: Run the test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected: +1 test pass (the SSE bool test). Total: baseline + 3 (1 from this task + 2 from Task 3.1).

---

## Chunk 4: Frontend regression test

**Files:**
- New: `src/apps/desktop/src/__tests__/sseIsInputOutput.spec.ts`

### Task 4.1: Add a frontend type + comparison contract test

- [ ] **Step 1: Create the test file**

```ts
import { describe, it, expect } from 'vitest'
import type { SseEventLLMHistory } from '../api'

// Compile-time assertion: SseEventLLMHistory.is_input is boolean, not string.
const _typeCheck: SseEventLLMHistory = {
  is_input: true,
  is_output: false,
}
// @ts-expect-error -- string is NOT a valid is_input value
const _typeCheckBadString: SseEventLLMHistory = {
  is_input: '1',
  is_output: '0',
}

describe('SSE is_input / is_output wire format', () => {
  it('is_input / is_output are booleans in the event payload', () => {
    // The contract: the wire format is true/false booleans. Enforced by
    // the backend tests in src/ai_workflow/tui/on_event_sent_sanitize_test.zig
    // and src/ai_workflow/tui/llm_history_is_input_output_test.zig.
    // The frontend just needs to parse them as booleans and compare as booleans.
    const event: Partial<SseEventLLMHistory> = {
      is_input: true,
      is_output: false,
    }
    expect(event.is_input).toBe(true)
    expect(event.is_output).toBe(false)
  })

  it('ChatView showPreviewMessages filter uses === true (boolean compare)', async () => {
    // Static-contract test: the file's runtime behavior is exercised by
    // the live component tests. Here we just assert the pattern is in place.
    const fs = await import('node:fs/promises')
    const path = await import('node:path')
    const chatviewPath = path.resolve(
      __dirname,
      '..',
      'components',
      'ChatView.vue'
    )
    const source = await fs.readFile(chatviewPath, 'utf8')
    // The filter must compare against the boolean true, not the string '1'.
    expect(source).toMatch(/is_output\s*===\s*true\b/)
    expect(source).not.toMatch(/is_output\s*===\s*'1'/)
  })
})
```

- [ ] **Step 2: Run the test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run sseIsInputOutput 2>&1 | tail -n 20
```

Expected: 2/2 tests pass.

- [ ] **Step 3: Build (full type check)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean. If `vue-tsc` errors on the `@ts-expect-error` line, it means the type already correctly rejects strings — remove the line. If the `@ts-expect-error` does NOT error, the test is doing its job (the type truly does reject strings).

---

## Chunk 5: End-to-end verification

- [ ] **Step 1: Full backend build**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 10
timeout 180 zig build test --summary all 2>&1 | tail -n 5
```

Expected:
- `install:linux:system`: 4/6 steps succeed (the cp /usr/local/bin/nalar fails harmlessly).
- `build test`: baseline + 3 (1 SSE bool test from Task 3.2 + 2 backend regression tests from Task 3.1).

- [ ] **Step 2: Full frontend build + tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected:
- `bun run build`: clean (no `vue-tsc` errors, no lint errors).
- `bunx vitest run`: baseline + 2 (the new `sseIsInputOutput.spec.ts`).

- [ ] **Step 3: Live smoke test (port 8080)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
PID=$!
sleep 2

# Hit the session messages endpoint and confirm the wire format is JSON boolean.
# First, find a session_id from the DB (or use a known one):
SESSION_ID="session_xxx"  # replace with a real session_id from your DB
curl -sS "http://127.0.0.1:8080/api/sessions/$SESSION_ID/messages?limit=1" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["messages"][0]; print("is_input:", m["is_input"], type(m["is_input"]).__name__); print("is_output:", m["is_output"], type(m["is_output"]).__name__)'

# Expected:
#   is_input: True <class 'bool'>
#   is_output: False <class 'bool'>

kill $PID
```

If `is_input` / `is_output` come back as strings (`"1"`, `"0"`) or numbers (`1`, `0`), the `buildSessionMessagesJson` change didn't land — re-check Task 1.3 Step 1.

- [ ] **Step 4: Frontend smoke test (open the app, send a chat, observe a message bubble)**

Open the desktop app, send a user message, observe:
- The user message bubble renders (this checks the REST path).
- The assistant response bubble renders (this checks the SSE path).
- Open DevTools → Network → `messages?session_id=...` and `llm` EventSource: the payloads should show `"is_input": true` (bool, no quotes), NOT `"is_input":"1"` (string) or `"is_input": 1` (number).
- The previews panel (showPreviewMessages filter) should render previews correctly.

---

## Rollback strategy

If the refactor breaks production:

1. **Backend rollback**: `git revert` the merge commit. The wire-format change is contained to 3 files (`llm_history.zig`, `http_response.zig`, `session_messages_get.zig`) — a single revert restores the old string format and the frontend still works (it was already string-typed before).
2. **Frontend rollback**: independent — `git revert` the frontend commits. Frontend + backend don't need to ship together; the frontend can ship first against the old string-format backend (old code does `=== '1'` which still works against `"1"` strings).
3. **DB is untouched**: the schema migration for `is_input`/`is_output` columns (Migration 016) is preserved. No data migration needed in either direction.

---

## Out of scope

- **`is_thinking` field** has the same wire-format shape (DB INTEGER, Zig `bool`, JSON `true`/`false` via `std.json.fmt`). It's already a bool in the wire format — no inconsistency to fix. (Trivial follow-up: rename or document its semantics, not in scope here.)
- **Other message-typed fields** with similar potential inconsistency (e.g. `tool_calls_json`'s `[]const u8` shape) are out of scope.
- **Database migration to change the column type** — not needed. `INTEGER` already accepts 0/1 and is what the rest of the system uses.
- **Renaming `is_input` / `is_output`** to a more generic `is_user` / `is_assistant` — out of scope. (Some other plans have considered this; not part of this consistency refactor.)
- **SSE path code changes** — the SSE was already emitting booleans (the `SseEventLLMHistory` struct has `is_input: bool` and `std.json.fmt` emits it as `true`/`false`). Only Task 3.2 adds a regression test to lock in the contract.

---

## Verification checklist (paste into PR description)

- [ ] `zig build install:linux:system` succeeds (no compile errors).
- [ ] `zig build test --summary all` shows baseline + 3 tests.
- [ ] `bun run build` succeeds (no `vue-tsc` / lint errors).
- [ ] `bunx vitest run` shows baseline + 2 tests.
- [ ] `curl http://127.0.0.1:8080/api/sessions/$SID/messages` returns `"is_input": true` (bool, no quotes).
- [ ] DevTools Network shows SSE `llm_full` event with `"is_input": true` (bool).
- [ ] ChatView previews panel renders for messages with `is_output === true` (boolean compare).
- [ ] No string-form (`"is_input":"1"`) or number-form (`"is_input": 1`) JSON output anywhere in the live payloads.
- [ ] DB column is unchanged (`INTEGER` (0/1) — no migration applied).
