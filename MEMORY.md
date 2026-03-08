
## 2026-03-08 save_message.run refactoring

**Problem:** Pre-existing bug in tui_workflow.zig line 199 - errFmt used `{s}` format string for error type which doesn't work in Zig
**Root cause:** The format string `{s}` expects a string type, but `@errorName(err)` returns `[]u8` which needs to be wrapped in a tuple
**Fix:** Changed from `.{err}` to `.{@errorName(err)}`
**Reuse signal:** When encountering "invalid format string" errors for error types, use `@errorName()` to convert to string first
