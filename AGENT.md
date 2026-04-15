# AGENT.md — Project Summary

> **Last Updated:** 2025-04-11
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

# Mandatory
- Always update this file AGENT.md to match actual project or codebase

## Project Overview

**Name:** nalarcore
**Executable:** `nalar`
**Language:** Zig 0.15.2
**Type:** AI agentic coding toolbox with HTTP server + TUI interfaces

## Research Rule

> **MANDATORY: Use Context7 for library/module research!**

When needing **latest documentation, examples, or best practices** for any library or technology:
1. `mcp_context7_resolve-library-id` — Find the library ID (e.g., `/mongodb/mongoose`)
2. `mcp_context7_query-docs` — Query specific questions with examples

**Never guess library APIs — research them first! If Context7 lacks results, use web search.**

## Build System

```bash
zig build              # Build all targets
zig build run          # Run HTTP server (port 8080)
zig build run:tui      # Run TUI app
zig build test         # Run tests
```

**Deps:** httpz, libsqlite3, libssl, libcrypto

## Module Imports

```zig
const nalarcore = @import("nalarcore");  // Main module
const agent = nalarcore.agent;
const ai_workflow = nalarcore.ai_workflow;
const http_server = nalarcore.http_server;
const logger = nalarcore.logger;
// etc.
```

## Project Structure

```
src/
├── main.zig                      # HTTP server entry point
├── root.zig                       # Module exports + panic handler
├── test_main.zig                  # Test entry
├── helpers/
│   └── mod.zig                    # XML parsing utilities
├── modules/
│   ├── agent/                     # AI agent core
│   │   ├── agent.zig              # Agent orchestration
│   │   ├── prompt.zig             # Prompt building
│   │   ├── prompts/               # Modular prompts
│   │   │   ├── core.zig           # Universal rules
│   │   │   ├── agent.zig          # Main directive
│   │   │   ├── parallel.zig       # Parallel work rules
│   │   │   ├── research.zig       # Research rules
│   │   │   ├── specialized.zig    # change_agent rules
│   │   │   ├── subagent.zig       # Sub-agent brief
│   │   │   ├── execution.zig      # Classification/execution
│   │   │   ├── memory.zig         # Tasks, AGENTS.md, git
│   │   │   └── special.zig         # CompactionAgent, DestroyIdea
│   │   ├── tools/                 # Agent tools (35+)
│   │   │   ├── bash.zig           # Shell execution
│   │   │   ├── read_file.zig      # File reading
│   │   │   ├── write_file.zig     # File writing
│   │   │   ├── text_replace.zig   # File editing
│   │   │   ├── search.zig         # Ripgrep search
│   │   │   ├── glob.zig           # File discovery
│   │   │   ├── web_search.zig     # Web browser (agent-browser CLI)
│   │   │   ├── lsp_*.zig          # LSP tools (definition, hover, refs, etc.)
│   │   │   ├── skills.zig         # Skills management
│   │   │   ├── agents.zig         # Dynamic agents
│   │   │   ├── spawn_sub_agent.zig # Parallel agents
│   │   │   ├── change_agent.zig   # Switch agent persona
│   │   │   ├── set_agent_properties.zig
│   │   │   ├── list_skills.zig    # List available skills
│   │   │   ├── get_skill.zig      # Load skill content
│   │   │   ├── remove_skill.zig   # Delete skill file from .nalar/skills/
│   │   │   ├── add_skill.zig      # Create new skill file
│   │   │   ├── list_agents.zig    # List available agents
│   │   │   ├── add_agent.zig      # Create new agent file
│   │   │   ├── remove_agent.zig   # Delete agent file from .nalar/agents/
│   │   │   ├── schemas.zig        # Tool schemas
│   │   │   ├── loop_detector.zig   # Prevent infinite loops
│   │   │   └── bash_selfkill.zig  # Block self-kill commands
│   │   └── mcp/                    # MCP protocol support
│   ├── config/                     # LLM configuration
│   ├── databases/
│   │   ├── database.zig            # DB abstraction
│   │   └── sqlite/                 # SQLite implementation
│   │       ├── sqlite.zig
│   │       └── migrations.zig
│   ├── http/                       # HTTP client
│   ├── http_server/                # HTTP server
│   │   ├── http_server.zig         # Router + handlers
│   │   └── sse_manager.zig         # SSE streaming
│   ├── ipc/                        # IPC (XML format)
│   ├── logger/                     # Structured logging
│   │   ├── logger.zig
│   │   ├── formatter.zig
│   │   ├── request_id.zig
│   │   └── timing.zig
│   ├── session/                    # Session management
│   │   ├── cancellation_registry.zig
│   │   ├── activity_registry.zig
│   │   └── session_monitor.zig
│   └── cronjob/                    # Background scheduler
├── ai_workflow/tui/                # TUI workflow orchestration
│   ├── workflow.zig                # Main workflow
│   ├── http_handlers.zig           # REST handlers
│   ├── session_db.zig              # Session persistence
│   ├── session_table.zig            # Session table model
│   ├── session_helpers.zig         # Session helpers
│   ├── build_*.zig                # Prompt builders
│   ├── handle_*.zig               # Tool handlers
│   └── save_*.zig                 # Persistence
└── apps/tui/                       # Terminal UI app
    ├── main.zig                    # TUI entry
    ├── network/                    # SSE + HTTP client
    │   ├── streaming.zig           # SSE stream parsing (uses tool_parser)
    │   └── ...
    ├── display/                    # Response rendering
    │   ├── response.zig           # XML content extraction
    │   ├── tool_renderer.zig       # Terminal UI renderer for tool calls
    │   └── tool_results.zig       # Tool-specific display functions
    ├── helpers/
    │   ├── xml_entities.zig       # XML entity decoder
    │   ├── tool_parser.zig        # Tool call XML parser (mirrors frontend)
    │   └── utils.zig
    ├── input/                      # Keyboard input
    └── terminal/                  # Terminal backend
```

## Key Tool Conventions

### text_replace Tool
Just use it - read the file first to see its current content.

### glob Tool
- Uses `/usr/sbin/fd` with `--glob` pattern matching
- **Truncation Detection:** When results exceed `max_results`, includes `<truncated>` with count
- Returns: `<f>path</f>` for each match, plus `<truncated>{n} files truncated` if limited
- Supports `offset` + `max_results` for pagination

### web_search Tool
- Uses `agent-browser` CLI
- Actions: `open`, `snapshot`, `get`, `click`, `fill`, `press`, `scroll`
- Parameters: `query`, `url`, `action`, `selector`, `args`

## HTTP API Routes

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/command` | Generic command handler |
| GET | `/api/stream/:session_id` | SSE real-time events |
| POST | `/api/session` | Create session |
| GET | `/api/session` | List sessions (cursor pagination) |
| GET | `/api/session/:session_id` | Get session |
| GET | `/api/session/:session_id/messages` | Get messages |
| GET | `/api/session/exists/:session_id` | Check exists |
| GET | `/api/session/latest` | Get latest by directory |
| POST | `/api/session/:session_id/cancel` | Cancel session |
| POST | `/api/session/:session_id/compact` | Trigger compaction |
| DELETE | `/api/session/:session_id/queue/message?message=` | Delete queued message |
| GET | `/api/session/:session_id/queue/messages` | Get queued messages (clears queue) |
| POST | `/api/llm/run` | Run LLM workflow |
| GET | `/api/ping/:session_id` | Health check |

## Data Locations

| Data | Path |
|------|------|
| Database | `~/.config/nalar/agent.db` |
| Log file | `/tmp/agentic_coding.log` |
| Panic log | Same as log file |

## Important Conventions

- **Max lines per file:** 400 lines — split larger files
- **Naming:** snake_case (vars/functions), PascalCase (structs/types)
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions
- **Memory:** Prefer `ArenaAllocator` over manual `free()`
- **JSON keys:** Always `snake_case` (e.g., `session_id`, `created_at`)
- **ActivityRegistry:** Uses TWO separate concepts:
  - **Activity count** (`mark_running`/`mark_idle`) — tracks nested processing
  - **Stopped flag** (`mark_stopped`/`is_stopped`) — persistent flag that blocks `is_running()` until re-registered
  - **Critical:** `is_running()` checks stopped flag first, then activity count

## MCP Tool Handling

**Key files:**
- `src/ai_workflow/tui/handle_mcp_tool.zig` — Executes MCP tool calls
- `src/ai_workflow/tui/build_messages_tools_mcp_for_agent_prompt.zig` — Fetches MCP tools from servers

**Important fixes applied:**
1. **SSE Response Parsing:** MCP servers may return `text/event-stream` responses with `data:` prefix. The handler now strips this prefix before JSON parsing.
2. **Memory Safety:** When extracting strings from parsed JSON, the handler copies them to the parent allocator to avoid use-after-free when the parsed tree is deallocated.
3. **Use `std.heap.c_allocator` for JSON parsing** — Avoids nested arena alignment issues.

**JSON Parse Error Prevention:**
- Always use `std.heap.c_allocator` instead of arenas for `json.parseFromSlice`
- Strip SSE framing before parsing if server may return event-stream responses
- Copy extracted strings if they need to outlive the parsed value

## Logging Conventions

**Desktop Bun Frontend (`src/apps/desktop-bun/`):**
- Use `logger.ts` — Never use `console.log/warn/error`
- Import: `import { log } from '../utils/logger';`
- Usage: `log.info('msg')`, `log.warn('msg')`, `log.error('msg')`

**Zig Backend:** Use `root_mod.logger.getGlobal()` for custom logger
```zig
const logger = root_mod.logger;

// Get global logger instance
const log = logger.getGlobal();

// Use formatted methods (catch {} to ignore errors)
log.?.infoFmt("message: {s}", .{arg}) catch {};
log.?.warnFmt("warning: {}", .{err}) catch {};
log.?.errFmt("error: {s}", .{@errorName(err)}) catch {};
log.?.debugFmt("debug: {}", .{value}) catch {};
log.?.traceFmt("trace: {}", .{value}) catch {};

// Simple methods (also need error handling)
log.?.info("simple message") catch {};
log.?.warn("warning message") catch {};
log.?.err("error message") catch {};
```

**Note:** For void functions, use `catch {}` to silently ignore logging errors.

## Dev Test

for testing use this command always
    you can use -q to use cli

- ./zig-out/bin/nalar-dev-tui --port 8082 --process nalar-dev

## Unit Testing

### Zig
- Use `zig build test` to run all tests
- Tests go in `_test.zig` files next to source
- Import test runners in `root.zig`

### Desktop Bun (Vitest)
- Run: `bun test src/apps/desktop-bun/src/.../<filename>.test.tsx`
- Uses source-code verification approach (no DOM rendering)
- Test files: `*.test.tsx` alongside source files
- Pattern: Read source file → regex match expected patterns
- Example test files:
  - `src/mainview/components/Sidebar.test.tsx`
  - `src/mainview/pages/MessageRow.test.tsx`

---

## ⚡ Self-Review Checklist (AFTER EVERY TASK)

1. ✅ TASK COMPLETED — Did I actually solve the user's request?
2. 🔍 PROCESS AUDIT
   - [ ] Loaded relevant skills BEFORE starting?
   - [ ] Used proper tools (read_file vs bash cat)?
   - [ ] Researched unknown APIs instead of guessing?
   - [ ] Spawned sub-agents for parallel work?
   - [ ] Delegated specialized work via change_agent?
3. 📝 KNOWLEDGE CAPTURE — What did I learn?
4. 🔄 IMPROVEMENT — What would I do differently?

---

# Mandatory
- Dont ever kill the process port 8081 !!!
