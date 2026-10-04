# MCP stdio — Task Ledger

Branch: `worktree/mcp-stdio`
Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/mcp-stdio`
Plan: `docs/superpowers/plans/2026-08-27-mcp-stdio.md`

## Tasks

- [x] **Task 1** — `mcp_stdio.zig`: ONE file with framing + StdioClient + StdioRegistry + 17 inline tests (14 behavioural + 3 FD-leak regression tests)
- [x] **Task 2** — Extend `McpServerConfig` to carry both transports (Config.zig)
- [x] **Task 3** — Wire stdio client into `handle_mcp_tool.zig` + tool list fetch
- [ ] **Task 4** — `mcp-hello-world` binary (using existing McpServer framework)
- [ ] **Task 5** — Functional test: end-to-end agent calls `say_hello`
- [ ] **Task 6** — Frontend: extend `McpServer` type, modal, serializer
- [ ] **Task 7** — `PABRIK.md` changelog + final verification

## Pre-flight findings (Zig 0.16 API adjustments vs plan)

- ❌ `std.Thread.Mutex` → ✅ `std.atomic.Mutex` + `tryLock`/`unlock` (see `src/ai_workflow/tui/agentic_loop/stream_snapshot.zig:35-42`)
- ❌ `std.process.Child.cwd` doesn't exist in 0.16 → skip `cwd` for v1 (document as known limitation)
- ❌ `std.Io.File.reader(&buf)` / `writer(&buf)` slice-buf form → ✅ `std.fs.File.read(&buf)` + `writeAll(msg)` direct methods (matches existing `lsp*.zig` pattern)
- ✅ `std.process.Child.init(argv, allocator)` + `.stdin_behavior = .Pipe` etc. works identically
- ✅ `child.stdin.?` optional unwrap (shell.zig:485 pattern)
- ✅ `std.heap.page_allocator` for process-global singletons (matches `stream_snapshot.zig:63`)
