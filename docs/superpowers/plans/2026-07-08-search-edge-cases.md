# Plan: Search tool — edge cases + hardening

**Branch:** `worktree/search-edge-cases`
**Date:** 2026-07-08
**Task:** Add more edge cases for the `search` tool (`src/modules/agent/tools/search.zig`) and handle the most unpredictable inputs robustly.

## Problem statement

The current `search.zig` is functional for the happy path (regex pattern, valid path, JSON output) but ships with at least 12 documented "unpredictable input" gaps that cause silent corruption, panics in debug, security/flag-injection issues, or confusing error messages:

1. **Flag injection (security)** — `input.pattern` starting with `-` (e.g. `--help`, `-z`, `--`) is passed verbatim to ripgrep and interpreted as a flag, NOT as a search pattern. This can change ripgrep's behavior, print help, dump binary content, or in pathological cases leak file contents.
2. **`@intCast` panic on negative `line_number`** — `parseFromSlice` of `data.line_number` returns `i64`; ripgrep output is `>= 1`, but a malformed rg JSON or hand-rolled JSON could produce a negative value. `@intCast(negative_i64 → usize)` PANICS in debug, UB in release-fast.
3. **Empty pattern** — `pattern = ""` is allowed by ripgrep but produces noisy output (every line is a "match" if combined with `-l`, or empty if not). The tool returns "<warning>pattern not found" — wrong for what actually happened.
4. **Path doesn't exist** — ripgrep exits 2 with stderr; tool returns `<warning>stderr text</warning>` but doesn't surface that it's a *file not found* error vs *no matches* warning.
5. **cwd doesn't exist** — `std.process.run` returns `error.FileNotFound`. The tool_registry wraps this generically ("search failed: FileNotFound") which gives the LLM no actionable hint.
6. **`max_results = 0`** — silently returns empty results + "<warning>pattern not found", indistinguishable from a real "no match" but the user got 0 not 50 because they asked for 0.
7. **`head = 0` / `tail = 0`** — same as #6; returns empty + false "<warning>".
8. **`max_output = 0`** — passes `stdout_limit = .limited(0)` to `std.process.run`. The behaviour is "limit is 0 bytes" — ripgrep writes nothing, fails or produces zero output. We don't validate.
9. **`head > max_results` or `tail > max_results`** — currently the slicing branch only fires if `head_n < matches.items.len`. If `head_n == 100` but only 50 matches exist (after max_results cap), no slicing happens. That's actually correct behaviour, but the LLM might think they asked for 100 and got 50. No clarification.
10. **Binary file match** — ripgrep's `--json` output of a binary match includes a snippet with non-UTF-8 bytes. The current code uses `std.json.fmt` (via search_result_to_string_grouped) which would emit the snippet as an array of integers per `std.json.fmt`'s `emit_strings_as_arrays` rule (see memory `zig-0.16-std-json-fmt-emits-invalid-utf8-as-array`). The XML output becomes invalid for the LLM frontend.
11. **Pattern with NUL byte** — `"foo\0bar"` gets passed to ripgrep which truncates at NUL. Search runs against `"foo"` silently.
12. **Grouped vs flat output** — the `group_by_file: bool = true` input field is declared but the tool_registry ALWAYS calls `search_result_to_string_grouped` regardless of the flag. The flag is dead code.

## Goal

Add 12+ edge case tests + fix all 12 gaps so the search tool:
- Never panics on any input that parses to a `SearchInput` struct.
- Always gives a clear, actionable message for "no match" vs "pattern error" vs "path error" vs "I/O error" vs "config error".
- Defends against flag-injection and binary-content output corruption.
- Surfaces validation errors UP-FRONT (before spawning rg) when the call is obviously wrong.

## Approach

### Strategy: Pure Zig, no API changes that ripple beyond `search.zig`

Per memory `zig-slice-headers-across-defer-lifetimes` and the project's "surgical patches" rule, I will:

1. Modify `search.zig` to:
   - **Validate inputs UP-FRONT** (before spawning rg). Reject with clear errors.
   - **Sanitize inputs** for the cases where ripgrep can't be told directly:
     - Pattern starting with `-` → prepend an empty `--` separator OR use a ripgrep flag like `-e`.
     - Pattern with NUL byte → reject.
     - Empty pattern → reject (clearer message than "no match").
   - **Harden the JSON parser**:
     - Validate `line_number >= 1` before `@intCast`.
     - Reject empty `file` paths (corrupt JSON line).
     - Sanitize non-UTF-8 snippets via `helpers.sanitize.sanitizeUtf8` before they enter the XML output.
   - **Add new error variants** to `executeSearch`:
     - `EmptyPattern`
     - `PatternStartsWithDash` (with detail "did you mean to search for the literal text 'foo-bar'? If so, use the literal flag.")
     - `PatternContainsNulByte`
     - `InvalidMaxOutput` (max_output == 0)
     - `InvalidMaxResults` (max_results == 0)
     - `MaxOutputTooLarge` (e.g. > 100 MB hard ceiling to prevent OOM)
     - `PathError` (path doesn't exist; ripgrep stderr attached for detail)
     - `RegexParseError` (rg exit 2 with regex-parse signature)
   - **Wire `group_by_file`** — actually honor the flag by emitting flat XML when `false`. Add `search_result_to_string_flat` companion function.
2. Add **`search_test.zig`** with 14+ tests covering:
   - **Validation tests** (no rg invocation): empty pattern, pattern with NUL, max_output=0, etc.
   - **Behavioral tests** (rg invocation, may be marked `builtin.os.tag == .linux` to skip on CI Windows/macOS): flag injection prevention, regex parse error, path doesn't exist, cwd doesn't exist, binary snippet, etc.
   - **JSON parser hardening**: malformed line with negative line_number, line_number=0, empty file path, all rejected silently before.
3. Wire `search_test.zig` into `src/modules/agent/test_runner.zig`.

### Verification strategy (given the pre-existing test breakage)

There is a pre-existing compile error in `src/ai_workflow/tui/transform_llm_history_to_agent_messages_test.zig` — it passes `models.TUIHistory` to `transform_llm_history_to_agent_message(...)` which expects `agentic_loop.LLMHistory`. This breaks `zig build test` on main.

Per memory `cross-check-claims-against-source` and `verification-before-completion`, I will:

1. Verify my Zig code compiles via `zig build install:linux:system` — this target reaches the `addExecutable` graph which DOES include my `search.zig` (via `nalarcore.search_tool` re-exported in `src/root.zig:401`).
2. Add **static-contract tests** (read source, grep for patterns) for the cases that can't be easily behavioral — following the convention from `kanban_list_test.zig`, `routines_run_test.zig` and `memories_crud_test.zig` (per memory `nalar-http-handler-thin-wrapper-pattern`).
3. Behavioral tests will use `if (builtin.os.tag == .linux) { ... } return;` to skip on platforms without `rg` installed (matches the bash_test.zig pattern).
4. Document the pre-existing transform_llm_history_to_agent_messages_test.zig bug as an **out-of-scope finding** in the plan, not something I'll fix in this branch.

### What I will NOT do (scope guard)

- Will NOT refactor `search_result_to_string_grouped` into a streaming generator (the current per-match ArrayList works).
- Will NOT change the input parameter contract (no new fields, no removed fields) — callers in `tool_registry.zig` continue to work unchanged.
- Will NOT touch `tool_registry.zig` except to surface the new error variants with clearer messages.
- Will NOT fix the pre-existing `transform_llm_history_to_agent_messages_test.zig` bug.
- Will NOT change the `head AND tail → error` early return (it's already correct).

## File changes

| File | Change | Lines (approx) |
|------|--------|----------------|
| `src/modules/agent/tools/search.zig` | Validation, sanitization, hardening, new flat output | +180 / -30 |
| `src/modules/agent/tools/search_test.zig` | NEW: 14+ tests | +250 (new file) |
| `src/modules/agent/test_runner.zig` | Register new test file | +1 |
| `src/ai_workflow/tui/tool_registry.zig` | Map new error variants to LLM-friendly messages | +15 |

## Test inventory (14+ cases)

### Validation tests (no rg invocation, run on all platforms)
1. `empty pattern returns EmptyPattern error`
2. `pattern with NUL byte returns PatternContainsNulByte error`
3. `max_output = 0 returns InvalidMaxOutput error`
4. `max_results = 0 returns InvalidMaxResults error`
5. `head AND tail both set returns HeadAndTailMutuallyExclusive error` (already covered, keep regression)
6. `valid input passes validation` (positive case to ensure over-validation didn't break)

### Security / flag injection (rg invocation, Linux/macOS only)
7. `pattern starting with -- does NOT trigger rg --help` (the rg argv uses `-e <pattern>` to bypass flag parsing)
8. `pattern = -e does not consume next arg as pattern`

### Error surfacing (rg invocation)
9. `path that doesn't exist returns PathError with rg stderr attached`
10. `cwd that doesn't exist returns error from std.process.run`
11. `invalid regex like (unclosed paren returns RegexParseError`
12. `binary file match produces sanitized UTF-8 snippet (no array-of-ints)`

### Output shape
13. `group_by_file = false produces flat XML output (one match per line)`
14. `group_by_file = true (default) produces grouped XML output`

### Static-contract tests (run on all platforms)
15. `search.zig uses `-e <pattern>` in argv to prevent flag injection`
16. `search.zig rejects empty pattern with EmptyPattern error before spawning rg`
17. `search.zig sanitizes snippets via sanitizeUtf8 before XML output`
18. `search_result_to_string_flat exists and emits one-line-per-match XML`

### Robustness (rg invocation)
19. `max_results exceeded → exactly max_results returned`
20. `head slice after max_results cap works correctly`
21. `tail slice after max_results cap works correctly`
22. `negative line_number in rg JSON is dropped, not panicked`

Total: 14 behavioral + 4 static-contract = **18 tests**.

## Pre-existing bug noted (out of scope)

`src/ai_workflow/tui/transform_llm_history_to_agent_messages_test.zig:126,167,211,252` fails to compile on main:

```
error: expected type 'ai_workflow.tui.agentic_loop.get_llm_histories.LLMHistory',
       found 'ai_workflow.tui.models.TUIHistory'
```

The test passes a `TUIHistory` to `transform_llm_history_to_agent_message(allocator, message: agentic_loop.LLMHistory)`. The mismatch means `zig build test` exits non-zero on main BEFORE my work lands.

**Fix: in a follow-up branch.** Either:
- Convert `TUIHistory` → `LLMHistory` in the test (4 lines), OR
- Change the function signature to accept `TUIHistory` and convert internally.

This is unrelated to search.zig and would muddle the PR. Documented here so the next agent picking up the test compile fix can find it.

## Implementation order

1. **Task 1: Validate-input errors** — Add the `EmptyPattern`, `PatternContainsNulByte`, `InvalidMaxOutput`, `InvalidMaxResults` error variants + up-front validation in `executeSearch`. Add validation tests #1-#4.
2. **Task 2: Flag injection fix** — Change argv from `[..., input.pattern, input.path]` to `[..., "-e", input.pattern, "--", input.path]` (the `-e` flag tells rg "next arg is the pattern, even if it starts with `-`"). The `--` after pattern ensures path is not parsed as a flag. Add tests #7-#8.
3. **Task 3: Error surfacing** — Inspect rg's exit code + stderr; map exit 2 + "regex parse" → RegexParseError; exit 2 + other → PathError; exit 1 + stderr present → NoMatch (warning). Add tests #9-#11.
4. **Task 4: Binary snippet sanitization** — Sanitize via `helpers.sanitize.sanitizeUtf8` before storing in `SearchMatch.snippet`. Add test #12.
5. **Task 5: Honor group_by_file** — Add `search_result_to_string_flat` and route in tool_registry based on the flag. Add tests #13-#14.
6. **Task 6: Robustness** — Validate `line_number >= 1` before `@intCast`; reject empty `file` from JSON. Add test #22.
7. **Task 7: Wire tests + tool_registry** — Add `search_test.zig` to `test_runner.zig`; map new errors in `execSearch` to LLM-friendly messages.
8. **Task 8: Verify** — `zig build install:linux:system` clean, static tests pass, behavioral tests pass on Linux (other platforms skip).

## Risk assessment

- **Low**: All changes are inside `search.zig` + the registry caller. No new public API surface; no public type signature changes. Callers in tool_registry keep working.
- **Medium**: The argv change (`-e <pattern> -- <path>`) could change rg's behavior subtly if rg ever changes its flag parsing — but `-e` is documented as a stable, long-standing flag. The `--` separator is also documented and stable since rg v0.10 (2018).
- **Low**: Adding new error variants. Each variant maps cleanly to a user-facing message.
- **Low**: `helpers.sanitize.sanitizeUtf8` is already used elsewhere in the codebase (per memory `zig-0.16-std-json-fmt-emits-invalid-utf8-as-array`); zero new dependency.

## Open questions / decisions deferred

- **Do we cap `max_output` to prevent OOM?** Plan: yes, hard ceiling at 100 MB. The 1MB default is fine for most searches; the field is meant for "I know I'll get lots of output" cases. 100 MB is large enough for any practical search without risking the test binary's OOM. Decision: hard cap, error message names the limit.
- **Should `group_by_file = false` produce plain text or one-line-per-match XML?** Plan: one-line-per-match XML (matching the format of grep output: `<m><l>{line}</l><s>{snippet}</s></m>` inside `<results>` block). Reasoning: keeps the format consistent with the grouped case (the per-match element is `<m>...</m>`), and the LLM can iterate either way.
- **Should the new `search_result_to_string_flat` go in `search.zig` or `tool_registry.zig`?** Plan: `search.zig`. Same file = lower coupling, matches existing convention.

## Success criteria

- `zig build install:linux:system` exits 0 with my changes.
- `src/modules/agent/tools/search_test.zig` exists and registers 14+ tests in `test_runner.zig`.
- Behavioral tests pass when run directly via the test binary (Linux-only behavioral tests are guarded by `if (builtin.os.tag == .linux)`).
- Static-contract tests pass on all platforms.
- The pre-existing `transform_llm_history_to_agent_messages_test.zig` bug is documented but NOT fixed.
- No NEW public API surface; all callers keep working.