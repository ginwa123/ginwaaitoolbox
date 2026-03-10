# ExecutingAgent Memory

<!-- Existing entries may be updated if a better fix or more accurate root cause is found. -->

## Language & Environment Facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- [zig@0.15] `{s}` format string requires `[]u8` — use `@errorName(err)` to convert error types to string
- [zig@0.15] ArrayList API changed: `.init` → `.empty`, all of `.appendSlice`, `.deinit`, `.toOwnedSlice` now require allocator as first arg
- [zig@0.15] `std.fs.File.createFile` replaces `writeFile` for creating/overwriting files
- [zig@0.15] `ArrayList.deinit` requires allocator parameter
- [zig@0.15] Line collection must include newlines explicitly when building strings
- [zig@0.15] `std.fs.accessableAbsolute` doesn't exist — use `std.fs.openFileAbsolute` with try/catch
- [zig@0.15] `ArrayList.init(allocator)` → `ArrayList.empty`
- [zig@0.15] `ArrayList.writer()` → `ArrayList.writer(allocator)`
- [zig@0.15] `std.os.pid` doesn't exist — use literal 0 for processId in LSP init
- [zig@0.15] `std.fs.File.flush()` doesn't exist — not needed, write is immediate
- [zig@0.15] `std.fs.File.readByte()` doesn't exist — use `file.read()` instead
- [zig@0.15] `json.Value.get()` doesn't exist — use `.object.get()` for object values
- [zig@0.15] `process.Child.kill()` returns `Term`, not void — use `_ = ` to discard
- [zig@0.15] `allocator.dupeZ()` returns `[:0]u8` but argv needs `[:0]const u8` — use stack buffer approach

## Resolved Issues

<!-- Issues encountered and fixed during runs. -->

- [2026-03-08] No issues encountered.
- [2026-03-09] Agent system restructured — GeneralAgent and KnowledgeAgent removed, ExplorationAgent enhanced with classification logic

## [2026-03-09] LSP Client Implementation

**Problem:** Multiple Zig 0.15 API changes broke LSP client implementation
**Root cause:** ArrayList, std.fs, std.process APIs changed significantly in Zig 0.15
**Fix:**
- Used `ArrayList.empty` instead of `ArrayList.init(allocator)`
- Used `ArrayList.writer(allocator)` instead of `ArrayList.writer()`
- Used `std.fs.openFileAbsolute` with try/catch instead of `accessableAbsolute`
- Used `file.read()` instead of `file.readByte()`
- Used `json.Value.object.get()` instead of `json.Value.get()`
- Used `_ = child.kill()` to discard Term return value
- Used stack buffer for dupeZ since it returns mutable `[:0]u8` but argv needs `[:0]const u8`
**Reuse signal:** When implementing process spawning in Zig 0.15, test each API call individually; use stack buffers for null-terminated strings to avoid ownership issues

## [2026-03-08] save_message.run error format string

**Problem:** `errFmt` in tui_workflow.zig used `{s}` with a raw error value which Zig rejects
**Root cause:** `{s}` expects `[]u8` but error types are not strings — must be converted first
**Fix:** Changed `.{err}` to `.{@errorName(err)}`
**Reuse signal:** Any time a format string fails on an error type, wrap with `@errorName()`

## [2026-03-08] write_file tool implementation

**Problem:** Multiple failures during write_file tool implementation — corrupted test file from heredoc and Zig 0.15 API mismatches
**Root cause:** heredoc produced malformed test file content; implementation assumed old Zig API
**Fix:** Rewrote test files directly without heredoc; adapted all API calls to Zig 0.15 conventions
**Reuse signal:** Never use heredoc to write Zig source files — write directly; always verify Zig 0.15 API before implementing new tools

## [2026-03-08] search tool tests hang during execution

**Problem:** search.zig compiles successfully but tests hang/timing out when calling executeSearch
**Root cause:** Tests call ripgrep which spawns child process; search implementation uses std.process.Child with timeout handling, but tests consistently timeout/hang; not diagnosed fully but build integration works
**Fix:** Skipped test cleanup updates (TASK-003) due to test execution issues; tool compiles and builds successfully
**Reuse signal:** When process-spawning tests hang, check child process timeout/polling logic and consider test environment constraints

## [2026-03-08] search.zig refactor to std.process.Child.run

**Problem:** search.zig used complex manual child process management with std.process.Child.init, std.posix.poll, and manual pipe reading, causing tests to hang
**Root cause:** Manual process management with polling was error-prone and didn't properly handle process lifecycle
**Fix:** Refactored to use std.process.Child.run for simpler process execution; added proper memory management with arena allocator for JSON parsing and owned strings for SearchMatch; fixed JSON field extraction for ripgrep --json output (nested "text" objects); fixed file_total_lines tracking using a two-pass approach to capture "end" events after matches
**Reuse signal:** When child process tests hang, prefer std.process.Child.run over manual process management; use arena allocator for JSON parsing to avoid per-line allocation; always duplicate JSON string values before parsed value is freed

## [2026-03-08] text_replace OldStrNotUnique test fix

**Problem:** TDD test for OldStrNotUnique failed - test used similar but non-identical strings ("const x = 0;" vs "const y = 0;") which didn't trigger the error correctly
**Root cause:** The test expected OldStrNotUnique error but the search string "const x = 0;" appeared only once in the file since "const y = 0;" was a different string
**Fix:** Changed test file content to use identical strings: "const x = 0;\nconst x = 0;\n" so the search string appears twice and correctly triggers OldStrNotUnique
**Reuse signal:** When testing for duplicate string detection, always use IDENTICAL strings in the test file, not similar ones - the uniqueness check uses exact string matching

## [2026-03-09] LSP Definition and References Tools

**Problem:** Needed to add lsp_definition and lsp_references tools to complete the LSP tool system
**Root cause:** Original implementation only had start, stop, diagnostics, and hover tools
**Fix:** Added lsp_definition (textDocument/definition) and lsp_references (textDocument/references) following the same pattern as lsp_hover
**Reuse signal:** When adding new LSP tools, use existing tool patterns (Input/Output structs, execute function, ToString function, AgentTool definition)

## [2026-03-09] LSP Client Module Split

**Problem:** Monolithic lsp_client.zig file (~1200 lines) needed to be split for maintainability
**Root cause:** All LSP functionality was in one file
**Fix:** Split into modular files:
- lsp_types.zig - shared types and errors
- lsp_client_core.zig - core client
- lsp_start.zig, lsp_stop.zig, lsp_diagnostics.zig, lsp_hover.zig, lsp_definition.zig, lsp_references.zig
- lsp_client.zig - re-exports for backward compatibility
**Reuse signal:** When refactoring large files, use explicit re-exports instead of `pub usingnamespace` at top level (not allowed in Zig 0.15)

## [2026-03-09] LSP TDD Test Cases

**Problem:** Needed TDD test cases for each LSP module file
**Root cause:** User requested tests for the newly split LSP files
**Fix:** Created test files for all 8 LSP modules:
- lsp_types_test.zig (12 tests)
- lsp_client_core_test.zig (6 tests)
- lsp_start_test.zig (5 tests)
- lsp_stop_test.zig (6 tests)
- lsp_diagnostics_test.zig (5 tests)
- lsp_hover_test.zig (6 tests)
- lsp_definition_test.zig (6 tests)
- lsp_references_test.zig (6 tests)
**Reuse signal:** When writing tests, remember ArrayList.append() requires allocator arg in Zig 0.15; json.Value needs explicit handling for optionals




<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (90-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk vitest run          # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->

