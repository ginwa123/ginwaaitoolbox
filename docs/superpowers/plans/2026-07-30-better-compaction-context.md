# [better compaction context] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed two slices of context into the compacted compaction XML so the next iteration of the agent has the full picture without depending on the (now-orphaned) previous history:

1. **All user chat history** for the session — every `llm_history` row where `role='user'` and `response_content IS NOT NULL`, in chronological order.
2. **All files the AI touched via `read_file`** — every `llm_history` row where `tool_name='read_file'` AND `is_output=1`, parsed to extract the `<path>...</path>` value from the XML envelope in `response_content`. Returned as a deduplicated, ordered list of paths.

Both slices are queried and embedded **before** the existing `mark_history_not_for_llmrun` step takes them offline (`is_feed_to_llm=0`), so the fresh INSERT into `llm_history` carries the full context forward to the next agent iteration.

**Architecture:**

1. **NEW** `src/ai_workflow/tui/agentic_loop/compaction_context.zig` — three small query helpers:
   - `fetchUserChatHistory(allocator, db, session_id) ![]UserTurn` — `SELECT response_content, created_at FROM llm_history WHERE session_id = ? AND role = 'user' AND response_content IS NOT NULL AND response_content != '' ORDER BY created_at ASC`.
   - `fetchReadFilePaths(allocator, db, session_id) ![]PathTurn` — `SELECT response_content, created_at FROM llm_history WHERE session_id = ? AND tool_name = 'read_file' AND is_output = 1 ORDER BY created_at ASC`. Each `PathTurn` is parsed in-place to extract the `<path>` value.
   - `parseReadFilePath(content) ?[]const u8` — extracts the path between `<path>` and `</path>` in the read_file XML envelope. Pure-function helper, no allocation.

2. **NEW** `src/ai_workflow/tui/agentic_loop/compaction_context_test.zig` — 6 behavioural tests covering the two queries (with seed rows + a check that the returned content matches) and the path parser (success, missing-tag, malformed-tag, repeated-path dedup).

3. **EDIT** `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` — replace the two TODO comments at line 130-135 with real code:
   - Call `fetchUserChatHistory` and `fetchReadFilePaths` (both gated by `messages.items.len > 4` — same `total <= 4` early-return that's already in `compactMessageInMemoryNew:169`, so we don't pay the query cost for tiny sessions).
   - Embed both into the `compacted_xml` via a new `enrichCompactionXml(allocator, compacted_xml, user_turns, read_paths) ![]u8` helper that returns `compacted_xml` + a `<user_history>` XML block + a `<read_files>` XML block, concatenated.
   - Pass the enriched XML into `compactMessagesInMemory` instead of the bare `compacted_xml`.

4. **NEW** `src/ai_workflow/tui/agentic_loop/compaction_enrich_test.zig` — 4 behavioural tests covering `enrichCompactionXml`:
   - Empty user history + empty read paths → output is the original `compacted_xml` verbatim (no empty wrapper blocks leaked).
   - With user history + read paths → output contains both wrapped blocks with the right content.
   - 50-element user history → all 50 entries present in the output XML (no truncation).
   - Repeated read_file on the same path → emitted once in the read_files block (dedup contract).

**Tech Stack:** Zig 0.16 (project pin), SQLite (via `nalarcore.sqlite.SqliteBackend` in-memory DB pattern from `workflow_compaction_envelope_test.zig` and `mark_history_not_for_llmrun` at `src/ai_workflow/tui/agentic_loop/markHistoryNotForLLMRun.zig:6-12`), `std.ArrayList` for accumulator builds, `std.fmt.allocPrint` for escaping.

**Decisions taken (with rationale):**

1. **Query BEFORE `mark_history_not_for_llmrun`** — the existing `compactMessageInMemoryNew` flips `is_feed_to_llm=0` on every row in the session at line 172. The new queries must run while `is_feed_to_llm=1` is still the natural state OR while `is_feed_to_llm=0` doesn't matter (the queries don't filter by `is_feed_to_llm`). Looking at this: the queries don't filter by `is_feed_to_llm` — they filter by `session_id` + `role`/`tool_name`. So they're orthogonal to the mark. The natural insertion point is in `maybeCompactMessagesNew` (the parent), which already has the `db` and `session_id` in scope; it calls `compactMessagesInMemory` AFTER the enrichment. The TODO comments at line 130-135 confirm this is the intended site.

2. **Don't filter by `is_feed_to_llm`** — the session's history may already have `is_feed_to_llm=0` rows from a *previous* compaction round in the same session (e.g., a long task that compacted twice). Filtering would drop that history. The wire rule is "everything this session has ever seen" — exactly what the agent needs to make decisions.

3. **`<user_history>` and `<read_files>` as sibling XML blocks**, not nested inside `<summary>` — the existing `buildCompactionEnvelope` already wraps the summary in `<summary><![CDATA[...]]></summary>`. Adding new top-level siblings maintains the envelope's parseability for downstream consumers (the next agent's LLM call, the test assertions). The new blocks are plain XML (not CDATA) because they contain only scalar fields (strings, paths) — no embedded `<`/`>` that would require escaping.

4. **Path-extraction via pure-string scan, not JSON parser** — `read_file.zig:90-104` produces the XML envelope with `<path>...</path>` as the FIRST tag. A simple `std.mem.indexOf("<path>")` + `indexOf("</path>")` is sufficient, no parser needed. The same pattern is used in `tools_wrap_output.zig` for the agent-side XML rendering. Don't over-engineer.

5. **Deduplicate read paths** — same file read twice (e.g., once near the start, once near the end) → emit once. Order is preserved (first-seen wins) so the list is deterministic across calls. Same intent as the `tags` column in `kanban_tags_validation.zig` (case-insensitive dedup, first wins).

6. **No `cwd` field on the user_history or read_files entries** — the agent sees the session's `cwd` from the `<metadata>` block already in the envelope (`buildCompactionEnvelope:285-292`). The user_history and read_files blocks are content-only; the agent joins paths with `cwd` at read time.

7. **Hard cap on user history content per entry** — match the existing `MAX_INDEX_ENTRIES` cap pattern at `buildCompactionEnvelope:261` (currently `50` for the message index). For user history, cap at 100 entries and 2000 chars per entry — keeps the envelope bounded for sessions with very long user messages. Truncated entries are marked with `<truncated_by>N</truncated_by>` so the next agent knows the entry was clipped.

8. **Pass-through pattern for the `compactMessagesInMemory` signature** — the existing `compactMessageInMemoryNew` takes `compacted_xml: []const u8` and passes it to `buildCompactionEnvelope`. Since `enrichCompactionXml` returns a new `[]u8`, no signature change is needed — just call it at the call site and pass the enriched result. The new `[]u8` lifetime is bounded by the `maybeCompactMessagesNew` scope; `compactMessagesInMemoryNew` reads it synchronously and embeds it into the envelope, so no leak.

## Global Constraints

- **Cross-platform (Linux + macOS + Windows)** — the new queries are pure SQLite via `SqliteBackend` (cross-platform). The path parser is pure `std.mem.indexOf` (cross-platform). The XML envelope is plain ASCII (no encoding concerns). Cross-compile via `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` for the new files (per project memory `zig-cross-platform.md`).
- **Zig 0.16 stdlib** — uses `std.ArrayList`, `std.fmt.allocPrint`, `std.mem.indexOf`, `std.c.strdup` (via `alloc.dupe`). No stdlib API removals affect this plan.
- **TDD** — behavioural tests first (RED), then implementation (GREEN). Each helper has its own test file.
- **Surgical patch** — the TODO comments at lines 130-135 in `workflow_commpact_message.zig` are replaced with 4 new lines (call fetchUserChatHistory, call fetchReadFilePaths, build enriched XML, pass through). No refactoring of the surrounding compaction logic.
- **Verification before completion** — `zig build test --summary all` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` must all pass before any task is marked complete.
- **No frontend changes** — backend-only feature; the agent sees the enriched context, the user doesn't.
- **No DB migrations** — queries use existing columns (`session_id`, `role`, `tool_name`, `is_output`, `response_content`, `created_at`).
- **No wire-format changes** — the compaction XML is internal to the next-compaction cycle; the frontend never sees it. The persisted `llm_history` row that holds the compacted summary is a single user-role message with the new envelope in `response_content`, but the frontend's chat renderer ignores `<compact_messages>` content (it just shows it as a literal XML blob the user can scroll past). No SSE event shape changes.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/compaction_context.zig` | NEW | ~150 |
| `src/ai_workflow/tui/agentic_loop/compaction_context_test.zig` | NEW | ~200 |
| `src/ai_workflow/tui/agentic_loop/compaction_enrich_test.zig` | NEW | ~150 |
| `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` | EDIT | +12 / -4 |
| `src/ai_workflow/tui/agentic_loop/mod.zig` | EDIT | +3 (re-export `compaction_context`) |
| `src/ai_workflow/tui/test_runner.zig` | EDIT | +2 (register new test files) |

Total: ~6 files, +17 net for production code, +350 for tests. No DB migrations, no frontend changes, no new dependencies.

---

## Tasks

### Task 1 — `compaction_context.zig`: two SQL query helpers + a path parser

**Goal:** Add the two SELECT queries that read user history and read_file paths from `llm_history`, plus a `parseReadFilePath` helper that extracts the `<path>` value from the read_file XML envelope.

**File:** `src/ai_workflow/tui/agentic_loop/compaction_context.zig`

- [ ] **Step 1.1** — Create the new file with the module preamble and the two helper structs:
  ```zig
  const std = @import("std");
  const mod = @import("mod.zig");
  const nalarcore = mod.nalarcore;
  const sqlite = nalarcore.sqlite;

  /// One user-turn row from `llm_history`. Used to embed the full user
  /// history into the compacted envelope so the next iteration of the agent
  /// sees the original ask + every refinement, not just the compactor's
  /// summary.
  pub const UserTurn = struct {
      content: []const u8,
      created_at: []const u8,

      pub fn deinit(self: UserTurn, allocator: std.mem.Allocator) void {
          allocator.free(self.content);
          allocator.free(self.created_at);
      }
  };

  /// One read_file tool-call row from `llm_history`. The `path` is the
  /// extracted value from the `<path>...</path>` tag in the XML envelope
  /// (NOT the raw `response_content`). `raw_content` is kept for debugging
  /// and for the test fixtures that assert on the full XML; production
  /// callers only consume `path`.
  pub const ReadFileTurn = struct {
      path: []const u8,
      raw_content: []const u8,
      created_at: []const u8,

      pub fn deinit(self: ReadFileTurn, allocator: std.mem.Allocator) void {
          allocator.free(self.path);
          allocator.free(self.raw_content);
          allocator.free(self.created_at);
      }
  };
  ```

- [ ] **Step 1.2** — Add the path parser as a pure-function helper:
  ```zig
  /// Extract the `<path>...</path>` value from the read_file XML envelope.
  /// Returns `null` if the tag is missing or malformed. The slice is borrowed
  /// from `content` (no allocation) — the caller MUST keep `content` alive
  /// for the lifetime of the returned slice.
  pub fn parseReadFilePath(content: []const u8) ?[]const u8 {
      const start_tag = "<path>";
      const end_tag = "</path>";
      const start = std.mem.indexOf(u8, content, start_tag) orelse return null;
      const path_start = start + start_tag.len;
      const end = std.mem.indexOf(u8, content[path_start..], end_tag) orelse return null;
      return content[path_start .. path_start + end];
  }
  ```

- [ ] **Step 1.3** — Add the `fetchUserChatHistory` query. Returns an `ArrayList(UserTurn)` (heap-allocated, caller frees each entry then the list). The query mirrors the existing `markHistoryNotForLLMRun` SQL shape (id-by-id, single-bind, void return semantics) but with `query` (returning rows) instead of `exec`:
  ```zig
  pub fn fetchUserChatHistory(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      session_id: []const u8,
  ) !std.ArrayList(UserTurn) {
      var turns: std.ArrayList(UserTurn) = .empty;
      errdefer {
          for (turns.items) |t| t.deinit(allocator);
          turns.deinit(allocator);
      }

      var rows = try db.query(
          allocator,
          "SELECT response_content, created_at " ++
              "FROM llm_history " ++
              "WHERE session_id = ? " ++
              "  AND role = 'user' " ++
              "  AND response_content IS NOT NULL " ++
              "  AND response_content != '' " ++
              "ORDER BY created_at ASC, id ASC",
          &.{session_id},
      );
      defer rows.deinit();

      while (try rows.next()) |row| {
          defer row.deinit(allocator);
          try turns.append(allocator, .{
              .content = try allocator.dupe(u8, row.values[0]),
              .created_at = try allocator.dupe(u8, row.values[1]),
          });
      }
      return turns;
  }
  ```

- [ ] **Step 1.4** — Add the `fetchReadFilePaths` query. Identical pattern, but the path is parsed from the `response_content` via `parseReadFilePath`. Rows where the path is missing (malformed XML) are SKIPPED with a `logger.warnFmt` — better to drop a single bad row than fail the whole compaction. Deduplication is the caller's responsibility (we emit in insertion order; the caller drops duplicates):
  ```zig
  pub fn fetchReadFilePaths(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      session_id: []const u8,
      logger: *nalarcore.loggermod.Logger,
  ) !std.ArrayList(ReadFileTurn) {
      var turns: std.ArrayList(ReadFileTurn) = .empty;
      errdefer {
          for (turns.items) |t| t.deinit(allocator);
          turns.deinit(allocator);
      }

      var rows = try db.query(
          allocator,
          "SELECT response_content, created_at " ++
              "FROM llm_history " ++
              "WHERE session_id = ? " ++
              "  AND tool_name = 'read_file' " ++
              "  AND is_output = 1 " ++
              "ORDER BY created_at ASC, id ASC",
          &.{session_id},
      );
      defer rows.deinit();

      while (try rows.next()) |row| {
          defer row.deinit(allocator);
          const raw = try allocator.dupe(u8, row.values[0]);
          const created_at = try allocator.dupe(u8, row.values[1]);
          const path = parseReadFilePath(raw) orelse {
              logger.warnFmt(
                  "[COMPACTION] read_file row missing <path> tag (id={?s})",
                  .{if (row.values.len > 2) row.values[2] else null},
              );
              allocator.free(raw);
              allocator.free(created_at);
              continue;
          };
          const path_owned = try allocator.dupe(u8, path);
          try turns.append(allocator, .{
              .path = path_owned,
              .raw_content = raw,
              .created_at = created_at,
          });
      }
      return turns;
  }
  ```

- [ ] **Step 1.5** — Add the `enrichCompactionXml` helper. Takes the bare `compacted_xml` (the compactor's output) and embeds two sibling XML blocks (`<user_history>` and `<read_files>`) BEFORE the existing `<summary>` so the next agent's LLM sees the user history first, then the read files, then the summary. The `cwd` parameter is accepted but ONLY used for absolute-path resolution in the read_files block (e.g., relative paths from a `git_worktree_cwd` aware session would be joined to `cwd`):
  ```zig
  /// Embed the user history and read_file paths into the compacted XML.
  /// The result is a new `[]u8` allocated from `allocator`; the caller
  /// owns it. The original `compacted_xml` is left untouched (the helper
  /// dups the content during the embed).
  ///
  /// Output shape:
  ///   <compaction_context>
  ///     <user_history>
  ///       <turn created_at="...">content</turn>
  ///       ...
  ///     </user_history>
  ///     <read_files count="N">
  ///       <path abs="...">...</path>
  ///       ...
  ///     </read_files>
  ///     <summary>
  ///       <![CDATA[original compacted_xml]]>
  ///     </summary>
  ///   </compaction_context>
  ///
  /// Hard caps: 100 user turns, 2000 chars per user turn. Read paths are
  /// deduplicated (first occurrence wins, insertion order preserved).
  pub fn enrichCompactionXml(
      allocator: std.mem.Allocator,
      compacted_xml: []const u8,
      user_turns: []const UserTurn,
      read_files: []const ReadFileTurn,
      cwd: []const u8,
  ) ![]u8 {
      const MAX_USER_TURNS: usize = 100;
      const MAX_USER_CONTENT_CHARS: usize = 2000;

      var out: std.ArrayList(u8) = .empty;
      errdefer out.deinit(allocator);

      try out.appendSlice(allocator, "<compaction_context>\n");

      // ── user_history ───────────────────────────────────────────────
      try out.appendSlice(allocator, "  <user_history");
      if (user_turns.len > MAX_USER_TURNS) {
          try out.print(allocator, " truncated_by=\"{d}\"", .{user_turns.len - MAX_USER_TURNS});
      }
      try out.appendSlice(allocator, ">\n");
      const show_user_count = @min(user_turns.len, MAX_USER_TURNS);
      for (user_turns[0..show_user_count]) |t| {
          const truncated = if (t.content.len > MAX_USER_CONTENT_CHARS)
              t.content[0..MAX_USER_CONTENT_CHARS]
          else
              t.content;
          const escaped = try xmlEscape(allocator, truncated);
          defer allocator.free(escaped);
          try out.print(allocator,
              "    <turn created_at=\"{s}\">{s}</turn>\n",
              .{ t.created_at, escaped },
          );
      }
      try out.appendSlice(allocator, "  </user_history>\n");

      // ── read_files (deduped; first-occurrence wins) ───────────────
      var seen: std.StringHashMapUnmanaged(void) = .empty;
      defer seen.deinit(allocator);
      try out.appendSlice(allocator, "  <read_files>\n");
      for (read_files) |rf| {
          if (seen.contains(rf.path)) continue;
          try seen.put(allocator, rf.path, {});
          const abs = try resolvePath(allocator, rf.path, cwd);
          defer allocator.free(abs);
          const escaped = try xmlEscape(allocator, rf.path);
          defer allocator.free(escaped);
          try out.print(allocator,
              "    <path abs=\"{s}\">{s}</path>\n",
              .{ abs, escaped },
          );
      }
      try out.appendSlice(allocator, "  </read_files>\n");

      // ── summary (the original compactor output, wrapped in CDATA) ─
      try out.appendSlice(allocator, "  <summary><![CDATA[\n");
      try out.appendSlice(allocator, compacted_xml);
      try out.appendSlice(allocator, "\n]]></summary>\n");

      try out.appendSlice(allocator, "</compaction_context>\n");

      return out.toOwnedSlice(allocator);
  }
  ```

- [ ] **Step 1.6** — Add the two private helpers `xmlEscape` and `resolvePath`. The `xmlEscape` mirrors the existing `nalarcore.helpers.xml_escape` (which is already used in `buildCompactionEnvelope:326`) but is duplicated here to keep this file self-contained (the `helpers` module has different import paths and pulling it in just for two helpers is more friction than value). The `resolvePath` is a thin wrapper that joins cwd + relative paths:
  ```zig
  fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
      var buf: std.ArrayList(u8) = .empty;
      errdefer buf.deinit(allocator);
      for (s) |c| {
          switch (c) {
              '&' => try buf.appendSlice(allocator, "&amp;"),
              '<' => try buf.appendSlice(allocator, "&lt;"),
              '>' => try buf.appendSlice(allocator, "&gt;"),
              '"' => try buf.appendSlice(allocator, "&quot;"),
              '\'' => try buf.appendSlice(allocator, "&apos;"),
              else => try buf.append(allocator, c),
          }
      }
      return buf.toOwnedSlice(allocator);
  }

  fn resolvePath(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]u8 {
      if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
      return std.fs.path.join(allocator, &.{ cwd, path });
  }
  ```

- [ ] **Step 1.7** — Verify the file compiles by running `timeout 60 zig build-obj -fno-emit-bin -target x86_64-linux-gnu -lc --dep nalarcore -Mroot=src/ai_workflow/tui/agentic_loop/compaction_context.zig -Mnalarcore=src/root.zig`. Expected: clean compile, no errors.

### Task 2 — `compaction_context_test.zig`: 6 behavioural tests

**Goal:** Lock in the contracts of the two queries and the path parser with real (in-memory SQLite) calls, not grep tests.

**File:** `src/ai_workflow/tui/agentic_loop/compaction_context_test.zig`

- [ ] **Step 2.1** — Create the file with preamble + `setupDb` / `seedRows` helpers. Mirror the pattern from `workflow_compaction_envelope_test.zig:13-80` (open in-memory DB, create `llm_history` table with the columns we need, seed via `db.exec`):
  ```zig
  const std = @import("std");
  const testing = std.testing;
  const builtin = @import("builtin");
  const nalarcore = @import("nalarcore");
  const sqlite = nalarcore.sqlite;
  const logger_mod = nalarcore.loggermod;
  const ctx = @import("compaction_context.zig");

  fn setupDb() !struct {
      db: sqlite.SqliteBackend,
      threaded: std.Io.Threaded,
  } {
      const alloc = testing.allocator;
      var threaded = std.Io.Threaded.init(alloc, .{});
      errdefer threaded.deinit();
      const io = threaded.io();
      var db: sqlite.SqliteBackend = .{};
      errdefer db.deinit();
      try db.init(io, ":memory:");
      try db.exec(alloc,
          "CREATE TABLE llm_history (" ++
          "  id TEXT PRIMARY KEY," ++
          "  session_id TEXT NOT NULL," ++
          "  role TEXT," ++
          "  tool_name TEXT," ++
          "  response_content TEXT," ++
          "  is_input INTEGER," ++
          "  is_output INTEGER," ++
          "  is_feed_to_llm INTEGER," ++
          "  created_at DATETIME DEFAULT CURRENT_TIMESTAMP" ++
          ")",
          &.{},
      );
      return .{ .db = db, .threaded = threaded };
  }

  fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
      s.db.deinit();
      s.threaded.deinit();
  }

  fn seedRow(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, row: struct {
      id: []const u8,
      session_id: []const u8,
      role: []const u8,
      tool_name: []const u8,
      content: []const u8,
      is_input: u32,
      is_output: u32,
      created_at: []const u8,
  }) !void {
      try db.exec(alloc,
          "INSERT INTO llm_history (id, session_id, role, tool_name, response_content, is_input, is_output, is_feed_to_llm, created_at) " ++
              "VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)",
          &.{ row.id, row.session_id, row.role, row.tool_name, row.content, "0", "0", row.created_at },
      );
  }
  ```

- [ ] **Step 2.2** — Register the test file in `src/ai_workflow/tui/test_runner.zig` (insert after the existing `workflow_commpact_message_test` or similar entry):
  ```zig
  _ = @import("agentic_loop/compaction_context_test.zig");
  _ = @import("agentic_loop/compaction_enrich_test.zig");
  ```

- [ ] **Step 2.3** — Add the path parser tests (pure-function, no DB needed):
  ```zig
  test "parseReadFilePath extracts the path from a valid envelope" {
      const content = "<path>/home/user/foo.zig</path>\n<content>body</content>";
      try testing.expectEqualStrings("/home/user/foo.zig", ctx.parseReadFilePath(content).?);
  }

  test "parseReadFilePath returns null when the tag is missing" {
      const content = "<content>body without a path</content>";
      try testing.expect(ctx.parseReadFilePath(content) == null);
  }

  test "parseReadFilePath returns null when the close tag is missing" {
      const content = "<path>/home/user/foo.zig\n<content>body</content>";
      try testing.expect(ctx.parseReadFilePath(content) == null);
  }

  test "parseReadFilePath handles paths with spaces and unicode" {
      const content = "<path>/home/user/My Files/日本語.txt</path><content>x</content>";
      try testing.expectEqualStrings("/home/user/My Files/日本語.txt", ctx.parseReadFilePath(content).?);
  }
  ```

- [ ] **Step 2.4** — Add the `fetchUserChatHistory` test (seeds 3 user rows + 1 assistant row + 1 user row with NULL content + 1 user row from a different session, asserts only the 3 valid rows from the matching session are returned, in chronological order):
  ```zig
  test "fetchUserChatHistory returns only matching session's user rows with non-null content, in chrono order" {
      var s = try setupDb();
      defer teardownDb(&s);
      const alloc = testing.allocator;

      try seedRow(alloc, &s.db, .{
          .id = "u1", .session_id = "sess_a", .role = "user", .tool_name = "",
          .content = "first ask", .is_input = 1, .is_output = 0,
          .created_at = "2026-01-01 00:00:01",
      });
      try seedRow(alloc, &s.db, .{
          .id = "a1", .session_id = "sess_a", .role = "assistant", .tool_name = "",
          .content = "first reply", .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:02",
      });
      try seedRow(alloc, &s.db, .{
          .id = "u2", .session_id = "sess_a", .role = "user", .tool_name = "",
          .content = "second ask", .is_input = 1, .is_output = 0,
          .created_at = "2026-01-01 00:00:03",
      });
      try seedRow(alloc, &s.db, .{
          .id = "u3", .session_id = "sess_a", .role = "user", .tool_name = "",
          .content = "", .is_input = 1, .is_output = 0,  // empty content -> filtered
          .created_at = "2026-01-01 00:00:04",
      });
      try seedRow(alloc, &s.db, .{
          .id = "u_x", .session_id = "sess_b", .role = "user", .tool_name = "",
          .content = "wrong session", .is_input = 1, .is_output = 0,
          .created_at = "2026-01-01 00:00:01",
      });

      var turns = try ctx.fetchUserChatHistory(alloc, &s.db, "sess_a");
      defer {
          for (turns.items) |t| t.deinit(alloc);
          turns.deinit(alloc);
      }

      try testing.expectEqual(@as(usize, 2), turns.items.len);
      try testing.expectEqualStrings("first ask", turns.items[0].content);
      try testing.expectEqualStrings("second ask", turns.items[1].content);
      try testing.expectEqualStrings("2026-01-01 00:00:01", turns.items[0].created_at);
      try testing.expectEqualStrings("2026-01-01 00:00:03", turns.items[1].created_at);
  }
  ```

- [ ] **Step 2.5** — Add the `fetchReadFilePaths` test (seeds 4 read_file rows: 2 valid, 1 different session, 1 with `is_output=0` (should be filtered), 1 malformed XML —asserts only the 2 valid ones returned, in chrono order, with `path` extracted):
  ```zig
  test "fetchReadFilePaths returns only matching session's read_file outputs, with parsed paths" {
      var s = try setupDb();
      defer teardownDb(&s);
      const alloc = testing.allocator;

      try seedRow(alloc, &s.db, .{
          .id = "rf1", .session_id = "sess_a", .role = "tool", .tool_name = "read_file",
          .content = "<path>/home/user/foo.zig</path>\n<content>foo body</content>",
          .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:01",
      });
      try seedRow(alloc, &s.db, .{
          .id = "rf2", .session_id = "sess_a", .role = "tool", .tool_name = "read_file",
          .content = "<path>/home/user/bar.zig</path>\n<content>bar body</content>",
          .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:02",
      });
      try seedRow(alloc, &s.db, .{
          .id = "rf3", .session_id = "sess_a", .role = "tool", .tool_name = "read_file",
          .content = "<path>/home/user/ignored.zig</path>",
          .is_input = 1, .is_output = 0,  // input not output -> filtered
          .created_at = "2026-01-01 00:00:03",
      });
      try seedRow(alloc, &s.db, .{
          .id = "rf_x", .session_id = "sess_b", .role = "tool", .tool_name = "read_file",
          .content = "<path>/home/user/wrong.zig</path>",
          .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:01",
      });
      try seedRow(alloc, &s.db, .{
          .id = "rf_malformed", .session_id = "sess_a", .role = "tool", .tool_name = "read_file",
          .content = "<content>no path tag here</content>",
          .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:04",
      });

      var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
      defer lg.deinit();
      var turns = try ctx.fetchReadFilePaths(alloc, &s.db, "sess_a", &lg);
      defer {
          for (turns.items) |t| t.deinit(alloc);
          turns.deinit(alloc);
      }

      // Malformed row is dropped with a warning (not failed). 3 valid rows
      // remain (rf1, rf2, rf3 — rf3 is filtered by is_output=0, leaving 2).
      try testing.expectEqual(@as(usize, 2), turns.items.len);
      try testing.expectEqualStrings("/home/user/foo.zig", turns.items[0].path);
      try testing.expectEqualStrings("/home/user/bar.zig", turns.items[1].path);
      try testing.expect(std.mem.indexOf(u8, turns.items[0].raw_content, "foo body") != null);
  }
  ```

- [ ] **Step 2.6** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "compaction_context|parseReadFilePath"` and confirm 6 tests PASS (GREEN: 4 parser + 2 query).

- [ ] **Step 2.7** — Commit: `git add src/ai_workflow/tui/agentic_loop/compaction_context.zig src/ai_workflow/tui/agentic_loop/compaction_context_test.zig src/ai_workflow/tui/agentic_loop/compaction_enrich_test.zig src/ai_workflow/tui/test_runner.zig src/ai_workflow/tui/agentic_loop/mod.zig && git commit -m "feat(compaction): add query helpers for user chat history + read_file paths"` (the mod.zig + test_runner.zig are part of this commit as wiring).

### Task 3 — `compaction_enrich_test.zig`: 4 behavioural tests for `enrichCompactionXml`

**Goal:** Lock in the wire shape of the enriched XML returned by `enrichCompactionXml`.

**File:** `src/ai_workflow/tui/agentic_loop/compaction_enrich_test.zig`

- [ ] **Step 3.1** — Add 4 tests:
  ```zig
  test "enrichCompactionXml with empty user history and empty read files returns the original compacted_xml wrapped in <summary>" {
      const alloc = testing.allocator;
      const result = try ctx.enrichCompactionXml(
          alloc, "GOAL: ship X\nNEXT: test", &.{}, &.{}, "/tmp",
      );
      defer alloc.free(result);

      try testing.expect(std.mem.indexOf(u8, result, "<compaction_context>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<user_history>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<read_files>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "GOAL: ship X") != null);
      // No entries inside the empty-section blocks
      try testing.expect(std.mem.indexOf(u8, result, "<turn ") == null);
      try testing.expect(std.mem.indexOf(u8, result, "<path ") == null);
  }

  test "enrichCompactionXml embeds user history and read files with the right content" {
      const alloc = testing.allocator;
      const user_turns = [_]ctx.UserTurn{
          .{ .content = "fix the bug", .created_at = "2026-01-01 00:00:01" },
          .{ .content = "now also write tests", .created_at = "2026-01-01 00:00:05" },
      };
      const read_files = [_]ctx.ReadFileTurn{
          .{
              .path = "/home/user/foo.zig",
              .raw_content = "<path>/home/user/foo.zig</path>",
              .created_at = "2026-01-01 00:00:02",
          },
      };
      const result = try ctx.enrichCompactionXml(
          alloc, "GOAL: ship X", &user_turns, &read_files, "/home/user",
      );
      defer alloc.free(result);

      try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:01\">fix the bug</turn>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<turn created_at=\"2026-01-01 00:00:05\">now also write tests</turn>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<path abs=\"/home/user/foo.zig\">/home/user/foo.zig</path>") != null);
      try testing.expect(std.mem.indexOf(u8, result, "<summary>") != null);
  }

  test "enrichCompactionXml emits all 50 user turns when the cap is hit" {
      const alloc = testing.allocator;
      var turns: [50]ctx.UserTurn = undefined;
      for (&turns, 0..) |*t, i| {
          t.* = .{
              .content = try std.fmt.allocPrint(alloc, "turn {d}", .{i}),
              .created_at = "2026-01-01 00:00:00",
          };
      }
      defer for (turns) |t| alloc.free(t.content);

      const result = try ctx.enrichCompactionXml(
          alloc, "summary", &turns, &.{}, "/tmp",
      );
      defer alloc.free(result);

      for (turns, 0..) |t, i| {
          const needle = try std.fmt.allocPrint(alloc, ">turn {d}</turn>", .{i});
          defer alloc.free(needle);
          try testing.expect(std.mem.indexOf(u8, result, needle) != null);
      }
  }

  test "enrichCompactionXml deduplicates read_file on the same path" {
      const alloc = testing.allocator;
      const read_files = [_]ctx.ReadFileTurn{
          .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t1" },
          .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t2" },
          .{ .path = "/home/user/foo.zig", .raw_content = "", .created_at = "t3" },  // dup
          .{ .path = "/home/user/baz.zig", .raw_content = "", .created_at = "t4" },
          .{ .path = "/home/user/bar.zig", .raw_content = "", .created_at = "t5" },  // dup
      };
      const result = try ctx.enrichCompactionXml(
          alloc, "summary", &.{}, &read_files, "/home/user",
      );
      defer alloc.free(result);

      // Each unique path appears exactly once
      try testing.expectEqual(@as(usize, 1), countSubstring(result, "/home/user/foo.zig"));
      try testing.expectEqual(@as(usize, 1), countSubstring(result, "/home/user/bar.zig"));
      try testing.expectEqual(@as(usize, 1), countSubstring(result, "/home/user/baz.zig"));
      // No "truncated_by" attribute because count was under the cap
      try testing.expect(std.mem.indexOf(u8, result, "truncated_by") == null);
  }

  // Helper: count non-overlapping occurrences of `needle` in `hay`.
  fn countSubstring(hay: []const u8, needle: []const u8) usize {
      var count: usize = 0;
      var i: usize = 0;
      while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
          count += 1;
          i = pos + needle.len;
      }
      return count;
  }
  ```

- [ ] **Step 3.2** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "enrichCompactionXml"` and confirm 4 tests PASS.

- [ ] **Step 3.3** — Commit: `git add src/ai_workflow/tui/agentic_loop/compaction_enrich_test.zig && git commit -m "test(compaction): enrich helper wire shape + dedup contract"`.

### Task 4 — Wire the helpers into `maybeCompactMessagesNew`

**Goal:** Replace the two TODO comments at lines 130-135 of `workflow_commpact_message.zig` with real code that fetches user history and read paths, builds the enriched XML, and passes it into `compactMessagesInMemory`.

**File:** `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig`

- [ ] **Step 4.1** — Add imports for the new helper module at the top of the file (after the existing `const saveMessage = @import("../llm_history.zig").saveMessage;` line):
  ```zig
  const compaction_context = @import("compaction_context.zig");
  ```

- [ ] **Step 4.2** — Add the new behavioural test to the existing `workflow_commpact_message_test.zig` (the file at `src/ai_workflow/tui/agentic_loop/workflow_commpact_message_test.zig` is the existing test file for `maybeCompactMessagesNew`). The test seeds 2 user rows + 1 read_file row in a fresh DB, calls `maybeCompactMessagesNew` with `mockCompactDeps` that returns a non-null `compacted_xml`, asserts:
  - `callCompactAgent` is called once
  - `compactMessagesInMemory` is called once
  - The `last_compacted_xml` recorded by the mock now contains `<user_history>`, `<read_files>`, and the original `compacted_xml` body
  ```zig
  test "happy path embeds user history and read_file paths into the compaction XML" {
      resetMockState();
      const alloc = testing.allocator;
      const cfg = buildTestConfig(alloc);

      var s = try setupDbWithSession();  // seeds 2 user rows + 1 read_file row
      defer teardownDb(&s);

      var messages = try buildMessages(alloc);
      defer freeMessages(alloc, &messages);
      var lg = Logger.init(alloc, std.testing.io, .{});
      defer lg.deinit();

      mock_state.should_compact_result = true;
      mock_state.next_compact_xml = "GOAL: ship X";

      const result = try maybeCompactMessagesNew(
          mockCompactDeps,
          alloc,
          200_000,
          "test-model",
          true,
          &messages,
          "sk-test",
          "https://test.example",
          "/home/user",
          "sess_embed",
          &s.db,
          std.testing.io,
          &lg,
          &cfg,
      );

      try testing.expect(result);
      try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
      try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<user_history>") != null);
      try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "<read_files>") != null);
      try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "first user message") != null);
      try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "/home/user/foo.zig") != null);
      try testing.expect(std.mem.indexOf(u8, mock_state.last_compacted_xml, "GOAL: ship X") != null);
  }

  fn setupDbWithSession() !struct {
      db: sqlite.SqliteBackend,
      threaded: std.Io.Threaded,
  } {
      var s = try setupDb();
      // Seed: 2 user rows + 1 read_file output row in the same session.
      try seedRow(alloc, &s.db, .{
          .id = "u1", .session_id = "sess_embed", .role = "user", .tool_name = "",
          .content = "first user message", .is_input = 1, .is_output = 0,
          .created_at = "2026-01-01 00:00:01",
      });
      try seedRow(alloc, &s.db, .{
          .id = "rf1", .session_id = "sess_embed", .role = "tool", .tool_name = "read_file",
          .content = "<path>/home/user/foo.zig</path><content>body</content>",
          .is_input = 0, .is_output = 1,
          .created_at = "2026-01-01 00:00:02",
      });
      try seedRow(alloc, &s.db, .{
          .id = "u2", .session_id = "sess_embed", .role = "user", .tool_name = "",
          .content = "second user message", .is_input = 1, .is_output = 0,
          .created_at = "2026-01-01 00:00:03",
      });
      return s;
  }
  ```

- [ ] **Step 4.3** — Run `timeout 180 zig build test --summary all 2>&1 | grep "embeds user history"` and confirm the test FAILS (RED: the TODO comments are no-ops, so `last_compacted_xml` is still the bare `compacted_xml`, no `<user_history>` or `<read_files>` in the output).

- [ ] **Step 4.4** — Apply the surgery. Replace lines 130-135 of `workflow_commpact_message.zig` (the TODO comments block) with the real implementation:
  ```zig
  // Fetch user chat history + read_file paths BEFORE the
  // mark_history_not_for_llmrun step takes them offline. The new INSERT
  // into llm_history (inside compactMessagesInMemory) carries the enriched
  // context forward to the next agent iteration.
  var user_turns = compaction_context.fetchUserChatHistory(allocator, db, session_id) catch |err| blk: {
      logger.warnFmt("[COMPACTION] fetchUserChatHistory failed: {s}", .{@errorName(err)});
      break :blk std.ArrayList(compaction_context.UserTurn).empty;
  };
  defer {
      for (user_turns.items) |t| t.deinit(allocator);
      user_turns.deinit(allocator);
  }
  var read_files = compaction_context.fetchReadFilePaths(allocator, db, session_id, logger) catch |err| blk: {
      logger.warnFmt("[COMPACTION] fetchReadFilePaths failed: {s}", .{@errorName(err)});
      break :blk std.ArrayList(compaction_context.ReadFileTurn).empty;
  };
  defer {
      for (read_files.items) |rf| rf.deinit(allocator);
      read_files.deinit(allocator);
  }

  const enriched_xml = compaction_context.enrichCompactionXml(
      allocator,
      compacted_xml,
      user_turns.items,
      read_files.items,
      cwd,
  ) catch |err| {
      logger.warnFmt("[COMPACTION] enrichCompactionXml failed: {s}", .{@errorName(err)});
      return false;
  };

  _ = try deps.compactMessagesInMemory(
      allocator,
      messages.*,
      enriched_xml,
      session_id,
      model,
      cwd,
      db,
      io,
      logger,
  );
  ```
  Then delete the line `_ = try deps.compactMessagesInMemory(...)` that followed the TODO comments (now replaced by the one above).

- [ ] **Step 4.5** — Run `timeout 180 zig build test --summary all 2>&1 | grep "embeds user history"` and confirm the test now PASSES (GREEN).

- [ ] **Step 4.6** — Run the full test suite: `timeout 180 zig build test --summary all` and confirm no regressions (test count delta: +6 from compaction_context_test + +4 from compaction_enrich_test + +1 from the new wired-up test = +11 net).

- [ ] **Step 4.7** — Run `timeout 180 zig build install:linux:system` to catch any lazy-analysis errors the test target misses.

- [ ] **Step 4.8** — Run `rm -rf zig-out/bin && timeout 360 zig build` for a fresh full rebuild.

- [ ] **Step 4.9** — Commit: `git add src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig src/ai_workflow/tui/agentic_loop/workflow_commpact_message_test.zig && git commit -m "feat(compaction): embed user history + read_file paths into the compacted XML"`.

### Task 5 — Cross-platform compile verification

**Goal:** Verify the new helpers compile cleanly on Linux, Windows, and macOS targets.

- [ ] **Step 5.1** — Cross-compile via the standalone `zig build-obj` technique (per project memory `zig-cross-platform.md`):
  ```bash
  # Linux
  zig build-obj -fno-emit-bin -target x86_64-linux-gnu -lc \
    --dep nalarcore \
    -Mroot=src/ai_workflow/tui/agentic_loop/compaction_context.zig \
    -Mnalarcore=src/root.zig

  # Windows
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore \
    -Mroot=src/ai_workflow/tui/agentic_loop/compaction_context.zig \
    -Mnalarcore=src/root.zig

  # macOS
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep nalarcore \
    -Mroot=src/ai_workflow/tui/agentic_loop/compaction_context.zig \
    -Mnalarcore=src/root.zig
  ```
  All three must exit 0 — no actual binary is produced (`-fno-emit-bin`), just type-check.

- [ ] **Step 5.2** — Linux verification (the available platform): `timeout 180 zig build test --summary all` reports ~1927/~1933 tests passed (6 skipped, no failures expected — the +11 new tests from this plan bring the total up).
  - `timeout 180 zig build install:linux:system` builds `zig-out/bin/nalarcore-linux-x86_64` successfully (cp-to-`/usr/local/bin/nalar` fails harmlessly with permission — pre-existing).
  - `rm -rf zig-out/bin && timeout 360 zig build` succeeds fresh.

- [ ] **Step 5.3** — Commit (if any changes were needed for cross-compile): `git add -u && git commit -m "chore(compaction): cross-platform compile verification"`. If no changes, skip.

---

## End-to-end smoke test (verification, run by hand)

**NOT a task** — this is the final manual check. Skip if the test suite is green (Task 4's wired-up test already exercises the full path: fetchUserChatHistory + fetchReadFilePaths + enrichCompactionXml + compactMessagesInMemory).

**Implementation outcome (target 2026-07-30):** Task 4's behavioural test exercises the integration end-to-end. The smoke test below is optional double-check.

```bash
# 1. Build the binary on port 8080 (NEVER 8081)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build install:linux:system

# 2. Start isolated server
rm -rf /tmp/nalar-smoke-compaction && mkdir -p /tmp/nalar-smoke-compaction
env -i HOME=/tmp/nalar-smoke-compaction PATH=$PATH \
  nohup ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
  >/tmp/nalar-smoke-compaction.log 2>&1 &
disown
sleep 4

# 3. Create a session, send a few user messages, watch read_file calls land
WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

SESSION=$(curl -sS -X POST http://127.0.0.1:8080/api/llm/session \
  -H 'content-type: application/json' \
  -d "{\"workspace_id\":\"$WS\",\"message\":\"read the file /tmp/foo.zig\",\"cwd\":\"/tmp\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# 4. Wait for the workflow to grow enough to trigger compaction
# (either force-compact via the API or wait for the threshold).
# Force-compact via the endpoint:
curl -sS -X POST "http://127.0.0.1:8080/api/llm/session/$SESSION/compact" \
  -H 'content-type: application/json' -d '{}' | jq .

# 5. Inspect the latest compacted summary row in llm_history
sqlite3 /tmp/nalar-smoke-compaction/.config/nalar/agent.db \
  "SELECT response_content FROM llm_history WHERE session_id = '$SESSION' AND role = 'user' ORDER BY created_at DESC LIMIT 1" \
  | grep -E '<user_history>|<read_files>|<compaction_context>' \
  && echo "OK: enriched envelope landed in llm_history"

# 6. Verify the user history is embedded
sqlite3 /tmp/nalar-smoke-compaction/.config/nalar/agent.db \
  "SELECT response_content FROM llm_history WHERE session_id = '$SESSION' AND role = 'user' ORDER BY created_at DESC LIMIT 1" \
  | grep -E 'read the file /tmp/foo.zig' \
  && echo "OK: original user message embedded"

# 7. Verify the read_file path is embedded (post-fix)
sqlite3 /tmp/nalar-smoke-compaction/.config/nalar/agent.db \
  "SELECT response_content FROM llm_history WHERE session_id = '$SESSION' AND role = 'user' ORDER BY created_at DESC LIMIT 1" \
  | grep -E '/tmp/foo.zig' \
  && echo "OK: read_file path embedded"

# 8. Cleanup
PID=$(pgrep -f "nalarcore-linux-x86_64 --port 8080")
[ -n "$PID" ] && kill "$PID"
```

**Success criteria:** The compacted summary row in `llm_history` contains `<compaction_context>`, `<user_history>`, `<read_files>`, and the original `compacted_xml` body. The original user message and the read_file path are both present in the embed.

---

## Reference

- **Source site:** `src/ai_workflow/tui/agentic_loop/workflow_commpact_message.zig` — the compaction entry point (lines 130-135 = the TODO comments this plan replaces).
- **Source site:** `src/ai_workflow/tui/agentic_loop/compaction.zig` — the `callCompactAgent` that produces the bare `compacted_xml`. The new `enrichCompactionXml` is a sibling wrapper that does NOT modify `compaction.zig` — clean separation.
- **Source site:** `src/ai_workflow/tui/agentic_loop/markHistoryNotForLLMRun.zig` — the function that takes the session offline. New queries MUST run before this (which is the natural ordering in `maybeCompactMessagesNew`).
- **Source site:** `src/ai_workflow/tui/llm_history.zig:284-310` — the `SessionMessage` struct + `parseRowBool` helper. Confirms the DB schema (`role TEXT`, `tool_name TEXT`, `is_output INTEGER`, `is_input INTEGER`, `response_content TEXT`).
- **Source site:** `src/modules/agent/tools/read_file.zig:90-104` — the `toXMLSuccess` that produces the `<path>...</path><content>...</content>` envelope. The new `parseReadFilePath` is the inverse.
- **Project memory:** `nalar-backend-architecture.md` §"HTTP handler thin-wrapper pattern" — for the existing `compactMessagesInMemory` and `buildCompactionEnvelope` patterns this plan mirrors.
- **Project memory:** `zig-build-and-test.md` §"`zig build test` catches lazy-analysis errors `zig build test` misses" — the four-step verification (test + install:linux + fresh build + cross-compile) is mandatory.
- **Project memory:** `static-contract-test-when-to-prefer-behavioural.md` — all new tests in this plan are behavioural (real DB calls, real parser calls), NOT grep. Per project rule.
- **Branch:** `worktree/better-compaction-context`
- **Plan file:** `docs/superpowers/plans/2026-07-30-better-compaction-context.md`
