# AGENT.md — Project Summary

> **Last Updated:** 2025-03-20
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

## Project Overview

**Name:** nalarcore
**Language:** Zig 0.15.2
**Type:** AI agentic coding toolbox with HTTP server + TUI interfaces

## Build System

```bash
zig build              # Build all targets
zig build run          # Run HTTP server
zig build run:tui      # Run TUI app
zig build test         # Run tests
zig build install:linux:system   # Install to /usr/local/bin (requires sudo)
```

**Deps:** httpz, libsqlite3, libssl, libcrypto

## Project Structure

```
src/
├── main.zig              # HTTP server entry point
├── root.zig              # nalarcore module exports
├── helpers/              # Utility helpers
├── apps/
│   ├── tui/              # Terminal UI app (Zig)
│   │   ├── main.zig
│   │   ├── commands/     # Command handlers
│   │   ├── display/      # Response rendering
│   │   ├── input/       # Keyboard input
│   │   ├── network/     # SSE, messaging, streaming
│   │   └── terminal/    # Raw mode, backend
│   └── Desktop/          # Desktop app (C#/Uno)
│       ├── Desktop/
│       │   ├── MainPage.cs         # Main page + workspace sidebar
│       │   ├── ViewModels/
│       │   │   └── WorkspaceStore.cs  # Workspace persistence (session_dir)
│       │   └── Views/
│       │       ├── SessionsView.cs     # Chat interface
│       │       └── WorkspaceBrowserDialog.cs  # Folder picker
├── modules/
│   ├── agent/            # AI agent core
│   │   └── tools/        # 20+ tools (bash, read_file, write_file, etc.)
│   ├── config/           # Configuration management
│   ├── databases/        # SQLite + migrations
│   ├── http/             # HTTP client
│   ├── http_server/      # HTTP routing, SSE, panic broadcast
│   ├── ipc/              # Inter-process communication
│   ├── logger/           # Structured logging + panic to file
│   └── session/          # Session state + cancellation registry
└── ai_workflow/          # AI workflow orchestration
    └── tui/              # TUI-specific workflows (tool handlers)
```

## Key Modules

### Agent (`src/modules/agent/`)
- **Tools:** bash, read_file, write_file, text_replace, search, list_skills, get_skill, remove_skill, change_agent, loop_detector, helper, list_agents, get_agent, spawn_sub_agent, LSP tools
- **Test coverage:** Unit + integration tests for all tools

### HTTP Server (`src/modules/http_server/`)
- HTTP routing with httpz
- Server-Sent Events (SSE) streaming
- Panic broadcasting to connected clients

### TUI (`src/apps/tui/`)
- Terminal UI with raw mode
- SSE connection to HTTP server
- Display rendering, input handling
- Command system

### Logger (`src/modules/logger/`)
- Structured logging
- Panic logging to file

### Session (`src/modules/session/`)
- Session state tracking
- Cancellation registry

## Important Conventions

- `const tree1 = @import("nalarcore");` — module imports
- **Naming:** snake_case for variables and functions, PascalCase for structs/types
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions
- **Memory management:** Prefer `ArenaAllocator` over manual `free()` calls — simpler, less error-prone, but for testing use `std.testing.allocator`

## Related

- [MEMORY.md](./MEMORY.md) — AI learning & mistakes
- [.nalar/plans/](.nalar/plans/) — Design documents
- [docs/superpowers/](docs/superpowers/) — Skills


## Testing

Use the TUI CLI to test AI agentic behavior:

```bash
./zig-out/bin/nalar-dev-tui --port 8080 -q "your query"
```

**Options:**
- `-q "query"` — Send a single query to the LLM, then exit
- `-c` — Continue the last session
- `-c <session_id>` — Continue a specific session

**Important:**
- Never kill port 8081 or its associated process
- Port 8081 is reserved for testing
- Never kill process name nalar, your process to testing is nalar-dev

