# `search_history` v2 — improvements

**Date:** 2026-08-06
**Owner:** orchestrator + implementer
**Scope:** `src/modules/agent/tools/search_history.zig` + `src/ai_workflow/tui/llm_history.zig` + the tool's description string (rendered by `prompts.zig::appendToolListing`).

## Goal

Add 8 new capabilities to `search_history` that every daily user of the tool will hit during routine work:

1. **`is_feed_to_llm` filter** — pick live, compacted, or both.
2. **`tool_name` filter** — e.g. "all `bash` invocations that ran `cargo test`".
3. **`parent_session_id` filter** — sub-agent debugging.
4. **Full content in mode `text`** — accept `message_ids` in mode `text` so the LLM doesn't have to do a second hop.
5. **Longer snippet** — 32 tokens instead of 10.
6. **`agent` filter** — when multiple agents share a session.
7. **Relative `since`/`until`** — `1h`, `30m`, `2d`, `1w`.
8. **Thread context in mode `session`** — fetch the assistant message + user message that triggered the requested tool row.

## Backward compatibility

- Every new field is optional with a default. Existing callers see identical behavior.
- The `include_all` flag on `CompactedMessagesOptions` is renamed to `feed_filter` (enum: `all | live_only | compacted_only`). The old `include_all` is kept as a backward-compat alias for the test setup that uses `.{ .include_all = true }` (the only existing caller — `search_history.zig`).

## API additions

### `SearchHistoryInput` (new fields)

| Field | Type | Default | Mode | Meaning |
|---|---|---|---|---|
| `live_only` | `bool` | `false` | both | `true` → restrict to `is_feed_to_llm = 1` |
| `compacted_only` | `bool` | `false` | both | `true` → restrict to `is_feed_to_llm = 0` |
| `tool_name` | `[]const u8` | `""` | both | Exact match on `llm_history.tool_name` |
| `parent_session_id` | `[]const u8` | `""` | both | Exact match on `llm_history.parent_session_id` |
| `agent` | `[]const u8` | `""` | both | Exact match on `llm_history.agent` |
| `since_relative` | `[]const u8` | `""` | both | Same as `since` but accepts `1h` / `30m` / `2d` / `1w` (mutually exclusive with `since`) |
| `until_relative` | `[]const u8` | `""` | both | Same as `until` but accepts `1h` / `30m` / `2d` / `1w` (mutually exclusive with `until`) |
| `relative_window` | `[]const u8` | `""` | both | Sugar: `since = now - window` and `until = now`. e.g. `relative_window = "1h"` returns the last hour. Mutually exclusive with `since`/`until`/`since_relative`/`until_relative`. |

`mode = "text"` additionally accepts:
- `message_ids` — optional CSV (max 50). When set, the response includes full `<content>` for those ids (same shape as mode `session`).

### `SearchOptions` (new fields — `searchMessagesFts`)

Mirror `SearchHistoryInput` for the low-level FTS query.

### `CompactedMessagesOptions` (new fields — `getCompactedMessages`)

Mirror `SearchHistoryInput`. The `include_all` flag is kept as a deprecated alias for `feed_filter`.

### `CompactedMessagesOptions.feed_filter` (new enum)

```zig
pub const FeedFilter = enum {
    all,           // default — both live and compacted
    live_only,     // is_feed_to_llm = 1
    compacted_only, // is_feed_to_llm = 0
};
```

To avoid breaking the existing `include_all` callers (the test setup uses `.{ .include_all = true }`), we keep `include_all: bool` as a read-only alias: when the caller sets `include_all = true`, `feed_filter` is set to `all`; when `include_all = false`, `feed_filter = compacted_only`. The new `feed_filter` takes precedence when both are set.

## Relative duration parsing

New helper `parseRelativeDuration(now: i64, raw: []const u8) ![]const u8` that:
- Accepts `1h`, `30m`, `2d`, `1w` (and any `N<unit>` where unit is `s`/`m`/`h`/`d`/`w`).
- Returns the ISO timestamp string `now - seconds(raw)`.
- Fails on invalid input (TODO: error XML or panic).

Return format: `YYYY-MM-DD HH:MM:SS` (matches `created_iso` storage format).

The helper is exposed via `llm_history` so the test can unit-test it directly.

## Thread context

When `mode = "session"` is called with `message_ids = "X"` and `X` is a `tool` row, the response includes:

```xml
<thread_context>
  <user_message id="h_user_42" role="user" created_at="...">
    <content>Fix the login bug</content>
  </user_message>
  <assistant_message id="h_assist_99" role="assistant" tool_call_id="X" created_at="...">
    <content>Running grep across the codebase</content>
  </assistant_message>
</thread_context>
```

Search semantics:
- `user_message` = the most recent `role = 'user'` row in the session with `created_at < h.tool_call_id_message.created_at`.
- `assistant_message` = the row with `tool_call_id = X` (the assistant that produced the tool call).

If either lookup fails (e.g. the tool row was the first message), the corresponding `<user_message>` or `<assistant_message>` block is omitted. No error.

For non-`tool` rows, the thread context is omitted (no tool_call_id to anchor against).

## Tool description update

The `search_history_tool.function.description` is updated to document the new fields. The `appendToolListing` helper in `prompts.zig` renders the description verbatim, so the LLM sees the new fields automatically.

## Migration / schema

No migration required. Every new filter is a `WHERE` clause on existing columns. The FTS index (`messages_fts`) is unchanged.

## Indexes

Add `CREATE INDEX IF NOT EXISTS idx_llm_history_tool_name ON llm_history(tool_name)` in a migration file (Migration 070). The `parent_session_id` and `agent` columns are already indexed (or their tables are small enough that table scans are fine — verify in the implementation).

## Test plan

For each chunk, write tests first (RED), then implement (GREEN), then refactor.

### Chunk 1 — `is_feed_to_llm` filter
- mode `text` + `live_only: true` → only live rows in the result.
- mode `text` + `compacted_only: true` → only compacted rows.
- mode `session` + `live_only: true` → same filter.
- mode `session` + `compacted_only: true` → same filter.
- `live_only` + `compacted_only` both true → error XML.

### Chunk 2 — `tool_name` filter
- mode `text` + `tool_name: "bash"` → only bash tool rows.
- mode `session` + `tool_name: "bash"` → same.

### Chunk 3 — `parent_session_id` filter
- mode `text` + `parent_session_id: "s_parent"` → only rows belonging to that parent session.

### Chunk 4 — Full content in mode `text`
- mode `text` + `message_ids: "h1,h2"` → response includes `<content truncated="0">...</content>` for each requested id.

### Chunk 5 — Longer snippet
- Match the snippet length is 32 tokens (sanity check: render a row with 50 tokens and check the snippet captures ~32 of them).

### Chunk 6 — `agent` filter
- mode `text` + `agent: "Agent"` → only rows where `agent = 'Agent'`.

### Chunk 7 — Relative `since` / `until`
- `relative_window: "1h"` → returns rows from the last hour only.
- `since_relative: "30m"` → `since` field is set to `now - 30m` automatically.
- Invalid: `1x` → error XML.

### Chunk 8 — Thread context
- mode `session` + `message_ids: "tool_h"` (with matching user + assistant rows) → response includes `<thread_context>` with both anchors.
- mode `session` + `message_ids: "user_h"` → no thread context (no tool_call_id).
- mode `session` + `message_ids: "orphan_tool_h"` (no preceding user) → only `<assistant_message>` block.

### Chunk 9 — Tool description update
- `search_history_tool.function.description` includes the new fields.
- `prompts.zig::appendToolListing` renders the new description (verified by a unit test that asserts the description contains the new field names).

### Chunk 10 — Stats/Aggregation (NEW — bonus)

This is a meta-statistic request: how many messages with `is_feed_to_llm=0` vs `is_feed_to_llm=1` does the session have? Wait, that's just a `mode=text` with `query='*'` query. Already covered.

Skip.

## Out of scope

- Multi-session-id at once (already supported via `mode = text` without `session_id`).
- Token count / cost filter (data not always populated).
- `model` filter (out of scope for this round; cheap follow-up).
- ISO 8601 date format (cheaper follow-up — relative durations cover the common case).
- Ordering mode `text` by `created_at` (cheaper follow-up).
- Response hint "more pages available" (cheaper follow-up — `total_count` is already there).

## Verification

- `zig build test --summary all` → 2294+ pass / 6 skip / 0 new failures / 2 (pre-existing) leaks.
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` and `-target aarch64-macos` → both clean.
- `zig build install:linux:system` → compiles.
- `rm -rf zig-out/bin && zig build` → all 4 binaries (`nalar`, `nalarcore-linux-x86_64`, `nalar-desktop`, `nalarcli`).
- Live smoke on port 8080: `POST /api/llm/session` with `tools: ["search_history"]` and a hand-rolled prompt that calls the tool with each new field. Verify the assistant can see the new fields in the tool description.

## Files

| File | Change |
|---|---|
| `src/modules/agent/tools/search_history.zig` | New fields + thread context + tool description rewrite |
| `src/modules/agent/tools/search_history_test.zig` | +25 tests (3-4 per chunk) |
| `src/ai_workflow/tui/llm_history.zig` | New `SearchOptions` fields + `feed_filter` enum + `parseRelativeDuration` helper |
| `src/ai_workflow/tui/llm_history_compacted_messages_test.zig` | +5 tests for `feed_filter` |
| `src/ai_workflow/tui/llm_history_search_messages_fts_test.zig` | +5 tests for new FTS filters |
| `src/migrations/migration.zig` | Migration 070 (tool_name index) |
| `src/migrations/migration_070_test.zig` | +1 test for the new index |
| `AGENTS.md` | Changelog entry |
| `docs/SPEC.md` | Update §3.14 (search_history) |

## Commits

One commit per chunk (10 commits total). Each commit must include the test changes + implementation changes. No big-bang commit.
