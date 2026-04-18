# NALAR.md — Project Summary

> **Last Updated:** 2025-04-18
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

# Mandatory
- Always update this file NALAR.md to match actual project or codebase

## Project Overview

**Name:** nalarcore
**Executables:** `nalar` (server), `nalar-tui` (TUI), `nalar-dev`/`nalar-dev-tui` (debug builds)
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
zig build test         # Run all tests

# Dev builds (debug symbols)
zig build install:dev:linux:system   # Build nalar-dev
zig build install:dev:tui:linux:system # Build nalar-dev-tui

# Platform builds
zig build install:linux:system      # Linux x86_64 → /usr/local/bin
zig build install:windows            # Windows x86_64
zig build install:macos              # macOS x86_64
zig build install:macos-arm          # macOS aarch64
```

**Deps:** httpz, libsqlite3, libssl, libcrypto

## Module Imports

```zig
const nalarcore = @import("nalarcore");  // Main module
const agent = nalarcore.agent;
const sqlite = nalarcore.sqlite;
const logger = nalarcore.logger;
// etc.
```

## Project Structure

```
src/
├── main.zig                           # HTTP server entry point
├── root.zig                          # Module exports + panic handler
├── helpers/
│   ├── mod.zig                        # Helpers re-exports
│   └── xml.zig                        # XML parsing utilities
├── modules/
│   ├── agent/
│   │   ├── Agent.zig                  # Agent orchestration (type)
│   │   ├── LLMModels.zig               # LLM model definitions (type)
│   │   ├── prompts.zig                # Prompt building (namespace)
│   │   ├── prompts/                    # Modular prompts
│   │   │   ├── agent.zig, core.zig, execution.zig, memory.zig,
│   │   │   ├── parallel.zig, research.zig, special.zig,
│   │   │   ├── specialized.zig, subagent.zig, prompts.zig
│   │   ├── mcp/mcp/                   # MCP protocol implementation
│   │   │   ├── mcp_server.zig, mcp_tools.zig, mcp_transport.zig, mcp_types.zig
│   │   └── tools/                     # Agent tools (40+ files)
│   │       ├── bash.zig, read_file.zig, write_file.zig, text_replace.zig
│   │       ├── search.zig, glob.zig, web_search.zig, remove_file.zig
│   │       ├── lsp.zig, lsp_definition.zig, lsp_hover.zig, lsp_references.zig
│   │       ├── lsp_document_symbol.zig, lsp_workspace_symbol.zig, lsp_types.zig
│   │       ├── spawn_sub_agent.zig, change_agent.zig, agents.zig
│   │       ├── skills.zig, get_skill.zig, list_skills.zig, add_skill.zig, remove_skill.zig
│   │       ├── list_agents.zig, add_agent.zig, remove_agent.zig
│   │       ├── set_agent_properties.zig, loop_detector.zig, bash_selfkill.zig
│   │       ├── helper.zig, schemas.zig, tools.zig
│   ├── config/Config.zig              # LLM configuration
│   ├── databases/
│   │   ├── database.zig               # DB abstraction (placeholder)
│   │   └── sqlite/Sqlite.zig          # SQLite implementation
│   ├── http/HttpClient.zig            # HTTP client
│   ├── http_server/HttpServer.zig     # Router + handlers
│   ├── logger/                        # Logger module
│   │   ├── Logger.zig, Formatter.zig, RequestId.zig, Timing.zig
│   ├── session/
│   │   ├── mod.zig                    # Re-exports
│   │   ├── SessionMonitor.zig, SessionRegistry.zig
│   ├── cronjob/
│   │   ├── mod.zig                    # Re-exports
│   │   ├── Cronjob.zig, ProcessChecker.zig
│   └── system_folder/system_folder.zig  # System folder operations
├── ai_workflow/tui/                   # TUI workflow orchestration
│   ├── workflow.zig                   # Main workflow
│   ├── http_handlers/                 # REST API handlers
│   │   ├── mod.zig, cors.zig, llm_run.zig, ping.zig
│   │   ├── session_*.zig              # Session CRUD handlers
│   │   ├── worker_*.zig               # Worker management handlers
│   │   ├── sse_disconnect.zig, stream.zig, system_folder.zig
│   ├── session_table.zig              # Session table model
│   ├── llm_history.zig                # LLM history persistence
│   ├── session_skills.zig             # Session skills management
│   ├── save_agent.zig, build_messages_for_agent_prompt.zig
│   ├── handle_tool.zig, handle_spawn_sub_agent.zig, handle_mcp_tool.zig
│   ├── migration.zig                  # Database migrations
│   ├── transform_llm_history_to_agent_messages.zig
│   ├── on_event_sent.zig, tool_registry.zig, models.zig, startup.zig
└── apps/tui/                          # Terminal UI app
    ├── main.zig                       # TUI entry
    ├── box.zig, keybindings.zig, globals.zig, opts.zig
    ├── cli/opts.zig
    ├── commands/command_defs.zig, handlers.zig
    ├── display/response.zig, tool_results.zig
    ├── helpers/tool_parser.zig, xml_parser.zig, utils.zig
    ├── input.zig, input/escape.zig, input/handle_input.zig
    ├── network/connection.zig, debug.zig, messaging.zig
    │   ├── sse.zig, sse_test.zig, streaming.zig, streaming_test.zig
    └── terminal/backend.zig, raw_mode.zig
```

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

## Key Tool Conventions

### text_replace Tool
Just use it - read the file first to see its current content.

### glob Tool
- **Pure Zig implementation** (like node-glob/Minimatch) - no external dependencies
- **Parameters:**
  - `pattern` - Glob pattern (e.g., "*.zig", "**/*.ts", "{*.js,*.ts}")
  - `path` - Directory to search (default: ".")
  - `max_results` - Maximum results (default: 100, max: 500)
  - `offset` - Skip first N results for pagination
  - `hidden` - Include hidden files (default: false)
  - `ignore_case` - Case insensitive matching (default: false)
  - `file_type` - Filter: "f" for files, "d" for directories
  - `follow` - Follow symlinks (default: false)
- **Glob patterns:** `*`, `**`, `?`, `[abc]`, `{a,b,c}`, `{1..5}`
- **Auto-truncation:** Output limited to ~50KB to protect LLM context window
- **Returns:** `<f>path</f>` wrapped in `<glob_summary total="" returned="" offset="" truncated="">`

### web_search Tool
- Uses `agent-browser` CLI
- Actions: `open`, `snapshot`, `get`, `click`, `fill`, `press`, `scroll`
- Parameters: `query`, `url`, `action`, `selector`, `args`

## Search Tool Features

When the search tool finds no matches, it returns:
```xml
<warning>pattern not found</warning>
```

This follows the same pattern as `glob.zig` and helps agents detect when searches yield no results.

**Implementation:** `src/modules/agent/tools/search.zig`

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
| GET | `/api/session/:session_id/queue/messages` | Get queued messages |
| POST | `/api/llm/run` | Run LLM workflow |
| GET | `/api/ping/:session_id` | Health check |
| POST | `/api/worker` | Create/register a worker |
| GET | `/api/workers` | List all active workers |
| GET | `/api/worker/:session_id/status` | Get worker status |
| POST | `/api/worker/:session_id/cancel` | Cancel a worker |

## Worker System

**Workers** are persistent background agents that survive restarts. They are:
- Registered in the `worker` table in the database
- Tracked in the activity registry for real-time awareness
- Automatically restarted on app startup (via startup handler)
- Shown in agent prompts so agents know what other workers are active

**Sub-agents** (spawned via `spawn_sub_agent`) are now also registered as workers:
- Each sub-agent gets a unique `session_id` (nanosecond timestamp)
- They're registered in the database (`worker` table) with `worker_id = "subagent_{session_id}"`)
- They're tracked in the activity registry during execution
- On completion, their activity description is updated and they become idle

## Data Locations

| Data | Path |
|------|------|
| Database | `~/.config/nalar/agent.db` |
| Log file | `/tmp/agentic_coding.log` |
| Panic log | Same as log file |

## Database Schema Notes

**Latest Migration:** `Migration021RemoveSessionNameFromLlmHistory` — moved to `ai_workflow/tui/migration.zig`

| Table | Key Column | Purpose |
|-------|------------|---------|
| `sessions` | `id` (PK), `name` | Session metadata |
| `llm_history` | `session_id` (FK) | References `sessions.id` |

## Important Conventions

- **Max lines per file:** 400 lines — split larger files
- **Zig Naming Convention:**
  - `camelCaseFunctionName` — callable functions
  - `TitleCaseTypeName` — types, type aliases, structs with fields
  - `snake_case_variable_name` — variables, constants, namespaces
  - **File names:** `TitleCase.zig` if struct has fields, `snake_case.zig` otherwise
  - **Directory names:** `snake_case`
- `ArrayList.empty` replaces `ArrayList.init` (Zig 0.15)
- `ArrayList.deinit(allocator)` — allocator required
- Never return stack-allocated slices from functions
- **Memory:** Prefer `ArenaAllocator` over manual `free()`
- **JSON keys:** Always `snake_case` (e.g., `session_id`, `created_at`)

## Dev Test

```bash
./zig-out/bin/nalar-dev-tui --port 8082 --process nalar-dev
```

## Unit Testing

```bash
zig build test              # Run all Zig tests
zig build test:ai_workflow:tui  # Run AI workflow TUI tests
zig build test:desktop      # Run desktop Bun tests
```

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
- Dont ever kill the process port 8081 or process nalar !!!
- If you want to test use process port 8080 and process nalar-dev !!!
