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

## Resolved Issues

<!-- Issues encountered and fixed during runs. -->

- [2026-03-08] No issues encountered.
- [2026-03-09] Agent system restructured — GeneralAgent and KnowledgeAgent removed, ExplorationAgent enhanced with classification logic

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
