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
│   └── tui/              # Terminal UI app
│       ├── main.zig
│       ├── commands/     # Command handlers
│       ├── display/      # Response rendering
│       ├── input/       # Keyboard input
│       ├── network/     # SSE, messaging, streaming
│       └── terminal/    # Raw mode, backend
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
- snake_case for variables, PascalCase for structs
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions

## Related

- [MEMORY.md](./MEMORY.md) — AI learning & mistakes
- [.nalar/plans/](.nalar/plans/) — Design documents
- [docs/superpowers/](docs/superpowers/) — Skills



## to testing ai agentic use cli
dont ever kill port 8081, or the process

you allowed to use port 8081 for testing
 nalar-tui --port 8080 -q "your query" -c
 -c will be continue last session
 -q will be query to llm

