# Search Tool — `respect_ignore_files` Parameter (Design)

**Date:** 2026-07-15
**Status:** Approved
**Branch:** `worktree/search-respect-ignore`
**Author:** Brainstorm session

## Problem

`src/modules/agent/tools/search.zig` spawns ripgrep with no ignore-related
flags, so rg's **default** behavior applies — it respects `.gitignore`,
`.ignore`, `.rgignore`, `.git/info/exclude`, the global gitignore, and
parent-dir gitignores.

This is correct for most LLM queries ("find usages of `MyType`"), but
breaks when the LLM (or operator) wants to search across gitignored
content:

- `node_modules/` (gitignored, but contains tokens worth searching)
- `build/`, `dist/`, `.zig-cache/` (build outputs)
- `.git/` internals (reflog, etc.)
- Custom vendored deps

There is currently no way to opt out — the tool silently skips any file
that matches an ignore pattern.

## Solution

Add one optional field to `SearchInput` to control whether ripgrep
respects ignore files. Default = `true` (preserves current behavior,
zero breaking change).

```zig
pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
    head: ?usize = null,
    tail: ?usize = null,
    max_output: ?usize = 1024 * 1024,
    group_by_file: bool = true,
    cwd: ?[]const u8 = null,
    respect_ignore_files: bool = true,   // ← new
};
```

When `false`, append `--no-ignore` to ripgrep's argv. That flag
(rg --help) "implies `--no-ignore-dot`, `--no-ignore-exclude`,
`--no-ignore-global`, `--no-ignore-parent` and `--no-ignore-vcs`" —
i.e., disables **all** ignore-file filtering in one switch.

## Design Choices

| Decision | Value | Why |
|---|---|---|
| Parameter type | `bool` (one field) | Simplest, covers 90% of value |
| Default | `true` | Preserves current behavior; no breaking change |
| Map to flag | `--no-ignore` | One flag disables all ignore files |
| Out of scope | `--ignore-file PATH` (custom file) | Not in user's request; can be follow-up |
| Out of scope | `--no-ignore-vcs` (VCS-only ignore) | Same — not requested |
| Out of scope | `--hidden` (search `.git/` etc.) | Hidden files ≠ ignored files; separate concern |

## Files Changed (4 total)

| File | Change |
|---|---|
| `src/modules/agent/tools/search.zig` | +1 field to `SearchInput`; conditional argv append; updated tool description; +1 JSON schema entry |
| `src/modules/agent/tools/search_test.zig` | +4 tests: 1 validation + 3 behavioral (with rg) |
| `src/ai_workflow/tui/tool_registry.zig::execSearch` | No change (SearchInput parses automatically; no new error variants) |
| (other files — TS frontend, etc.) | No change (default-true preserves wire format) |

## Data Flow

```
LLM tool_call.arguments JSON
  → parseFromSlice(SearchInput, ...)  // respects default if arg omitted
    → executeSearch builds argv
      → if respect_ignore_files == false: appendSlice("--no-ignore")
        → rg runs without ignore-file filtering
  → unchanged output XML
```

## Error Handling

**No new error variants.** The boolean is always safe — there's nothing
to validate. If ripgrep itself fails (path missing, regex invalid),
existing `SearchError` variants fire unchanged.

## Tests (4 new)

| # | Type | Asserts |
|---|---|---|
| 1 | Validation | `respect_ignore_files: false` does NOT trigger a validation error |
| 2 | Behavioral | Default `true` skips files in `.gitignore`'d directories |
| 3 | Behavioral | `false` searches files in `.gitignore`'d directories |
| 4 | Behavioral | `false` also un-respects `.ignore` / `.rgignore` |

Setup pattern: create tmpdir with `.gitignore` containing a directory
pattern, put a marker-token file inside that directory, also put a
marker-token file outside it, then search for the token with both
flag values and assert which files appear.

## Backwards Compatibility

✅ `SearchInput.respect_ignore_files` defaults to `true` → all
existing call sites work unchanged.
✅ JSON schema marks it `default: true` so the LLM sees the default.
✅ `zig build test` count: same baseline + 4 new tests.

## LLM-Facing Tool Description (added to `search_tool.description`)

```
\- respect_ignore_files: default true (respects .gitignore/.ignore/.rgignore).
\  Set false to search gitignored paths (build/, node_modules/, .git/, etc.).
```
