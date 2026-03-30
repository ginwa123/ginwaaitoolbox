# AGENT.md — Project Summary

> **Last Updated:** 2025-03-27
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

## Project Overview

**Name:** nalarcore
**Language:** Zig 0.15.2
**Type:** AI agentic coding toolbox with HTTP server + TUI interfaces

## Research Rule

> **MANDATORY: Use Context7 for library/module research!**

When needing **latest documentation, examples, or best practices** for any library or technology:
1. `mcp_context7_resolve-library-id` — Find the library ID (e.g., `/mongodb/mongoose`)
2. `mcp_context7_query-docs` — Query specific questions with examples

**Use Cases:**
- How to use a library API correctly
- Latest patterns/best practices
- Real code examples with proper syntax
- Version-specific documentation

**Never guess library APIs — research them first! If Context7 lacks results, use web search.**

## Build System

```bash
zig build              # Build all targets
zig build run          # Run HTTP server (port 8080)
zig build run:tui      # Run TUI app
zig build test         # Run tests
```

**Deps:** httpz, libsqlite3, libssl, libcrypto

## Project Structure

```
src/
├── main.zig              # HTTP server entry point (402 lines)
├── root.zig              # Module exports
├── helpers/              # XML parsing, utilities
├── modules/
│   ├── agent/            # AI agent core + 20+ tools
│   ├── config/           # LLM configuration
│   ├── databases/        # SQLite + migrations
│   ├── http/             # HTTP client
│   ├── http_server/      # HTTP routing, SSE, panic broadcast
│   ├── logger/           # Structured logging + panic to file
│   ├── session/          # Session state + cancellation
│   └── cronjob/          # Background job scheduler
├── ai_workflow/tui/      # TUI workflows + tool handlers
└── apps/tui/             # Terminal UI app
```

## Key Modules

### HTTP Server (`src/main.zig`)
- REST API on port 8080 (httpz)
- SSE streaming for real-time updates
- Routes: `/api/command`, `/api/stream/:session_id`, `/api/session/*`
- Panic broadcasting to connected TUI clients

### Agent (`src/modules/agent/`)
- **Tools:** bash, read_file, write_file, text_replace, search, glob, LSP tools
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, change_agent, spawn_sub_agent
- **MCP:** LSP definition/references/hover/workspace_symbol/document_symbol

### AI Workflow (`src/ai_workflow/tui/`)
- `workflow.zig` — Main TUI workflow orchestration
- `session_db.zig` — Session persistence with cursor-based pagination
- `http_handlers.zig` — HTTP request handlers
- `/api/session` — Cursor-based pagination: `?limit=20&cursor=<timestamp>` → `{sessions, has_more, next_cursor}`
- 30+ tool handlers (bash, file ops, search, skills, agents, LSP)

### Logger (`src/modules/logger/`)
- Structured logging with timestamps
- Panic logging to `/tmp/agentic_coding.log`
- Color support (file mode)

### Session (`src/modules/session/`)
- Per-session state tracking
- Cancellation registry (cancel active sessions)
- Session monitor (exit when no active sessions)

## Important Conventions

- **Max lines per file:** 400 lines — split larger files
- `const tree1 = @import("nalarcore");` — module imports
- **Naming:** snake_case (vars/functions), PascalCase (structs/types)
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions
- **Memory:** Prefer `ArenaAllocator` over manual `free()`

## JSON Conventions

- **JSON keys:** Always `snake_case` (e.g., `session_id`, `created_at`, `is_input`)
- This applies to all HTTP API responses and internal JSON builders

## Data Locations

| Data | Path |
|------|------|
| Database | `~/.config/nalar/agent.db` |
| Log file | `/tmp/agentic_coding.log` |
| Panic log | Same as log file |

## Related

- [MEMORY.md](./MEMORY.md) — AI learning & mistakes
- [.nalar/plans/](.nalar/plans/) — Design documents
- [docs/superpowers/](docs/superpowers/) — Skills


## Skills and learning

- always use skills frontend-design
- always use skills zig-expert


## Dev Test

for testing use this command always
    you can use -q to use cli

- ./zig-out/bin/nalar-dev-tui --port 8082 --process nalar-dev


## Unit testing
### Zig
- use `zig build test` to run all tests
- put the test in test_runner.zig and import it in root.zig
- the test should be in the same folder as the file it's testing and end with `_test.zig`


# Mandatory
- Dont ever kill the process port 8081 !!!
