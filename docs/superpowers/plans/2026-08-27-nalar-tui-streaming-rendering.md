# `nalar-tui` streaming rendering — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `nalar-tui`'s chat stream render in the Vue frontend's
style (tool cards + hidden thinking) instead of dumping raw
`<tool>...</tool>` envelopes and `<think>...</think>` blocks, and
replace the yellow input-cursor background with a foreground-only caret.

**Architecture:** Three pure helpers (`think`, `tool_envelope`,
`render_msg`) feed one wiring change in `App.onMessages` plus a
one-liner in `Input.render`. No new HTTP endpoints, no new transports,
no new dependencies. All new code lives under
`src/apps/cli/src/tui/`. Tests are inline per project convention
(see `AGENTS.md`: "impl and test code should inline one file no need
split").

**Tech Stack:** Zig 0.16, existing `tui` module
(`Frame`/`Cell`/`Line`/`Style`/`Color`), `std.mem.indexOf`/`std.mem.eql`
for parsing, `std.ArrayList(Line)` for the renderer's output.

## Global Constraints

- **Zig 0.16** — `std.ArrayList(T)` is unmanaged; explicit allocator on
  every method call (`.append(alloc, x)`, `.deinit(alloc)`). Use
  `try testing.allocator.alloc(...)` and `defer testing.allocator.free(...)`
  in tests.
- **Inline tests.** Per `AGENTS.md`, every impl file has its
  `test "..."` blocks at the bottom in the SAME file. Do NOT create a
  parallel `*_test.zig` file.
- **Pure helpers where possible.** `think.zig` and `tool_envelope.zig`
  are dependency-free. `render_msg.zig` depends only on `think.zig`,
  `tool_envelope.zig`, and the existing `tui.widgets.Line`/`Style`.
  `App.onMessages` (in `tui/app.zig`) is the only file that knows the
  JSON wire shape.
- **No backend changes.** The REST endpoint
  `/api/llm/session/:id/messages` already returns
  `role`/`content`/`tool_name`/`reasoning_content`/etc. We only read.
- **No new external crate.** `tui/` already exposes everything.
- **Run `zig build test:tui --summary all` after every task** — every
  task ends with that command showing zero fails / zero leaks.
- **No `defer allocator.free` inside handlers** — the request arena
  handles it (per `AGENTS.md` rule "Per-Request Arena Cleanup").
  This rule does not apply to the TUI (no per-request arena here), so
  ordinary `defer` cleanup in tests is fine.

---

## Tasks

### Task 1 — Strip `<think>...</think>` blocks from assistant content

**Files:** `src/apps/cli/src/tui/think.zig` (new).

**TDD steps:**

- [ ] **RED.** Write the failing test in `think.zig` at the bottom:
      ```zig
      test "stripThinkingTags: removes single think block" {
          const got = stripThinkingTags("<think>hidden</think>visible");
          try testing.expectEqualStrings("visible", got);
      }
      ```
      Run `zig build test:tui --summary all`. Confirm it FAILS with
      `error: 'stripThinkingTags' has not been declared`.

- [ ] **GREEN.** Add the function:
      ```zig
      pub fn stripThinkingTags(content: []const u8) []const u8 {
          // Walk content; copy non-think ranges to out.
          // ... returns a slice into `content` with every
          // <think>...</think> block removed (tags + inner).
      }
      ```
      Run `zig build test:tui --summary all`. Confirm the new test
      PASSES. Confirm existing tests stay green.

- [ ] **RED.** Add a second test:
      ```zig
      test "stripThinkingTags: returns content unchanged when no tags" {
          const got = stripThinkingTags("plain assistant text");
          try testing.expectEqualStrings("plain assistant text", got);
      }
      ```
      Run `zig build test:tui --summary all`. Confirm PASSES (no new
      code needed — already handled by the passthrough branch).

- [ ] **RED → GREEN.** Add a third test:
      ```zig
      test "stripThinkingTags: handles leading think + trailing text" {
          const got = stripThinkingTags("<think>plan</think>the answer is 42");
          try testing.expectEqualStrings("the answer is 42", got);
      }
      ```
      Run; expect PASS.

- [ ] **RED → GREEN.** Add a fourth test for multiple blocks:
      ```zig
      test "stripThinkingTags: removes multiple think blocks" {
          const got = stripThinkingTags("<think>a</think>x<think>b</think>y");
          try testing.expectEqualStrings("xy", got);
      }
      ```
      Run; expect PASS.

- [ ] **RED → GREEN.** Add `isThinkingOnly`:
      ```zig
      test "isThinkingOnly: true when only think block present" {
          try testing.expect(isThinkingOnly("<think>plan</think>"));
      }
      test "isThinkingOnly: false when visible text remains" {
          try testing.expect(!isThinkingOnly("<think>plan</think>answer"));
      }
      test "isThinkingOnly: false when no tags" {
          try testing.expect(!isThinkingOnly("plain"));
      }
      ```
      Implement `isThinkingOnly` to first call `stripThinkingTags` and
      return `stripped.len == 0` after trimming whitespace.

- [ ] **Verify.**
      `zig build test:tui --summary all` — 0 fail, 0 leak.

- [ ] **Commit.**
      `git add src/apps/cli/src/tui/think.zig && git commit -m "feat(tui): add think-tag stripper (pure helper)"`

---

### Task 2 — Parse `<tool>...</tool>` envelopes

**Files:** `src/apps/cli/src/tui/tool_envelope.zig` (new).

**TDD steps:**

- [ ] **RED.** Write the failing test:
      ```zig
      test "tryParseToolEnvelope: valid envelope returns parsed struct" {
          const content =
              \\<tool><name>read_file</name><parameters><path>/foo.txt</path></parameters><success>true</success><data><content>hi</content></data></tool>
          ;
          const env = tryParseToolEnvelope(content) orelse unreachable;
          try testing.expectEqualStrings("read_file", env.name);
          try testing.expect(env.success);
          try testing.expectEqualStrings("<content>hi</content>", env.data);
          try testing.expectEqualStrings("", env.error);
      }
      ```
      Run `zig build test:tui --summary all`. Confirm FAILS with
      `'tryParseToolEnvelope' has not been declared`.

- [ ] **GREEN.** Add `ToolEnvelope` struct and `tryParseToolEnvelope`.
      Use `std.mem.indexOf` to find each tag (no full XML parser — the
      envelope is fixed-shape). Return `null` when `<tool>`, `<name>`,
      or `<success>` is missing.
      Run; confirm PASS. Existing tests stay green.

- [ ] **RED → GREEN.** Add error-path test:
      ```zig
      test "tryParseToolEnvelope: success=false with <error>" {
          const content =
              \\<tool><name>bash</name><parameters><command>bad</command></parameters><success>false</success><error>boom</error></tool>
          ;
          const env = tryParseToolEnvelope(content) orelse unreachable;
          try testing.expect(!env.success);
          try testing.expectEqualStrings("boom", env.error);
      }
      ```
      Run; PASS (no new code — already supported by the implementation).

- [ ] **RED → GREEN.** Add malformed-envelope test:
      ```zig
      test "tryParseToolEnvelope: malformed returns null" {
          try testing.expect(tryParseToolEnvelope("plain text") == null);
          try testing.expect(tryParseToolEnvelope("<tool>missing name</tool>") == null);
          try testing.expect(tryParseToolEnvelope("<tool><name>x</name></tool>") == null); // missing <success>
      }
      ```

- [ ] **RED → GREEN.** Add primary-field extractor + 3 whitelist tests:
      ```zig
      test "toolEnvelopePrimary: read_file uses <path> from data" {
          const env = tryParseToolEnvelope(
              "<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>hi</content></data></tool>"
          ) orelse unreachable;
          try testing.expectEqualStrings("/foo.txt", toolEnvelopePrimary(env));
      }
      test "toolEnvelopePrimary: search uses <query> from data" {
          const env = tryParseToolEnvelope(
              "<tool><name>search</name><parameters></parameters><success>true</success><data><query>foo bar</query><matches>3</matches></data></tool>"
          ) orelse unreachable;
          try testing.expectEqualStrings("foo bar", toolEnvelopePrimary(env));
      }
      test "toolEnvelopePrimary: bash falls back to first 60 chars of data" {
          const env = tryParseToolEnvelope(
              "<tool><name>bash</name><parameters></parameters><success>true</success><data><output>hello</output></data></tool>"
          ) orelse unreachable;
          try testing.expectEqualStrings("hello", toolEnvelopePrimary(env));
      }
      test "toolEnvelopePrimary: unknown tool falls back to its name" {
          const env = tryParseToolEnvelope(
              "<tool><name>weird_thing</name><parameters></parameters><success>true</success><data>x</data></tool>"
          ) orelse unreachable;
          try testing.expectEqualStrings("weird_thing", toolEnvelopePrimary(env));
      }
      ```
      Implement `toolEnvelopePrimary` with the whitelist from the design
      spec (read_file/write_file/text_replace → `<path>`, search →
      `<query>`, glob → `<pattern>`, bash/pwsh → first 60 chars of
      data or command, else → tool name).

- [ ] **Verify.** `zig build test:tui --summary all` — 0 fail.

- [ ] **Commit.** `git commit -am "feat(tui): add tool-envelope parser + primary extractor"`

---

### Task 3 — Dispatch a single message into rendered `[]Line`

**Files:** `src/apps/cli/src/tui/render_msg.zig` (new).

**TDD steps:**

- [ ] **RED.** Write the first failing test:
      ```zig
      test "renderMessage: user role yields bold prompt line" {
          const lines = try renderMessage(testing.allocator, .{
              .role = "user",
              .content = "hello",
              .tool_name = "",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expectEqual(@as(usize, 1), lines.len);
          try testing.expectEqualStrings("> hello", lines[0].text);
          try testing.expect(lines[0].style.bold);
          try testing.expectEqual(@as(?Color, .green), lines[0].style.fg);
      }
      ```
      Run; FAIL with `'renderMessage' has not been declared`.

- [ ] **GREEN.** Add `MessageView` struct and `renderMessage`. User
      branch: one `Line` of `"> " + content`, style `{ .fg = .green, .bold = true }`.
      Other branches stub to a single empty line so the test PASSES.
      Run; PASS.

- [ ] **RED → GREEN.** Add assistant tests:
      ```zig
      test "renderMessage: assistant with think block strips it" {
          const lines = try renderMessage(testing.allocator, .{
              .role = "assistant",
              .content = "<think>plan</think>the answer is 42",
              .tool_name = "",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expectEqualStrings("the answer is 42", lines[0].text);
      }
      test "renderMessage: assistant thinking-only yields chip line" {
          const lines = try renderMessage(testing.allocator, .{
              .role = "assistant",
              .content = "<think>just thinking</think>",
              .tool_name = "",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expectEqualStrings("… thinking …", lines[0].text);
          try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
      }
      ```
      Implement the assistant branch: if `isThinkingOnly(content)` → one
      dim `Line` of `"… thinking …"` in `.brightBlack`. Else → one or
      more `Line`s of `stripThinkingTags(content)` (one line per
      hard-break for now — full word-wrap is the viewport's job).

- [ ] **RED → GREEN.** Add tool tests:
      ```zig
      test "renderMessage: tool with valid envelope yields card line" {
          const content =
              "<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>x</content></data></tool>";
          const lines = try renderMessage(testing.allocator, .{
              .role = "tool",
              .content = content,
              .tool_name = "read_file",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expectEqualStrings("▶ read_file  /foo.txt  ✓", lines[0].text);
          try testing.expectEqual(@as(?Color, .magenta), lines[0].style.fg);
      }
      test "renderMessage: tool with error envelope yields ✗ card line" {
          const content =
              "<tool><name>bash</name><parameters></parameters><success>false</success><error>boom</error></tool>";
          const lines = try renderMessage(testing.allocator, .{
              .role = "tool",
              .content = content,
              .tool_name = "bash",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expect(std.mem.indexOf(u8, lines[0].text, "✗") != null);
          try testing.expectEqual(@as(?Color, .red), lines[0].style.fg);
      }
      test "renderMessage: tool with malformed content falls back to raw dim" {
          const lines = try renderMessage(testing.allocator, .{
              .role = "tool",
              .content = "some plain legacy output",
              .tool_name = "old_tool",
              .reasoning_content = "",
          });
          defer testing.allocator.free(lines);
          try testing.expectEqualStrings("some plain legacy output", lines[0].text);
          try testing.expectEqual(@as(?Color, .brightBlack), lines[0].style.fg);
      }
      ```
      Implement the tool branch: if `tryParseToolEnvelope(content)`
      returns non-null → build the header line
      `"▶ " + name + "  " + primary + "  " + (✓ or ✗)`, style
      `.{ .fg = success ? .magenta : .red }`. Else → one `Line` of raw
      content, style `.{ .fg = .brightBlack }`.

- [ ] **RED → GREEN.** Wire `render_msg.zig` to depend on `think.zig`
      and `tool_envelope.zig`:
      ```zig
      const think = @import("think.zig");
      const tool_envelope = @import("tool_envelope.zig");
      ```

- [ ] **Verify.** `zig build test:tui --summary all` — 0 fail.

- [ ] **Commit.** `git commit -am "feat(tui): add render_msg dispatcher (think strip + tool card + role colours)"`

---

### Task 4 — Wire `App.onMessages` to render via `renderMessage` + dedupe by id

**Files:** `src/apps/cli/src/tui/app.zig` (edit).

This is a behaviour change, so write the failing tests FIRST.

**TDD steps:**

- [ ] **RED.** Add the new dedupe + render tests at the bottom of
      `app.zig` (after the existing 3 `onMessages` tests; leave those
      in place — they still pass because the user-message path is
      unchanged):
      ```zig
      test "App: onMessages dedupes by message id (regression: <tool> x3 bug)" {
          var app = try testApp();
          defer app.deinit();
          app.is_streaming = true;
          // Same body polled twice — must NOT duplicate the tool card.
          const body =
              \\{"messages":[
              \\ {"id":"m1","role":"user","content":"hi"},
              \\ {"id":"m2","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/a</path><content>x</content></data></tool>"},
              \\ {"id":"m3","role":"assistant","content":"<think>p</think>done"}
              \\]}
          ;
          try app.onMessages(body);
          const first_count = app.viewport.lines.items.len;
          try app.onMessages(body); // re-poll
          try testing.expectEqual(first_count, app.viewport.lines.items.len);
      }

      test "App: onMessages renders tool card header (no raw <tool> xml)" {
          var app = try testApp();
          defer app.deinit();
          app.is_streaming = true;
          const body =
              \\{"messages":[
              \\ {"id":"m1","role":"tool","tool_name":"read_file","content":"<tool><name>read_file</name><parameters></parameters><success>true</success><data><path>/foo.txt</path><content>x</content></data></tool>"}
              \\]}
          ;
          try app.onMessages(body);
          // The viewport must contain the styled header, NOT the raw
          // <tool> envelope text.
          const lines = app.viewport.lines.items;
          try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "▶ read_file  /foo.txt  ✓") != null);
          try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "<tool>") == null);
      }

      test "App: onMessages strips <think> from assistant content" {
          var app = try testApp();
          defer app.deinit();
          app.is_streaming = true;
          const body =
              \\{"messages":[
              \\ {"id":"m1","role":"assistant","content":"<think>secret plan</think>hello user"}
              \\]}
          ;
          try app.onMessages(body);
          const lines = app.viewport.lines.items;
          try testing.expect(std.mem.indexOf(u8, lines[lines.len - 1].text, "<think>") == null);
          try testing.expectEqualStrings("hello user", lines[lines.len - 1].text);
      }

      test "App: onMessages renders thinking-only assistant as chip" {
          var app = try testApp();
          defer app.deinit();
          app.is_streaming = true;
          const body =
              \\{"messages":[
              \\ {"id":"m1","role":"assistant","content":"<think>just thinking</think>"}
          \\]}
          ;
          try app.onMessages(body);
          const lines = app.viewport.lines.items;
          try testing.expectEqualStrings("… thinking …", lines[lines.len - 1].text);
      }

      test "App: onMessages renders user prompt as > bold green" {
          var app = try testApp();
          defer app.deinit();
          app.is_streaming = true;
          const body =
              \\{"messages":[
              \\ {"id":"m1","role":"user","content":"hai"}
          \\]}
          ;
          try app.onMessages(body);
          const last = app.viewport.lines.items[app.viewport.lines.items.len - 1];
          try testing.expectEqualStrings("> hai", last.text);
          try testing.expect(last.style.bold);
          try testing.expectEqual(@as(?tui.Color, .green), last.style.fg);
      }
      ```
      Run `zig build test:tui --summary all`. Confirm the new tests
      FAIL (current `onMessages` appends raw content → fails the
      "renders tool card header" and "strips <think>" and "renders
      user prompt as > bold green" assertions).

- [ ] **GREEN.** Rewrite `onMessages`:
      1. Replace `seen_count: usize` with `seen_ids:
         std.StringHashMapUnmanaged(void) = .empty`. Add a matching
         field, initialize to `.empty`, free in `deinit`.
      2. Parse the JSON body as today.
      3. For each message in `messages`:
         - if `seen_ids.contains(msg.id)`, skip.
         - else: build a `MessageView` from the JSON fields, call
           `renderMessage(allocator, view)`, append the resulting
           `[]Line`s to the viewport. Mark `seen_ids` with `msg.id`.
      4. Keep the "is_streaming stops when last message is assistant"
         heuristic.

      Use `@import("render_msg.zig")` for `MessageView` + `renderMessage`
      and `@import("think.zig")` is reachable through render_msg.

      Run `zig build test:tui --summary all`. Confirm the new tests
      PASS and the existing 3 `onMessages` tests still pass.

- [ ] **Verify.** `zig build test:tui --summary all` — 0 fail, 0 leak.

- [ ] **Commit.** `git commit -am "feat(tui): wire onMessages to render via renderMessage + dedupe by id"`

---

### Task 5 — Replace input cursor background with foreground-only caret

**Files:** `src/apps/cli/src/tui/widgets.zig` (edit, one block).

**TDD steps:**

- [ ] **RED.** Add the failing test at the bottom of `widgets.zig`:
      ```zig
      test "Input: cursor cell uses foreground-only caret (no bg)" {
          var in = Input.init(testing.allocator);
          defer in.deinit();
          _ = try in.handleKey(.{ .rune = 'a' });
          var f = try in.render(testing.allocator, 20);
          defer f.deinit(testing.allocator);
          // Cursor sits at column 3 ("> a" is 3 chars).
          const cursor = f.get(3, 0);
          try testing.expectEqual(@as(u21, '|'), cursor.char);
          try testing.expect(cursor.bg == null);          // NO background fill
          try testing.expectEqual(@as(?Color, .white), cursor.fg);
          try testing.expect(cursor.bold);
      }
      ```
      Run `zig build test:tui --summary all`. Confirm the new test
      FAILS (current code sets `.bg = .white` and char = ' ').

- [ ] **GREEN.** In `Input.render` (widgets.zig:215-217), replace
      ```zig
      if (cx < width) {
          f.set(cx, 0, .{ .char = ' ', .bg = .white });
      }
      ```
      with
      ```zig
      if (cx < width) {
          f.set(cx, 0, .{ .char = '|', .fg = .white, .bold = true });
      }
      ```
      Run `zig build test:tui --summary all`. Confirm the new test
      PASSES. Confirm existing `Input.*` tests stay green.

- [ ] **Verify.** `zig build test:tui --summary all` — 0 fail.

- [ ] **Commit.** `git commit -am "fix(tui): input cursor is fg-only caret, no yellow bg fill"`

---

### Task 6 — End-to-end smoke

- [ ] **Build.** `zig build install:tui`. Confirm `zig-out/bin/nalar-tui`
      is produced.
- [ ] **Smoke (manual).** With the dev server on `:8081`, run
      `nalar-tui --server http://localhost:8081`. Type `hai`. Confirm:
      - `> hai` renders as a green/bold prompt.
      - Tool rows render as `▶ load_memory  user preferences language  ✓`
        (no raw `<tool>` envelope text visible).
      - Assistant reply renders as plain text with no `<think>` block
        visible.
      - The input row cursor is a `|` character, NOT a yellow block.
      - Pressing Enter a second time does NOT re-render the previous
        tool cards (dedupe-by-id regression test).
- [ ] **Commit docs (if needed).** If you changed the help text or
      flags, update `src/apps/cli/README.md` and commit.

---

### Task 7 — Open PR

- [ ] Push branch: `git push origin HEAD`.
- [ ] Open a PR with title
      `feat(cli): render nalar-tui stream like Vue — tool cards, hidden
       thinking, no yellow cursor`.
- [ ] PR body bullets:
      - TDD — every behaviour has a failing test that drives the impl.
      - Inline tests per project convention.
      - `zig build test:tui --summary all` 0 fail / 0 leak.
      - Manual smoke verified against the live server.
      - No backend changes (pure frontend rendering).

---

## Pitfalls

- **Don't write impl first.** Tasks 1–5 each have a RED → GREEN step.
  Watch the test FAIL for the right reason before writing any
  production code. If a test fails for an import / typo reason, fix
  the test, not the impl.
- **Don't run the smoke before task 4.** Until the wiring change in
  `App.onMessages` lands, the tool cards won't appear at all — a
  half-shipped build is worse than no build.
- **Don't add expand/collapse.** Explicit non-goal. The body is folded
  away in v1. Adding it would balloon scope.
- **Don't join via `tool_call_id`.** Out of scope; v1 relies on
  `tool_name` arriving on the tool row, which it already does.
- **Don't change the screenshot's "rendering > 1 tool card for the
  same `<tool>` envelope".** That's the regression the dedupe-by-id
  test (Task 4) exists to prevent.
- **The yellow cursor is a terminal-rendering quirk, not a bug in
  every terminal.** The fix is benign everywhere — a foreground-only
  caret is universally supported.

## Verification (run before opening PR)

- [ ] `zig build test:tui --summary all` → 0 fail, 0 leak.
- [ ] `zig build install:tui` → `zig-out/bin/nalar-tui` produced.
- [ ] Manual smoke against `http://localhost:8081` (see Task 6).
- [ ] `git log --oneline` shows one commit per task (5 task commits +
      docs/optional commit).
- [ ] No files outside `src/apps/cli/src/tui/` (except possibly
      `src/apps/cli/README.md` and the plan/spec docs).
- [ ] PR title matches the convention.
