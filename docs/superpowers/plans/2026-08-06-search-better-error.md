# Search tool — better error output (show actual pattern + path on no-match)

## Symptom (user report, task `task_1785849939020`, 2026-08-06)

User: *"better tool output, search. if success false, show a input parameter from llm, so human know why its cannot found"*

Screenshot showed three chatview search tool messages, each labelled:

```
search "unknown"   unknown pattern not found
```

The "unknown" appears twice (pattern + path) and the warning text is the literal
`pattern not found`. The operator can't tell what the LLM was searching for
— a typo? a wrong path? a wrong regex?

The user also said: *"default keep minimalism, or to show paramaeter user
have to click that"*. The full tool input (parameters) is already shown in
the existing "Raw Input" panel on click. The default header should just
show the actual pattern + path — nothing extra.

## Root cause

Two compounding bugs in `src/modules/agent/tools/search.zig` + the
agentic-loop wrapper:

### Bug 1: `tools_exec_search.zig` bypassed the wrapper for no-match

`src/ai_workflow/tui/agentic_loop/tools_exec_search.zig:54-58` (pre-fix):

```zig
if (search_result.matches.items.len == 0) {
    const inner = try ctx.allocator.dupe(u8, search_result.content);
    search_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

This uses `search_result.content` directly. The content is just
`<warning>pattern not found</warning>` — no `<search pattern="…" path="…">`
wrapper. The frontend's `Search.vue` parses pattern/path from the wrapper
via `content.match(/pattern="([^"]+)"/)`. Without the wrapper, both
extractors return `null` and the header falls back to `"unknown"` for
each.

### Bug 2: `search_result_to_string_{grouped,flat}` dropped the body on no-match

`src/modules/agent/tools/search.zig:533-536` (pre-fix grouped):

```zig
if (result.matches.items.len == 0) {
    try output.appendSlice(allocator, "</search>\n");
    return try output.toOwnedSlice(allocator);
}
```

Closing the tag immediately after the opening — no body content. The
flat variant (line 643) had the same shape but didn't even open the
tag, so the `</search>` came first.

### Bug 3: `executeSearch` no-match warning text was opaque

`src/modules/agent/tools/search.zig:510` (pre-fix):

```zig
try output.appendSlice(allocator, "<warning>pattern not found</warning>");
```

The literal text "pattern not found" tells the operator nothing about
what was searched. The pattern + path the LLM passed were available
in the function scope but were never included.

### Frontend `parseSearch` parser bug (separate, deferred)

`src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts:338`
calls `extractTag(content, 'pattern="([^"]+)"')` — but `extractTag`
expects a literal `<tag>` form, not a regex. So `parsed.pattern` and
`parsed.path` are always `null` even when the wire envelope has the
attributes. This doesn't affect the user-visible bug (because
`Search.vue` uses its own regex `/pattern="([^"]+)"/` which DOES
work), but downstream consumers reading `parseSearch()` see broken
data. Out of scope for this fix; follow-up.

## What landed

### Backend (3 files)

**`src/modules/agent/tools/search.zig`** — 3 surgical edits:

1. `executeSearch` no-match warning now includes the actual pattern +
   path the LLM passed (line 504-524):
   ```xml
   <warning>no matches for pattern "X" in path "Y"</warning>
   ```
   Stderr path (regex parse error, permission denied, etc.) is unchanged
   — surfaces the raw stderr verbatim.

2. `search_result_to_string_grouped` no-match branch now includes the
   warning body inside the `<search>` tag (line 533-543):
   ```xml
   <search pattern="X" path="Y">
   <warning>no matches for pattern "X" in path "Y"</warning>
   </search>
   ```

3. `search_result_to_string_flat` no-match branch — same fix (line
   643-651).

**`src/ai_workflow/tui/agentic_loop/tools_exec_search.zig`** — removed
the no-match bypass branch. The formatters now handle the empty case
correctly (warning body inside the wrapper), so the special case is
dead code.

### Tests (1 new file + 3 new cases in existing test)

**`src/modules/agent/tools/search_test.zig`** — 3 new tests:

- `search: executeSearch no-match warning includes the actual pattern
  and path` — runs a real search with a pattern that doesn't appear in
  any file, asserts `result.content` contains the literal pattern +
  path + the `<warning>` wrapper.
- `search: search_result_to_string_grouped no-match wraps warning in
  <search pattern="..." path="...">` — asserts the grouped formatter
  emits both the wrapper attributes AND the warning body, both before
  `</search>`.
- `search: search_result_to_string_flat no-match wraps warning in
  <search pattern="..." path="...">` — same for the flat formatter.

**`src/apps/desktop/src/components/tool_outputs/__tests__/Search.spec.ts`**
(new) — 7 behavioural tests:

- `shows the actual pattern from the envelope, not "unknown" (regression:
  bug 2026-08-06)` — locks in the fix.
- `shows the actual path from the envelope, not "unknown"`.
- `renders both the pattern and the path together in the header`.
- `renders the warning text from <warning>...</warning>`.
- `falls back to "unknown" only when the envelope truly has no pattern
  attribute` — back-compat guard for stale DB rows.
- `match-found envelope: renders the pattern + path on match results`
  (regression guard).
- `match-found envelope: does NOT render the "unknown" fallback when
  envelope has the wrapper` (regression guard).

## Behaviour matrix (before/after)

| Scenario | Before (user sees) | After |
|---|---|---|
| No matches, `pattern="foo"`, `path="/x"` | `search "unknown"   unknown pattern not found` | `search "foo" in /x  no matches for pattern "foo" in path "/x"` (orange) |
| Match found | `search "foo" in /x  3 files, 12 matches` | unchanged |
| Stale DB row (no wrapper) | `search "unknown"   unknown pattern not found` | unchanged (back-compat fallback) |
| Regex parse error | `search "unknown"   error: regex parse error…` | unchanged (existing error path) |
| Click to expand | Raw Input panel shows the full wire XML | unchanged (existing Raw Input panel) |

## Verification

```bash
# Backend
cd /home/ginwa/ginwaaitoolbox/.worktrees/search-better-error
timeout 180 zig build test --summary all
# 2254/2263 pass, 6 skip, 3 fail
# 3 fails are pre-existing on main (per AGENTS.md "Undo regressions from
# 'fixing invalid'"): 3 updateToolResultById / resolveStaleLoadingToolResults
# tests in llm_history_tool_call_loading_test.zig. NOT touched by this change.

# Cross-compile smoke
timeout 60 zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
timeout 60 zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep pabrikcore -Mroot=/tmp/test_mod.zig -Mpabrikcore=src/root.zig
# both clean (no errors)

# Frontend
cd src/apps/desktop
timeout 90 bunx vitest run src/components/tool_outputs/__tests__/Search.spec.ts
# 7/7 pass

timeout 90 ./node_modules/.bin/vue-tsc --build
# clean (no output)
```

## Out of scope (deferred)

- **`parseSearch` parser bug** — `extractTag(content, 'pattern="([^"]+)"')`
  doesn't work because `extractTag` expects literal `<tag>` form. The
  frontend `Search.vue` uses its own regex (which works), so the
  user-visible bug is fixed. But downstream consumers reading
  `parseSearch()` see `null` for pattern/path. Should be a separate
  follow-up: either change `parseSearch` to use a regex-extracting
  helper, or change the backend to `<pattern>X</pattern>` (separate
  tag children inside `<search>`).

- **Other tools with anonymous wire data** — `read_file`, `bash`,
  `write_file` already use `<parameters>{json}</parameters>` inside
  their envelope and go through `parseBash` / `parseFile` correctly.
  Only `search` was missing the wrapper for the no-match case. After
  this fix, every agent tool's wire envelope carries the input
  parameters in a parsable shape.

- **Stale DB rows** — old `search` tool messages persisted before
  this fix don't have the `<search pattern="…" path="…">` wrapper.
  The frontend's `Search.vue` "unknown" fallback handles them
  gracefully (no crash, just shows "unknown" for the pattern/path).
  No migration is needed.

## Branch / commit

- Branch: `worktree/search-better-error`
- Plan: this file
- Memory: `.pabrik/memories/search-better-error-2026-08-06.md`
- Files changed: 3 modified + 1 new test file
