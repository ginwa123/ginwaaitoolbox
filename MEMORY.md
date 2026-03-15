## Language & Environment Facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- [zig@0.15] **CRITICAL: Never return stack-allocated slices from functions** — stack memory is invalidated after function returns, causing corruption. Always use `allocator.alloc()` or `allocator.dupe()` for returned slices.
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
- [zig@0.15] `allocator.dupeZ()` returns `[:0]u8` but argv needs `[*:0]const u8` — use stack buffer approach
- [zig@0.15] `std.posix.Sigaction` is not a struct literal type — initialize fields individually
- [zig@0.15] `std.posix.sigaction()` returns `void`, not error union — no `catch` needed
- [zig@0.15] `std.posix.execveZ()` returns error union directly — use `catch` without `|err|`
- [zig@0.15] `std.posix.sigemptyset()` returns `sigset_t` for signal mask initialization

