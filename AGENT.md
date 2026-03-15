# AGENT.md — Project Summary

## Project Overview

**Name:** nalarcore (also known as ginwaaitoolbox)  
**Language:** Zig 0.15.2  
**Type:** AI agentic coding toolbox with multiple interfaces  

---

## What This Project Does

Nalarcore is an AI-powered agentic coding system written in Zig. It provides multiple ways to interact with an AI agent:

1. **HTTP Server** — Main application exposing AI capabilities via HTTP with SSE (Server-Sent Events) for real-time streaming
2. **TUI (Terminal UI)** — Interactive terminal interface for chatting with the AI
3. **CLI** — Command-line interface for scripting and automation

---

## Build System

- **Build Tool:** Zig's native build system (build.zig)
- **Package Manager:** Zig 0.15+ (build.zig.zon)
- **Minimum Zig Version:** 0.15.2

### Build Targets

```bash
zig build              # Build main executable (nalarcore)
zig build run          # Run the HTTP server
zig build run:tui      # Run the TUI
zig build run:cli      # Run the CLI
```

### Dependencies

| Dependency | Purpose |
|------------|---------|
| http.zig | HTTP client/server |
| libsqlite3 | Database storage |
| libssl | TLS/SSL support |
| libcrypto | Cryptographic operations |

---

## Project Structure

```
ginwaaitoolbox/
├── src/
│   ├── main.zig           # Main entry point
│   ├── root.zig           # Library root & module exports
│   ├── ai_workflow/       # AI workflow orchestration
│   ├── apps/
│   │   ├── cli/           # CLI application
│   │   ├── kerjabot/      # KerjaBot integration
│   │   └── tui/           # Terminal UI application
│   └── modules/
│       ├── agent/         # AI agent implementation
│       │   └── tools/     # Agent tools (bash, read_file, write_file, etc.)
│       ├── config/        # Configuration management
│       ├── databases/     # SQLite database & migrations
│       ├── http/          # HTTP client
│       ├── http_server/   # HTTP server with SSE
│       ├── ipc/           # Inter-process communication
│       ├── logger/        # Logging system
│       └── session/       # Session management
├── docs/
│   ├── plans/             # Design documents
│   └── superpowers/      # Skill documentation
├── build.zig             # Build configuration
├── build.zig.zon         # Package manifest
├── MEMORY.md             # AI learning & mistake tracking
└── AGENT.md              # This file
```

---

## Key Modules

### Agent Module (`src/modules/agent/`)
Core AI agent functionality with tools:
- **bash** — Execute shell commands
- **read_file** — Read files from disk
- **write_file** — Write/create files
- **text_replace** — Edit existing files
- **search** — Search for patterns in code
- **list_skills** — List available skills
- **get_skill** — Load skill content
- **remove_skill** — Unload skills
- **change_agent** — Modify agent behavior
- **lsp_client** — LSP for code intelligence
- **loop_detector** — Detect repetitive behavior

### HTTP Server (`src/modules/http_server/`)
- HTTP server with routing
- SSE (Server-Sent Events) for streaming responses
- Panic broadcasting to connected clients

### Session Management (`src/modules/session/`)
- Session state tracking
- Session monitoring

### Logger (`src/modules/logger/`)
- Structured logging system
- Panic logging to file

---

## Important Conventions

### Module Imports
```zig
const tree1 = @import("nalarcore");
const agent = tree1.agent;
const http_server = tree1.http_server;
```

### Key Files
- `src/root.zig` — Main library entry, exports all modules
- `src/main.zig` — Application entry point
- `build.zig` — Build configuration for all executables

### Database
- SQLite for persistent storage
- Migrations in `src/modules/databases/sqlite/migrations.zig`

---

## Known Technical Details

- **Zig 0.15 API Notes** (from MEMORY.md):
  - `ArrayList.empty` replaces `ArrayList.init`
  - `ArrayList.deinit(allocator)` — allocator required
  - `std.fs.File.createFile` for file creation
  - Format strings require explicit type conversion

---

## Related Documentation

- [MEMORY.md](./MEMORY.md) — AI learning system, past mistakes and solutions
- [docs/plans/](docs/plans/) — Design documents
- [docs/superpowers/](docs/superpowers/) — Skill definitions
