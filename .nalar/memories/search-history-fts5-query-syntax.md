# search_history FTS5 query syntax — `.`, `-`, `:` are syntax errors

## Symptom

The `search_history` tool (mode="text") returns `FTS search failed:
QueryFailed` (the bare enum name) for plain-text queries containing
FTS5-special characters. User reported in task_1785658329168 that
queries like `handle_tool.zig`, `AGENTS.md`, `SPEC.md`, `2026-08-06`,
and `agentic_loop/handle_tool.zig:18` all failed with the same
useless message — no hint about why.

## Root cause

The `messages_fts` table uses FTS5 with the `porter unicode61
remove_diacritics 2` tokenizer. FTS5's QUERY PARSER interprets certain
characters as **query syntax operators** BEFORE applying the tokenizer.
So plain user input that happens to contain those operators fails
with `SQLITE_ERROR`:

- `.` — FTS5 sees the `.` as part of a single term, but **also**
  treats the query as malformed when adjacent to other FTS5 syntax.
  Diagnostic from raw FTS5: **`fts5: syntax error near "."`**.
- `-` — FTS5 binary NOT. `2026-08-06` parses as `2026 - 08 - 06` —
  binary NOT with no right operand. Diagnostic: **`no such column:
  08`** (FTS5 treats `08` after `-` as a column-name filter).
- `:` — FTS5 column-name filter. `agentic_loop/handle_tool.zig:18`
  tries to filter by column `agentic_loop/handle_tool.zig`, which
  doesn't exist.
- `+`, `*`, `^`, `(`, `)`, `"` — other FTS5 operators.

`sqlite3_errmsg(db)` reveals the actual root cause (e.g. `fts5:
syntax error near "."`), but the old code dropped this on the floor
and only returned `Error.QueryFailed` to callers.

## Fix (two parts)

### Part 1: Capture the SQLite error message

`SqliteBackend.Rows` previously only printed the rc number to
`std.debug`. New `getLastErrorMessage()` method:

- Adds `db: ?*c.sqlite3` field to `Rows` (needed because the stmt
  pointer alone can't reach the db handle — added in
  `executeQuery`).
- Adds `last_error_msg: ?[]u8` field, populated by `captureError()`
  before returning `Error.QueryFailed`. Freed in `deinit()`.
- Public getter: `rows.getLastErrorMessage() ?[]const u8`.

Verified by `sqlite_test_rows_capture_error.zig` (3 tests).

### Part 2: Sanitize user input before binding

`llm_history.escapeFtsQuery` (new, ~30 lines + 6 inline unit tests):

1. Strips FTS5 operators by replacing with a single space.
2. Wraps the result in FTS5 phrase syntax (`"..."`).

The phrase `"handle_tool.zig"` is tokenized by the FTS5 query parser
using the SAME unicode61 tokenizer as the indexer, so `handle_tool.zig`
splits into `["handle_tool", "zig"]` and the phrase query looks for
those two tokens to appear ADJACENTLY in the document — which they
do, because the indexer split the original text the same way.

Used in `searchMessagesFts` before binding to SQL.

Verified by `llm_history_search_fts_query_safety_test.zig` (5
regression tests) and 6 inline unit tests on `escapeFtsQuery` itself.

## Test counts

| File | Tests | Purpose |
|---|---|---|
| `sqlite_test_rows_capture_error.zig` | 3 | `Rows.getLastErrorMessage()` captures SQL error |
| `llm_history_search_fts_query_safety_test.zig` | 5 | User-reported queries no longer fail |
| Inline in `llm_history.zig` | 6 | `escapeFtsQuery` transformation correctness |

Total 14 new tests, all green.

## Pitfalls

- **Don't add a default value for a `*?[]u8` parameter** in Zig 0.16
  — the `null` default fails to parse (column 27 of the parameter
  list). Either make it required (and update all callers) or wrap in
  `?*?[]u8` (optional pointer to optional slice).
- **Don't use `for (out) |*c|` to mutate a slice** — Zig 0.16's
  variable analyzer doesn't see the mutation through the pointer
  indirection. Use a `while (i < out.len) : (i += 1) out[i] = ...`
  loop instead.
- **The user wanted SQL errors in the formatted envelope** but
  plumbing `Rows.getLastErrorMessage()` through `searchMessagesFts`
  (which iterates Rows internally) requires either a signature
  change with an out-param or a different plumbing mechanism.
  Deferred to a follow-up — the infrastructure is in place.
- **Don't kill the user's 8081 server** (per AGENTS.md rule) when
  smoke-testing. Use port 8080 for new instances.
EOF
ls /home/ginwa/ginwaaitoolbox/.worktrees/tool-error-better-message/.nalar/memories/