# AGENT.md — Project Summary

> **Last Updated:** 2025-04-01
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

# Mandatory
- Always update this file AGENT.md make sure its match with actual project or codebase

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
├── main.zig              # HTTP server entry point (257 lines)
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
- **Prompts (`prompts/`):** Modular prompts by purpose — core, agent, research, specialized, subagent, execution, memory, special
- **Tools:** bash, read_file, write_file, text_replace, search, glob, **tree_dir**, LSP tools
- **write_file:** Tool with `create_with_dir` option for automatic directory creation
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, change_agent, spawn_sub_agent
- **MCP:** LSP definition/references/hover/workspace_symbol/document_symbol
- **Self-Kill Protection:** `bash_selfkill.zig` — blocks dangerous commands (kill, killall, pkill, exit) that target self PID

### AI Workflow (`src/ai_workflow/tui/`)
- `workflow.zig` — Main TUI workflow orchestration
- `session_db.zig` — Session persistence with cursor-based pagination
- `http_handlers.zig` — HTTP request handlers (all TUI operations via REST)
- `/api/session` — Cursor-based pagination: `?limit=20&cursor=<timestamp>` → `{sessions, has_more, next_cursor}`
- 30+ tool handlers (bash, file ops, search, skills, agents, LSP)

### HTTP API Routes (`HttpRoutes.setup` in `main.zig`)
| Method | Endpoint | Purpose |
|--------|----------|--------|
| POST | `/api/command` | Generic command handler |
| GET | `/api/stream/:session_id` | SSE real-time events |
| POST | `/api/session` | Create session |
| GET | `/api/session` | List sessions |
| GET | `/api/session/:session_id` | Get session |
| GET | `/api/session/:session_id/messages` | Get messages |
| GET | `/api/session/exists/:session_id` | Check session exists |
| GET | `/api/session/latest` | Get latest by directory |
| POST | `/api/session/:session_id/cancel` | Cancel session |
| POST | `/api/session/:session_id/compact` | Trigger compaction |
| POST | `/api/llm/run` | Run LLM workflow |
| GET | `/api/ping/:session_id` | Connection health check |

### Logger (`src/modules/logger/`)
- Structured logging with timestamps
- Panic logging to `/tmp/agentic_coding.log`
- Color support (file mode)

### Session (`src/modules/session/`)
- Per-session state tracking
- Cancellation registry (cancel active sessions)
- Session monitor (exit when no active sessions)

### Desktop App (`src/apps/desktop-bun/`)
- Bun + SolidJS desktop application using webview-bun
- Connects to Zig HTTP server via REST API
- **Create session:** `POST /api/session` — creates new session, navigates to it
- **List sessions:** `GET /api/session` — infinite scroll with cursor pagination
- **Session chat:** `GET /api/session/:session_id/messages` — loads messages with infinite scroll
- **Run workflow:** `POST /api/llm/run` — sends message to agent
- **SSE streaming:** `GET /api/stream/:session_id` — real-time updates via SSE (`sseClient.ts`)
- **cwd_session:** Current working directory sent via RPC from Bun to webview, then to Zig backend
- Port passed via RPC from Bun to webview

**RPC Schema (`src/shared/rpc.ts`):**
- `getCwd`: Returns Bun's current working directory (used by webview to send cwd_session)

**SSE Client (`src/mainview/utils/sseClient.ts`):**
- Connects to `/api/stream/:session_id` for real-time updates
- Event types: `message`, `tool_result`, `status`, `error`, `done`, `step`, `ping`
- Auto-reconnect on connection loss

**Run desktop app:**
```bash
cd src/apps/desktop-bun && bun run src/bun/index.ts
```

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


## Prompt Structure

Prompts split by purpose in `src/modules/agent/prompts/`:
- `core.zig` — Universal rules, auto-fix
- `agent.zig` — Main orchestration directive
- `research.zig` — Auto-research, tools
- `specialized.zig` — change_agent rules
- `subagent.zig` — Sub-agent brief
- `execution.zig` — Classification, execution, escalation
- `memory.zig` — Tasks, AGENTS.md, git
- `special.zig` — CompactionAgent, DestroyIdea

## Skills — Force Multipliers

**Skills are specialized knowledge packs that dramatically improve effectiveness.**
**ALWAYS load relevant skills BEFORE starting any task.**

### Quick Commands
- `list_skills` — **Browse all available skills** — use this to discover capabilities!
- `get_skill("skill_name")` — **Load a skill** — use for specialized work

### ⚡ How to Use Skills
1. **Don't know what skills exist?** → `list_skills` to browse them all
2. **Need guidance for a task?** → `get_skill("relevant_skill")` to load it
3. **Doing unfamiliar work?** → `list_skills` first, then load what fits

**Rule:** Let the LLM discover and choose skills with `list_skills`. Don't hardcode skill names.

## Agent Prompt — change_agent Rule

**CRITICAL:** The main Agent MUST always use `change_agent` when:
- Saying "you" or "I" in any response
- Performing specialized work (Zig, frontend, code review, etc.)

Never do specialized work directly — delegate to specialized agents:
- Zig code → `change_agent("zig-expert")`
- Frontend/UI → `change_agent("frontend-engineer")`
- Code review → `change_agent("code-reviewer")`
- Memory/security → `change_agent("memory-security-engineer")`
- Skill creation → `change_agent("skill-creator")`


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
