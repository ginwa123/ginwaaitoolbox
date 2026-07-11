# Plan: Glob tool — edge cases + hardening

**Branch:** `worktree/glob-edge-cases`
**Date:** 2026-07-08
**Task:** Add comprehensive edge case tests + hardening for the `glob` tool (`src/modules/agent/tools/glob.zig`).

## Problem statement

The current `glob.zig` is functional for the happy path (literal `*.zig`,
`**/*.ts`, brace expansion `{a,b}`, basic `.gitignore` respect) but ships
with at least 15 documented "unpredictable input" gaps that cause silent
corruption, panics, confusing error messages, or wrong behavior:

### Validation gaps (no error returned today)

1. **Empty pattern** — `pattern = ""` calls `expandBraces("")` which
   allocates `[""] ` of length 1, then `walkDir` happily iterates with an
   empty pattern. The `globMatch("", name, ...)` function always returns
   false for non-empty names. So the caller gets "no files found" with
   zero diagnostic info — looks identical to a real no-match but is
   actually a caller bug.

2. **Whitespace-only pattern** — Same as #1 but easier to trigger
   accidentally (e.g. `"   "` from a stray tool invocation). `parseBraces`
   doesn't strip whitespace.

3. **Pattern with NUL byte** — e.g. `"*.zig\0.log"` is passed verbatim to
   `expandBraces`. The brace expansion code does string concatenation
   with `@memcpy` — a NUL in the middle produces a corrupted pattern
   that's silently truncated.

4. **Path is "." (relative) but cwd doesn't exist** — `walkDir` opens
   `std.Io.Dir.cwd()` which returns the Io's cwd (often the binary's
   launch dir on a CI runner that defaults to `/`). If the LLM asked
   for `path = "./src"`, it depends on cwd being correct. No diagnostic
   is ever surfaced.

5. **Path that doesn't exist** — Currently `walkDir` calls
   `openDirAbsolute(io, dir_path, ...)` which returns an error that
   bubbles up as a generic "OpenDir failed" or similar. No
   `PathError`-style surfacing.

6. **`max_results = 0`** — The current code treats `0` as "use the
   default" (the `effective_max = if (max_res == 0) DEFAULT_MAX_RESULTS
   else max_res` shim). The expected behavior should be to validate
   up-front (search.zig does this) or to leave the silent default.

7. **`max_results > MAX_RECOMMENDED_RESULTS`** — The current code
   silently caps to MAX_RECOMMENDED_RESULTS (500). The caller's
   `result.truncated_count` reports the actual count, but the LLM
   doesn't know the limit was hit (vs having genuinely 500+).

8. **Negative `max_results` or `offset`** — `usize` parsing of negative
   JSON integers from `parseFromSlice` would yield huge numbers (e.g.,
   `-1 → usize.max`). The current `input.max_results: ?usize = null`
   means a malformed JSON input like `{"max_results": -1}` would be
   rejected at the JSON parse step (not the call site), but the same
   value via `input.max_results = @as(?usize, @bitCast(@as(usize, ...)
   ...)` is not guarded.

### Behavioral edge cases (the core of the bug class)

9. **Symlink loops** — `walkDir` opens with `follow_symlinks = opts.follow`
   (default false). A symlink loop produces infinite recursion up to
   `max_depth` (which defaults to no limit) → OOM or stack overflow.
   No protection.

10. **`.git` directory contents** — Even with a `.gitignore` that says
    `.git`, the loader uses `std.fs.path.join` which is then passed
    through `openFileAbsolute`. The gitignore loader itself works, but
    if no `.gitignore` exists in the dir, the `.git/` directory is
    still walked (and contains many files). The current
    `opts.dot = input.hidden` only hides files STARTING with `.`, not
    the `.git` directory itself (because `.git` is the dir name). So
    files INSIDE `.git/` are returned by `**/*.bin` patterns. Most
    LLM callers don't want them.

11. **Brace expansion with unmatched `{`** — `expandBraces` walks the
    pattern character by character. If `{foo` (no closing `}`) appears,
    depth never returns to 0; the function returns `[pattern]` (the
    original pattern unchanged). So `{*.zig` becomes `{*.zig` passed
    literally to `walkDir`, where `globMatch` returns false for any
    file (because `{` isn't a wildcard). Silent no-match.

12. **Brace expansion with numeric `{1..5}` mixed with comma in same
    braces** — `expandBraces` checks for `..` first. If the inner is
    `{1..5,7}`, both checks fail because `1..5,7` contains `,`. Returns
    `[pattern]` unchanged. Silent no-match.

13. **`file_type` parameter accepts anything** — The current code only
    treats `"f"`, `"file"`, `"d"`, `"directory"` as valid; everything
    else is silently ignored (both `.nodir` and `.onlydir` are false).
    An LLM calling with `file_type = "exec"` gets ALL types back —
    confusing.

14. **`offset = 0` returns the first results, `offset = 99999` returns
    empty** — The current code does `@min(offset, total)` and then
    slices `[offset..end]`. Correct, but not test-covered. Adding a
    test pins this behavior so a future refactor can't regress it.

15. **`max_results` paging: offset + max_results exceeds total** — Same
    slice logic. Should return what's available without padding.

### Output format gaps (the wire-format bugs)

16. **`toXmlSuccess` byte-cap truncation is silent** — `byte_count + xml.len
    > DEFAULT_MAX_OUTPUT_BYTES` breaks the loop and reports
    `total_truncated = result.truncated_count + (matches.len - returned)`.
    But if the FIRST match is bigger than 50 KB, the function still
    appends it (the `and returned > 0` guard). No test pins this.

17. **Empty results returns `<warning>`** — `toXmlSuccess` already does
    this correctly, but no test pins it. If a future refactor breaks the
    early-return path, the LLM gets an empty `<glob_summary>` instead of
    a clear "no files found" warning. Regression-prone.

18. **Byte-cap truncation reports wrong count when matched by SIZE not
    COUNT** — The current code conflates "truncated by size" and
    "truncated by count". `result.truncated_by_size` is defined but never
    set to `true`. If the byte cap is hit, the truncated_count math is
    wrong (matches what was suppressed, but doesn't distinguish cap-by-size
    from cap-by-count in the XML output).

19. **`pattern` containing XML metacharacters** — `<`, `>`, `&` in the
    pattern (e.g., a file named `<weird>.zig`) become literal XML markup
    in the `<glob_summary pattern="...">` attribute. Breaks XML
    parsers consuming the LLM output. The `allocPrint("{s}")` does NOT
    escape XML.

## Goal

Add 18+ edge case tests + fix the most impactful gaps so the glob tool:

- Never panics on any input that parses to a `GlobInput` struct.
- Always gives a clear, actionable message for "no match" vs
  "validation error" vs "path error" vs "config error".
- Defends against NUL injection in pattern (mirrors the search tool fix).
- Surfaces validation errors UP-FRONT (before walking the filesystem)
  when the call is obviously wrong.
- Distinguishes byte-cap truncation from count-cap truncation in the
  XML output (LLM can tell which limit was hit).
- Escapes XML metacharacters in the `pattern` XML attribute.

## Approach

### Strategy: Pure Zig, no API changes that ripple beyond `glob.zig`

Following the search.zig hardening pattern (commit `98d945fb`, plan
`2026-07-08-search-edge-cases.md`):

1. **Add up-front input validation** in `executeGlob` (BEFORE
   `expandBraces` so we don't allocate for invalid inputs):

   ```zig
   pub const GlobError = error{
       EmptyPattern,
       WhitespaceOnlyPattern,
       PatternContainsNulByte,
       PathDoesNotExist,
       InvalidFileType,
       InvalidMaxResults,
       InvalidOffset,
       MaxResultsTooLarge,
   };
   ```

   Validation rules:
   - `pattern.len == 0` → `EmptyPattern`
   - `pattern` is all whitespace → `WhitespaceOnlyPattern`
   - `pattern` contains `\x00` → `PatternContainsNulByte`
   - `path` doesn't exist (try `std.fs.accessAbsolute(path, {})`)
     → `PathDoesNotExist`
   - `file_type` not in `{null, "f", "file", "d", "directory"}`
     → `InvalidFileType`
   - `max_results = 0` → `InvalidMaxResults`
   - `offset > total_estimate (n/a)` → `InvalidOffset`
   - `max_results > MAX_RECOMMENDED_RESULTS + buffer` →
     `MaxResultsTooLarge` (warn but cap; don't error to keep LLM
     ergonomics — matches the search tool's behavior of hard-capping
     silently with truncation report)

2. **Fix the `path = .` (relative) + non-existent cwd scenario** by
   verifying `path` exists and pointing to a dir (not a file) in
   the validation block.

3. **Fix `.git` directory walk-through** by adding it to the
   always-ignored set in `walkDir` (or by interpreting
   `entry.kind == .directory and name == ".git"` as a skip).

4. **Fix symlink loop protection** by tracking visited inodes
   (or, simpler, by default `follow = false` and not walking
   inside a directory twice). Stick with the simpler approach —
   set a hard default `max_depth = 32` (configurable) for the
   non-follow case.

5. **Fix brace expansion with unmatched `{`** by detecting the
   unclosed-brace case and returning `expandBraces("...")` with the
   offending pattern (or a clear error). For now: detect and return
   original pattern, but ALSO log a warning via the LLM-friendly
   error (treat `{` without matching `}` as `InvalidBraceExpansion`).

6. **Fix byte-cap truncation accounting** by setting
   `truncated_by_size = true` when the byte cap is hit (distinct from
   the count cap).

7. **Escape XML metacharacters** in the `pattern` attribute via
   `helpers.sanitize.xmlEscape` (or write a small `xmlEscape` inline).

8. **Add 18+ tests** in `glob_test.zig`:
   - Validation tests (no fs invocation, run on all platforms): #1-#8
   - Behavioral tests (fs invocation, OS-independent): #9-#15
   - Output shape tests (no fs): #16-#18
   - Static-contract tests (grep source): the regex for error names

### What I will NOT do (scope guard)

- Will NOT change the `input.x` field shape (no new fields, no removed
  fields) — callers in `tool_registry.zig` continue to work unchanged.
- Will NOT change the brace expansion semantics for the happy-path
  cases (numeric ranges, comma lists) — only fix the unmatched-brace
  error reporting.
- Will NOT walk into `.git/` to find pack files (`.git/objects/`),
  but WILL skip the `.git` directory entirely (matches node-glob's
  default of skipping `.git` for safety).
- Will NOT touch `gitignoreContext` semantics — it's already
  documented in the description as "respects .gitignore".
- Will NOT fix the pre-existing
  `transform_llm_history_to_agent_messages_test.zig` bug — same
  out-of-scope decision as the search-edge-cases plan documented.
- Will NOT add a streaming variant of `toXmlSuccess` — the current
  ArrayList build is fast enough.

## File changes

| File | Change | Lines (approx) |
|------|--------|----------------|
| `src/modules/agent/tools/glob.zig` | GlobError enum, validation, truncation accounting, XML escape, .git skip | +200 / -50 |
| `src/modules/agent/tools/glob_test.zig` | 18+ new tests appended | +400 |
| `src/modules/agent/test_runner.zig` | Already imports glob_test.zig — no change | 0 |
| `src/ai_workflow/tui/tool_registry.zig` | Map new GlobError variants to LLM-friendly messages | +12 |

## Test inventory (18+ cases)

### Validation tests (no fs invocation, run everywhere)

1. `empty pattern returns EmptyPattern error`
2. `whitespace-only pattern returns WhitespaceOnlyPattern error`
3. `pattern with NUL byte returns PatternContainsNulByte error`
4. `path that doesn't exist returns PathDoesNotExist error`
5. `file_type not in {null,f,file,d,directory} returns InvalidFileType error`
6. `max_results = 0 returns InvalidMaxResults error`
7. `valid input passes validation (positive case to ensure over-validation didn't break)`
8. `positive: pattern "*.zig" matches files in test tree (existing test + strengthening)`

### Behavioral tests (fs invocation, OS-independent)

9. `.git/ directory is skipped even without a .gitignore`
10. `walkDir doesn't infinite-recurse on symlink cycles (max_depth default)`
11. `brace expansion handles unmatched brace gracefully (returns original or specific error)`
12. `brace expansion with {1..5,7} falls back to literal (no crash)`
13. `file_type = "f" filters to files only, "d" to dirs only`
14. `offset beyond results returns 0 matches with truncated_count = total`
15. `offset + max_results exceeds total, returns what's available`

### Output shape tests (no fs needed)

16. `toXmlSuccess with empty results emits <warning> (no <glob_summary>)`
17. `toXmlSuccess byte-cap hits → truncated_by_size=true, error message names byte cap`
18. `toXmlSuccess escapes XML metacharacters in pattern attribute (<, >, &)`

### Static-contract tests (no behavior — grep source)

19. `glob.zig defines GlobError enum with the new variants`
20. `glob.zig calls validation in executeGlob before expandBraces`
21. `glob.zig sets truncated_by_size=true in byte-cap branch`
22. `glob.zig skips .git directory in walkDir`
23. `tool_registry.zig maps new GlobErrors to LLM-friendly messages`

Total: 18 behavioral + 5 static-contract = **23 tests**.

## Pre-existing bug noted (out of scope)

`src/ai_workflow/tui/transform_llm_history_to_agent_messages_test.zig:126,167,211,252` fails to compile on main:

```
error: expected type 'ai_workflow.tui.agentic_loop.get_llm_histories.LLMHistory',
       found 'ai_workflow.tui.models.TUIHistory'
```

This breaks `zig build test` on main BEFORE this work lands. Per the
search-edge-cases plan, **fix is a follow-up branch**. Documented here so
the next agent picking up the test compile fix can find it.

## Implementation order

1. **Task 1: GlobError + validate-input errors** — Add `GlobError` enum + up-front validation in `executeGlob`. Add tests #1-#8.
2. **Task 2: Path validation** — Verify `path` exists + is a directory before walking. Add test #4 (and shore up the existing regression test #7).
3. **Task 3: Symlink loop + .git skip** — Default `max_depth` cap + `.git` early-skip in `walkDir`. Add tests #9-#10.
4. **Task 4: Brace expansion hardening** — Detect unmatched `{` and `{x,y,}` edge cases. Add tests #11-#12.
5. **Task 5: file_type strict validation** — Reject unknown file_type values. Add test #5 (rewritten to be strict).
6. **Task 6: Output hardening** — XML escape the `pattern` attribute; set `truncated_by_size = true` on byte-cap hit. Add tests #17-#18.
7. **Task 7: pagination math** — Test pins for offset+beyond-total + offset+max=underflow. Add tests #14-#15.
8. **Task 8: tool_registry.zig error mapping** — Map new error variants to LLM-friendly messages. Add static test #23.
9. **Task 9: Static-contract tests** — Add tests #19-#22 (verify source has the hardening markers).
10. **Task 10: Verify** — `zig build install:linux:system` clean, static tests pass, behavioral tests pass.

## Risk assessment

- **Low**: All changes are inside `glob.zig` + the registry caller. No
  new public API surface (new error variants ADDs to the error set,
  doesn't remove). Callers keep working.
- **Low**: Adding `max_depth` default cap of 32. If the LLM passes a
  `**/.../...` deep tree, it'll stop at 32 levels — which is the
  default for `git ls-tree --depth`, `find -maxdepth`, and
  `node-glob`. Matches industry convention.
- **Low**: Skipping `.git/` automatically. Could regress someone who
  legitimately wants to glob `.git/` contents (rare — no LLM
  caller would do this). The LLM can pass `pattern = ".git/**/*"` and
  `hidden = true` if they need it explicitly.
- **Medium**: Strict `file_type` validation rejects "exec", "symlink",
  etc. that today silently return all results. Existing LLM callers
  in `tool_registry.zig` use `"f"` or `"d"` only — confirmed by
  grep. No regression risk.
- **Medium**: XML escaping `pattern`. If the existing frontend or LLM
  consumes the `<glob_summary pattern="...">` and parses the attribute
  literally (without an XML parser), an escaped `<weird>` (XML-escaped
  to `&lt;weird&gt;`) would look different. But: the XML standard says
  attributes MUST be escaped, and any downstream XML parser will handle
  it correctly. Tests verify the exact escaped form.

## Success criteria

- `zig build install:linux:system` exits 0 with my changes.
- `src/modules/agent/tools/glob_test.zig` registers 18+ new tests
  (the existing 14 tests must continue to pass — no regressions).
- All 4 existing behavioral edge tests (Chunk 1 of the duplicate-results
  plan) continue to pass.
- Static-contract tests pass on all platforms.
- The pre-existing `transform_llm_history_to_agent_messages_test.zig`
  bug is documented but NOT fixed.
- No NEW public API surface; all callers keep working.
