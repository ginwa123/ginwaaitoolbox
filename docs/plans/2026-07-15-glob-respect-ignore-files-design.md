# Glob Tool — `respect_ignore_files` Parameter (Design)

**Date:** 2026-07-15
**Status:** Approved
**Branch:** `worktree/glob-respect-ignore`
**Author:** Brainstorm session
**Related:** [Search tool `respect_ignore_files` PR #96](https://github.com/ginwa123/ginwaaitoolbox/pull/96) — same pattern, parallel feature.

## Problem

`src/modules/agent/tools/glob.zig` ships with a custom `.gitignore`
parser (lines 22-188: `GitignoreEntry`, `parseGitignoreLine`,
`loadGitignore`, `gitignoreGlobMatch`, `GitignoreContext`,
`isIgnored`, etc.) and unconditionally applies it during the directory
walk.

The tool description in the LLM-facing schema even highlights this as a
**feature**:

> "Automatically respects .gitignore files - ignored files are
> excluded from results."

But there is **no opt-out**. The companion `search` tool just gained
`respect_ignore_files` in PR #96 — operators can now ask "find all
matches in `node_modules/`", but they cannot ask "list all files in
`node_modules/`" via glob. Same UX gap.

## Solution

Mirror PR #96's pattern exactly. Add one optional field to `GlobInput`:

```zig
pub const GlobInput = struct {
    pattern: []const u8 = "*",
    path: []const u8 = ".",
    max_results: ?usize = null,
    offset: ?usize = null,
    hidden: bool = false,
    ignore_case: bool = false,
    file_type: ?[]const u8 = null,
    follow: bool = false,
    /// When true (default), the tool respects .gitignore / .ignore / .rgignore
    /// (using glob's own custom parser — supports `!` negation, `/` anchors,
    /// etc.). When false, no ignore-file filtering is applied, so the tool
    /// will list files in `node_modules/`, `build/`, `.git/`, etc.
    /// Mirrors the search tool's `respect_ignore_files` parameter.
    respect_ignore_files: bool = true,
};
```

When `false`, the executor at `glob.zig:982` skips creating a
`GitignoreContext` and the `walkDir` calls at lines 826/833/842/872
receive `gitignore_ctx = null`. The walker already has `if
(gitignore_ctx) |ctx| { ... }` guards at lines 677-678 and 712-715 —
so the existing nullable plumbing just lights up.

## Design Choices

| Decision | Value | Why |
|---|---|---|
| Parameter type | `bool` (one field) | Same as search tool (#96) — consistency |
| Default | `true` | Preserves current behavior; no breaking change |
| Plumbing | Pre-existing `?*GitignoreContext` nullable in `walkDir` | Avoids refactoring — the option has been there since glob was written, just always passed non-null |
| Out of scope | `--no-ignore-vcs` style (drop only `.gitignore`) | Not requested; matches search's scope |
| Out of scope | Custom ignore file paths | Not requested; matches search's scope |

## Files Changed (4 total, parallel to PR #96)

| File | Change |
|---|---|
| `src/modules/agent/tools/glob.zig` | +1 field on `GlobInput` (line ~318); conditionally init `GitignoreContext` (line ~982); pass `gitignore_ctx = null` when false (4 sites in `walkDir` callers); update `glob_tool.description`; +1 JSON schema entry |
| `src/modules/agent/tools/glob_test.zig` | +4 tests: 1 validation + 3 behavioral |
| `src/ai_workflow/tui/tool_registry.zig::execGlob` | No change (`GlobInput` parses automatically; no new error variants) |
| Frontend / wire format | No change (default-true preserves wire format) |

## Data Flow

```
LLM tool_call.arguments JSON
  → parseFromSlice(GlobInput, ...)
    → executeGlob builds gitignore_ctx
      → if respect_ignore_files == true: GitignoreContext.init + walkDir passes it
      → if respect_ignore_files == false: gitignore_ctx stays null + walkDir skips filtering
  → unchanged XML output
```

The bool flows through `GlobInput` → `executeGlob` → `walkDir`'s
`?*GitignoreContext` slot. Nothing else in the pipeline sees it.

## Error Handling

**No new error variants.** The boolean is always safe — there's
nothing to validate. If the executor itself fails (path missing,
bad pattern), existing `GlobError` variants fire unchanged.

## Tests (4 new, parallel to PR #96's pattern)

| # | Type | Asserts |
|---|---|---|
| 1 | Validation | `respect_ignore_files = false` does NOT trigger a validation error |
| 2 | Behavioral | Default `true` excludes `.gitignore`'d paths |
| 3 | Behavioral | `false` includes `.gitignore`'d paths |
| 4 | Behavioral | `false` also un-respects `.ignore` / `.rgignore` |

Each test sets up a tmpdir with an ignore file containing a directory
pattern, puts marker files both inside and outside that directory, and
runs `executeGlob` with both flag values to verify which paths appear.

## Backwards Compatibility

✅ `GlobInput.respect_ignore_files` defaults to `true` → all
existing call sites and tests work unchanged.
✅ JSON schema marks it `default: true` so the LLM sees the default.
✅ `zig build test` count: same baseline + 4 new tests.

## LLM-Facing Tool Description (added to `glob_tool.description`)

```
\- respect_ignore_files: default true (respects .gitignore via glob's
\  custom parser — supports `!` negation, `/` anchors, .ignore,
\  .rgignore). Set false to list gitignored paths
\  (build/, node_modules/, .git/, etc.).
```

## Parallel-to-PR-96 Note

This is a deliberate "two tools, same parameter, same semantics" push
so the tool family has consistent ignore-file handling. Future PRs that
add a third ignore-files-aware tool should follow the same pattern.

## Implementation Note: Pre-existing Nullable Plumbing

The fact that `walkDir`'s `gitignore_ctx: ?*GitignoreContext` parameter
has always been nullable (even though only one call site exists and it
always passes non-null) is a small piece of pre-existing engineering
fortune. Without that nullable, the change would have required a
`walkDir` signature change. As-is, the change is purely about toggling
the existing nullable.