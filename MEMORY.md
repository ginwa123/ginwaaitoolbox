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
