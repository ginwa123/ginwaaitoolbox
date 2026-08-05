# search tool better error output (2026-08-06)

## Symptom (user report, task `task_1785849939020`)

User: *"better tool output, search. if success false, show a input parameter
from llm, so human know why its cannot found"*

Screenshot: three `search` tool messages in chatview, each labelled
`search "unknown"   unknown pattern not found`. The "unknown" appears twice
(pattern + path) and the warning text is the literal `pattern not found`.

## Root cause (3 compounding bugs)

1. **`tools_exec_search.zig` bypassed the wrapper for no-match** — when
   `search_result.matches.items.len == 0`, it used `search_result.content`
   directly. Content was just `<warning>pattern not found</warning>` — no
   `<search pattern="…" path="…">` wrapper. Frontend regex `pattern="([^"]+)"`
   returned `null`, header fell back to `"unknown"`.

2. **`search_result_to_string_{grouped,flat}` dropped the body on no-match** —
   closing the `<search>` tag immediately after the opening, no body. The
   flat variant didn't even open the tag.

3. **`executeSearch` no-match warning was opaque** — literal
   `<warning>pattern not found</warning>` with no pattern/path info.

## What landed (3 files + 1 new test file)

- `src/modules/agent/tools/search.zig` — 3 surgical edits: warning body
  includes pattern + path, both formatters include the body inside the
  `<search>` tag.
- `src/ai_workflow/tui/agentic_loop/tools_exec_search.zig` — removed the
  no-match bypass branch (formatters handle the empty case now).
- `src/modules/agent/tools/search_test.zig` — 3 new behavioural tests.
- `src/apps/desktop/src/components/tool_outputs/__tests__/Search.spec.ts`
  (new) — 7 behavioural tests for Search.vue rendering.

## Wire format (before → after)

```xml
<!-- BEFORE (no-match): wrapper missing, operator sees "unknown" everywhere -->
<warning>pattern not found</warning>

<!-- AFTER (no-match): wrapper + body with actual args -->
<search pattern="X" path="Y">
<warning>no matches for pattern "X" in path "Y"</warning>
</search>
```

## Behaviour

| Scenario | Before (operator sees) | After |
|---|---|---|
| No matches | `search "unknown"   unknown pattern not found` | `search "foo" in /x  no matches for pattern "foo" in path "/x"` (orange) |
| Match found | `search "foo" in /x  3 files, 12 matches` | unchanged |
| Stale DB row | `search "unknown"   unknown pattern not found` | unchanged (back-compat fallback) |
| Regex parse error | `error: regex parse error…` | unchanged (existing error path) |

## Lessons (record for future agents)

- **Wire formats must always carry the input parameters** — even on
  error/empty cases. The frontend's header relies on the wrapper to
  render "what was searched"; without it the operator can't tell a
  typo from a genuine no-match.
- **Never bypass the formatter for "simple" cases** — the no-match
  bypass in `tools_exec_search.zig` looked innocent ("we already have
  the content, just wrap it") but it silently dropped the wrapper.
  The formatters know the contract; trust them.
- **Test fixtures MUST match production data shape** — the existing
  `search_result_to_string_*` tests used a pre-fix-shaped
  `SearchResult{ .content = "<warning>pattern not found</warning>" }`
  fixture that didn't exercise the wrapper-bypass bug. The new tests
  use the post-fix content shape and the actual `executeSearch` flow.

## Branch / commit

- Branch: `worktree/search-better-error`
- Plan: `docs/superpowers/plans/2026-08-06-search-better-error.md`
- 3 modified + 1 new test file