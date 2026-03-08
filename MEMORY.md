
## 2026-03-08 save_message.run refactoring

**Problem:** Pre-existing bug in tui_workflow.zig line 199 - errFmt used `{s}` format string for error type which doesn't work in Zig
**Root cause:** The format string `{s}` expects a string type, but `@errorName(err)` returns `[]u8` which needs to be wrapped in a tuple
**Fix:** Changed from `.{err}` to `.{@errorName(err)}`
**Reuse signal:** When encountering "invalid format string" errors for error types, use `@errorName()` to convert to string first

- [2026-03-08] No issues encountered.

## 2026-03-08 read_file tool integration

**Problem:** Pre-existing bugs in read_file.zig - ArrayList API incompatible with Zig 0.15
**Root cause:** Zig 0.15 changed ArrayList API: .init → .empty, .appendSlice requires allocator, .deinit requires allocator, .toOwnedSlice requires allocator
**Fix:** Changed all ArrayList calls to use new API: .empty, .appendSlice(allocator, slice), .deinit(allocator), .toOwnedSlice(allocator)
**Reuse signal:** When migrating to Zig 0.15+, check all ArrayList usages for these API changes
