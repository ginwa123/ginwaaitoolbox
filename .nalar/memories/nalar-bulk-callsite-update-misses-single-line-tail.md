# Bulk callsite refactor — `// empty` single-line comment tail often misses the regex

A regex-based bulk editor that targets a callsite's CLOSER
(`        "",\n    );`) will MISS callsites whose last argument is
followed by a trailing comment on the same line, because the closer
shape is `        "", // empty X` not `        "",\n    )`.

## Symptom

I added a new `designStatusContent` parameter to
`prompts.build_agent_prompt` (a 14-arg function) and ran a
Python regex `re.compile(r'\n        "",\n    \);')` to insert the
new arg at the end of every callsite that ended with the canonical
multi-line closer pattern. The script reported "16 sites updated"
out of 17 expected. After running, `zig build test` failed with
`expected 14 argument(s), found 13` at:
- `src/modules/agent/prompts_test.zig:901:31`
- `src/modules/agent/prompts_test.zig:932:31`

The 2 missed callsites both had a trailing comment on the last
literal arg, e.g.:
```zig
        "", // empty kanbanStatusContent
    );              // ← my regex looked for `",\n    );` but the
                    //   actual closer is `", // comment\n    );`
```

The script happily updated every `"",\n    );` closer but skipped
the `"", // ...\n    );` closers — and there's no way to know
without running the build.

## Root cause

The regex was designed against the project's most-common closer
shape, not ALL closer shapes. Two callsite styles exist:
1. **Multi-line no-comment tail** — `        "",\n    );` (the
   shape most tests use, where every arg is on its own line and
   the trailing arg has no comment).
2. **Single-line commented tail** — `        "", // empty <name>\n    );`
   (used by tests whose last arg was a deliberately-empty placeholder
   for documenting intent — typically the kanban/design tests where
   the test name implies "no content here").

Both are valid Zig, both compile, but they're byte-different.

## How to avoid

### Option A — match the arg addition, not the closer shape

Instead of inserting at the END of every callsite using a closer
regex, INSERT BEFORE the LAST `"",` arg using an arg index:
```python
# Find every callsite boundary, then for each one:
# 1. Compute the depth (commas in parens) to find the closing `)`.
# 2. Find the last `,\n` inside the callsite (the separator between
#    the second-to-last and last args).
# 3. Insert `",\n        \"\" // empty <newname>"` after that
#    separator.
```
More complex to write, but inserts the new arg at the same depth
position for ALL callsites regardless of trailing-comment style.

### Option B — write a Zig-friendly parser
A 50-line AST-aware walker that finds every `prompts.build_agent_prompt(`
and walks the args by tracking `,` count (skipping commas inside
strings/comments) — then inserts at the AST-correct position.

### Option C — match BOTH closer shapes

```python
# Multi-line closer (no comment):
PATTERN_A = re.compile(r'\n        "",\n    \);')
# Single-line commented tail closer:
PATTERN_B = re.compile(r'\n        "",\s*//[^\n]*\n    \);')
```
Run BOTH patterns. Document the limitation. Then verify with
`zig build test` (compile errors will surface any missed callsite —
the test build's module graph reaches callsites that production
code reaches via separate analysis paths).

### Option D — verify after running

Run `zig build test 2>&1 | grep -E 'error:|expected.*argument(s)?'` after
the script. Any "expected N argument(s), found M" tells you exactly
which callsites were missed. Fix those by hand. The script's "X sites
updated" count is a LIE — `zig build test` is the ground truth.

## Why the test build catches it but only partially

`zig build test` compiles a SEPARATE module graph rooted at the test
runner. It reaches every callsite from the test file's perspective.
If a test file's callsite is missed, `zig build test` will catch it
with "expected N argument(s), found M". But `zig build test` does NOT
catch missed callsites in non-test files (production code) because
the test graph doesn't reach them via lazy analysis.

The full `zig build install:linux:system` (or any `addExecutable`)
target compiles the FULL `src/main.zig → nalarcore` module graph.
For a missed *production* callsite (not the test file), only the
install target catches it. This is the lazy-analysis pitfall
documented in `custom-http-server-per-request-arena.md` etc.

## When this bites

- Any bulk-rename / bulk-arg-add / bulk-signature-change where you
  use a regex to find callsites by their shape.
- Any tool/handler/helper with >5 callsites where hand-editing is
  impractical.
- The specific case in this repo: a 14-arg `build_agent_prompt` with
  test callsites that use trailing comments on the last arg to
  document intent ("empty kanbanStatusContent", "empty
  designStatusContent", etc.).
- Future similar functions will have the same problem — the
  project's convention is to use trailing comments on the LAST
  arg of a callsite to document that it's a placeholder, which
  always defeats single-shape regex scripts.

## How to detect

After running the bulk script:
1. `timeout 180 zig build test --summary all 2>&1 | grep 'expected.*argument(s)?'`
   — finds MISSED TEST callsites.
2. `timeout 180 zig build install:linux:system 2>&1 | grep 'expected.*argument(s)?'`
   — finds MISSED PRODUCTION callsites (lazy analysis trap).
3. The intersection tells you the full set of misses.

If the install target reports errors that the test target missed,
that's the lazy-analysis pitfall biting the production code path.
Fix those manually too.

## Concrete precedent in this repo

`src/modules/agent/prompts_test.zig:901` (was) and `:932` (was) had
the 2 missed callsites during the `designStatusContent` arg-add
refactor on `feature/design-mode` branch (2026-07-06, commit
`1ac82342`). Both had the shape:
```zig
        "", // empty kanbanStatusContent
    );
```
The regex `re.compile(r'\n        "",\n    \);')` (matched
closer-shape) updated 16/17 callsites; these 2 were missed.
Manual fix added `,` + `\n        "",` + `\n    `) on the next
line, then `// empty designStatusContent` comment for clarity.

The commit message explicitly noted the missing-callsite bug and
the fix path, so the rationale is in the project history.
