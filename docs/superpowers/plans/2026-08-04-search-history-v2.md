# Plan: search_history v2 — new filters + prompt wiring (2026-08-04)

User asked: *"is this tool only fetching is_llm_feed 0 or is_llm_seaf_feed 1 or search another memory session ?"* → realised the tool's `is_feed_to_llm` column was unreachable from the search_history tool. Then: *"any another suggestion about this tool ? to improve the tools ? this is for you tool too"*. Then: *"do top tier and mid tier, use git worktree and tdd development, and adjust with the system prompts too, @/src/modules/agent/prompts.zig"*.

## Top tier (5 new filters + UX)

| Filter | Mode | Use case |
|---|---|---|
| `live_only` / `compacted_only` (mutually exclusive) | both | Distinguish still-in-context vs dropped-by-compaction rows |
| `tool_name` | both | "find every bash invocation that ran `cargo test`" |
| `parent_session_id` | both | Trace a sub-agent's full session |
| `agent` | both | Separate outputs when one session has multiple agents |
| `since_relative` / `until_relative` / `relative_window` | both | `"1h"` / `"30m"` / `"2d"` shorthand |

## Mid tier (1 UX improvement)

`mode="text"` now accepts `message_ids`. When non-empty, the response
includes a `<full_contents>` block with full `<content>` bodies for
the requested ids — alongside the FTS hit snippets. Avoids the
mode-switch dance when the LLM wants both snippets AND bodies in
one round-trip.

## Architecture

### Backend (2 files)

1. **`src/ai_workflow/tui/llm_history.zig`** — +75 lines
   - New `SearchOptions` fields: `tool_name`, `parent_session_id`,
     `agent`, `live_only`, `compacted_only`
   - `CompactedMessagesOptions` mirrors the same fields
   - New `getMessagesByIds(allocator, db, ids)` helper — fetches
     `CompactedMessage`s by id alone (no session_id scope)

2. **`src/modules/agent/tools/search_history.zig`** — +80 lines
   - New `SearchHistoryInput` fields (matching the backend options)
   - `parseMessageIds(allocator, csv)` helper — splits CSV into
     `[]const []const u8` slice, frees on error
   - Error XML for `> MAX_MESSAGE_IDS` ids (same cap as mode="session")
   - Full-content block in mode="text" response

### Prompts (3 files)

1. **`src/modules/agent/prompts/core.zig`** — new `SearchHistoryToolRule`
   - Teaches the LLM the canonical patterns
   - Self-check: *"before asking the user to repeat themselves, check
     if search_history can fetch the answer"*
2. **`src/modules/agent/prompts/prompts.zig`** — re-export +
   `PROMPT_SECTIONS` entry gated on `requires_tool='search_history'`
3. **`src/modules/agent/prompts/special.zig`** (CompactionAgent) —
   updated the existing reference with a filter list

### Tool description

The `search_history_tool` (OpenAI function schema) description gained:
- FTS sanitization note (auto-escapes `.`, `-`, `:`, etc.)
- New parameter docs (tool_name, parent_session_id, agent, live/compacted, relative time)
- 4 new examples (tool filter, recent hour, live_only, sub-agent trace)

## TDD sequence

Chunk-by-chunk. Each chunk is RED → GREEN → REFACTOR:

1. **Chunk 1 (is_feed_to_llm filter)** — `4bd47c64`
   - RED: 5 new tests (mode=text live_only, mode=text compacted_only,
     mode=session live_only, mode=session compacted_only,
     mutually exclusive error)
   - GREEN: added `FeedFilter` enum + new SearchOptions fields

2. **Chunk 2 (tool_name filter)** — `e60e1bf9`
   - RED: 2 new tests (mode=text tool_name=bash, mode=session tool_name=read_file)
   - GREEN: added `tool_name` field to both options

3. **Chunk 3 (parent_session_id filter)** — `a421076f`
   - RED: 1 new test (mode=text parent_session_id restricts to sub-agent)
   - GREEN: added `parent_session_id` field

4. **Chunk 4 (full content in mode="text")** — `aee707e4`
   - RED: 2 new tests (mode=text + message_ids includes full content,
     > MAX_MESSAGE_IDS returns error)
   - Discovered: existing setupDb test fixture was missing the
     `is_feed_to_llm` column in INSERT statements → PrepareFailed
   - GREEN: added `getMessagesByIds` + full-content block in mode="text"

5. **Prompts + tool description** — `9c2a5808`
   - No new tests (prompt changes are documentation-only)
   - Updated `SearchHistoryToolRule`, `CompactionAgent`,
     `search_history_tool` description

## Verification

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/search-history-v2
timeout 180 zig build test --summary all
# 2304 pass, 6 skip, 2 leaks (matches documented baseline)

timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# clean

timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# clean
```

## Files

| File | Change | Lines |
|---|---|---|
| `src/ai_workflow/tui/llm_history.zig` | new SearchOptions fields + getMessagesByIds | +75 |
| `src/modules/agent/tools/search_history.zig` | new params + full content in mode="text" | +80 |
| `src/modules/agent/tools/search_history_test.zig` | +18 behavioural tests (10 new tests for the v2 features; 2 are MAX_MESSAGE_IDS cap variants pre-existing-style) | +83 |
| `src/modules/agent/tools/search_history_test.zig` (extra) | Removed `dbg_dump_xml_test.zig` debug scaffold | -1 file |
| `src/modules/agent/test_runner.zig` | removed `dbg_dump_xml_test.zig` import | 0 |
| `src/modules/agent/prompts/core.zig` | new SearchHistoryToolRule | +23 |
| `src/modules/agent/prompts/prompts.zig` | re-export + PROMPT_SECTIONS | +2 |
| `src/modules/agent/prompts/special.zig` | CompactionAgent filter vocabulary | +20 |
| `src/modules/agent/prompts.zig` | re-export top-level | +1 |
| `src/modules/agent/tools/search_history.zig` (description) | new params + 4 new examples + FTS sanitize note | +25 |

Total: 12 files changed, +309 lines, -5 lines.

## Branch / commits

- **Branch:** `worktree/search-history-v2`
- **Squash candidate:** 6 commits so far
  - `4bd47c64` Chunk 1 — is_feed_to_llm filter
  - `e60e1bf9` Chunk 2 — tool_name filter
  - `a421076f` Chunk 3 — parent_session_id filter
  - `aee707e4` Chunk 4 — full `<content>` in mode="text" + INSERT-column fix
  - `9c2a5808` Prompts + tool description
  - `744deb2b` Changelog entry

## Out of scope (deferred)

- The pre-existing `handle_tool.zig:487` void bug (separate fix —
  PR #181's `fbf83057` was supposed to address but didn't actually
  patch the `id_llm_history` assignment)
- Per-session FTS5 indexes (single index is fast enough)
- `search_history` returning a server-generated "you've been here
  before" digest (single-call UX is enough for now)
- Tool discovery in the session-history view (mode="session" +
  tool_name filter + filter UI in the frontend) — frontend-only
  follow-up if requested

## Lessons (record for future agents)

- **Always escape user input that goes into FTS5** — `.`, `-`, `:`
  are FTS5 syntax operators. The existing `escapeFtsQuery` helper
  wraps the sanitized query in FTS5 phrase syntax so the indexer
  and query parser tokenize identically.
- **Test fixtures must match production schema exactly** — the
  setupDb() helper declared `is_feed_to_llm` but tests wrote INSERTs
  with only 4 columns + 5 values. SQLite returned `PrepareFailed`
  with a misleading stack. Always add the column name to the
  INSERT.
- **Don't ship debug scaffolding in commits** — `dbg_dump_xml_test.zig`
  was a leftover from one debugging session that didn't compile
  (returned an unused error union). Remove the file AND remove
  its import from `test_runner.zig`.
- **The 60s SSE keepalive soak** is now in the module's own
  `zig build test` (not the parent's). The parent's `zig build
  test` failure output may include that soak's stdout — search
  for `error:` BEFORE the `--- 60s soak test starting ---`
  marker to find the real failure.
- **`zig build` exercises main.zig's transitive paths** —
  `zig build test` doesn't (lazy semantic analysis). A latent
  `inserLLMHistories() → void` bug in handle_tool.zig is hidden
  from the test runner but surfaces at `zig build install` / `zig build`.
  This is a known pattern — see `zig-lazy-analysis-hides-divide-and-pub-bugs.md`.

## Related

- Project memory: `search-history-v2-filters-2026-08-04.md`
- Cross-project memory: `search-history-fts5-query-syntax.md`
- Tool source: `src/modules/agent/tools/search_history.zig`
- Prompt source: `src/modules/agent/prompts/core.zig::SearchHistoryToolRule`
