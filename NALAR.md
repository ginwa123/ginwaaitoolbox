# NALAR.md — Project Summary

> **Last Updated:** 2025-04-20
> **Auto-Update Rule:** MUST update after making changes. Keep concise, max ~200 lines.

---

# Mandatory
- Always update this file NALAR.md to match actual project or codebase

## Project Overview

**Name:** nalarcore
**Executables:** `nalar` (server), `nalar-tui` (old TUI), `nalar-new-tui` (new ZigZag TUI), `nalar-dev`/`nalar-dev-tui` (debug builds)
**Language:** Zig 0.16.0
**Type:** AI agentic coding toolbox with HTTP server + TUI interfaces

## HTTP Server Architecture

**GinwaServer** (`src/modules/custom_http_server/src/http_server.zig`) is the main HTTP server that handles:
- HTTP request routing
- SSE (Server-Sent Events) for real-time streaming
- Session management
- Panic broadcast to all connected clients

**SSE Manager:** Manages SSE client connections with automatic stale client cleanup. Provides `broadcastPanic()` for panic events.

**Global access:** `gserverz.global_server` holds the singleton instance. Use `gserverz.getGlobalSseManager()` to access SSE functionality.

## Workflow Methods

**TUIWorkflow** (`src/ai_workflow/tui/workflow.zig`) has two workflow modes:

| Method | Behavior |
|--------|----------|
| `runAgenticSimpleStep` | Single LLM call, no tool execution — answers questions only |
| `runAgenticMultiStep` | Loop with tool execution — full agentic behavior |

**Initialization:**
```zig
var workflow = TUIWorkflow.init(db, llm_config, logger);
```

**RunParams (simplified):**
```zig
pub const RunParams = struct {
    parent_allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
};
```

All HTTP handlers use `runAgenticMultiStep`. Sub-agents use `runAgenticSimpleStep`.

## ZigZag TUI Framework

The new TUI (`nalar-new-tui`) is built using the **ZigZag** framework (https://github.com/meszmate/zigzag):
- Elm-style Model-Update-View pattern
- Built-in terminal handling, keyboard/mouse input
- Styles, colors, borders, layout utilities
- See `src/apps/new_tui/src/main.zig` for the new TUI implementation

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
zig build run:tui      # Run old TUI app
zig build run:new_tui  # Run new ZigZag TUI app
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
const helpers = nalarcore.helpers;
// etc.
```

**Helpers module exports:**
```zig
const xml = helpers.xml;           // XML parsing utilities
const db_path = helpers.db_path;   // Database path helper
const process = helpers.process;    // Process utilities (getCurrentProcessId, hex_digits)
const image = helpers.image;        // Base64 image URL extraction
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
│   │       ├── skills.zig, get_skill.zig, list_skills.zig, add_skill.zig, edit_skill.zig, remove_skill.zig
│   │       ├── list_agents.zig, add_agent.zig, remove_agent.zig
│   │       ├── set_agent_properties.zig, bash_selfkill.zig
│   │       ├── helper.zig, schemas.zig, tools.zig
│   ├── config/Config.zig              # LLM configuration
│   ├── databases/
│   │   ├── database.zig               # DB abstraction (placeholder)
│   │   └── sqlite/Sqlite.zig          # SQLite implementation
│   ├── http/HttpClient.zig            # HTTP client
│   ├── custom_http_server/           # Custom HTTP server with SSE support
│   │   └── src/http_server.zig       # GinwaServer + gserverz exports
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
└── apps/desktop/                      # Desktop Vue app (Bun + Vue 3)
    ├── src/
    │   ├── main.ts                    # Entry point
    │   ├── App.vue                    # Main app with navigation state
    │   ├── api.ts                     # API client
    │   ├── stores/
    │   │   ├── workspaces.ts          # Workspaces state + localStorage persistence
    │   │   └── sidebar.ts             # Sidebar state + localStorage persistence
    │   └── components/
    │       ├── Sidebar.vue           # Sidebar with chats + workspaces
    │       ├── WorkspaceList.vue     # Workspaces section
    │       ├── WorkspaceItem.vue     # Individual workspace item
    │       ├── Chats.vue              # Chat list view
    │       └── ChatView.vue           # Chat conversation view
```

## Desktop App (Vue) State Persistence

**localStorage keys for navigation state:**
| Key | Value | Purpose |
|-----|-------|---------|
| `sidebar-collapsed` | `'true'` / `'false'` | Sidebar collapsed state |
| `sidebar-width` | Pixel number | Sidebar width (72-480px) |
| `active-chat-id` | Session ID | Active chat session (without `chat-` prefix) |
| `active-chat-name` | Display name | Active chat name |
| `active-task-id` | Task ID | Active task for persistence |
| `nalar_chats_sort_direction` | `'asc'` / `'desc'` | Sort direction for chats list |
| `nalar-sidebar-chats-height` | Percentage number | Chats section height in sidebar |
| `nalar-sidebar-nav-expanded` | `'true'` / `'false'` | Chats section expanded state |
| `nalar-sidebar-workspaces-expanded` | `'true'` / `'false'` | Workspaces section expanded state |
| `nalar-workspace-expanded` | JSON array of IDs | Expanded workspace IDs |
| `nalar-workspace-item-expanded` | JSON array of IDs | Expanded workspace item IDs (nested folders) |
| `nalar-workspace-item-tasks-expanded` | JSON array of IDs | Expanded workspace item IDs (tasks list - allows multiple) |

**Note:** Workspace and workspace item expand states are persisted in `workspaces.ts` store. Nav section and workspaces section expand states are persisted in `sidebar.ts` store.

**LLM Processing Indicator in Sidebar:**
When the LLM is processing (detected via `isLLMProcessing` from App.vue), the active chat item shows a spinner animation instead of the 💬 icon. Implementation in `Sidebar.vue`:
- Injects `isLLMProcessing` from App.vue
- Watches `isLLMProcessing` and syncs `processing` flag to active navItem
- Template shows spinner when `item.processing` is true, icon otherwise

**URL routing for navigation state:**
| URL | View | Parameters |
|-----|------|------------|
| `/app?view=chat&session=<id>` | Chat view | `session` = chat session ID |
| `/app?view=task&task=<id>` | Task view | `task` = task ID |
| `/app?view=workspace` | Workspace view | (no extra params) |
| `/app/settings` | Settings view | - |

**Routing priority:**
1. URL query params (first priority - for shareable links)
2. localStorage (fallback - for page refresh within app)
3. Defaults to chat view if neither is present

## Desktop Components

| Component | File | Purpose |
|-----------|------|---------|
| SkillList | `components/SkillList.vue` | Reusable skills list with loading/error/empty states. Fetches from `/api/skills` endpoint. |
| response-path-api-skills | `.nalar/skills/response-path-api-skills/SKILL.MD` | Documents GET /api/skills endpoint response format and usage |
| SettingsView | `components/SettingsView.vue` | Settings page with tabs for Model, API, and Skills configuration |

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

## Bug Fixes (Development Notes)
- [workflow.zig:737] Fixed "write failed" error: `msg.tool_call_id orelse "unknown"` can't be used directly in `print` format — wrapped in `if (msg.tool_call_id) |id| id else "unknown"` because Zig requires the same type for both branches of the ternary-like pattern.
- [llm_history.zig:477] Fixed JSON parsing error in frontend: added `jsonEscape()` helper function and used it for all string fields (id, session_id, role, content, timestamp, tool_name, finish_reason) in `buildSessionMessagesJson()`. Previously only `content` was escaped.
- [llm_history.zig:491] Added control character escaping (\x08, \x0C, and 0x00-0x07, 0x0E-0x1F as \u00XX) in `jsonEscape()` to prevent "Bad control character in string literal" JSON parse errors.
- [llm_history.zig:114] Added `SessionSortField` and `SessionSortDirection` enums, updated `getSessionListWithCursor()` with `sort_field` and `sort_direction` parameters to support sorting by `created_at`, `session_name`, or `agent` fields with `asc`/`desc` directions.
- [llm_history.zig:416] Fixed cursor pagination for DESC order: reversed cursor comparison operator from `h.created_at < ?` (asc) / `h.created_at > ?` (desc) to `h.created_at > ?` (asc) / `h.created_at < ?` (desc) so loading more goes correctly to older messages.
- [ChatView.vue] Added "Load more messages" button at top for when message list doesn't overflow (overscroll not visible). Also fixed scroll position preservation when prepending messages during loadMore.
- [list_skills.zig] Refactored to shared module with `SkillsListData` struct used by both HTTP handler (`/api/skills`) and AI agent tool. Added `toJson()` and `toXml()` serialization functions.
- [llm_history.zig, workflow.zig, transform_llm_history_to_agent_messages.zig] Renamed `TUIHistory.image_url` (single) to `image_urls` (array, `?[][]const u8`) and updated all usages to support multiple base64 images per message. Storage format in DB remains `image_url TEXT` with pipe-separated values. Helper function `extractBase64ImageUrls` in workflow.zig extracts ALL image URLs (not just first) from messages containing `data:image/...;base64,...` patterns. The `transform_llm_history_to_agent_message()` function creates `content_parts` for multimodal messages when `image_urls` is present.
- [workflow.zig, llm_history.zig, models.zig, migration.zig] Added base64 image support for vision. Messages containing `data:image/...;base64,...` patterns are detected and stored with the `image_url` field. The `transform_llm_history_to_agent_message()` function creates `content_parts` for multimodal messages when `image_url` is present. Migration036 adds `image_url TEXT` column to `llm_history` table.

## Lessons Learned
- **Never build JSON manually** — Use `std.json.Stringify.valueAlloc(allocator, response_struct, .{})` instead of manual string concatenation with manual escaping. Zig's standard library handles JSON escaping properly and the code is cleaner. Example: see `http_response.zig` for response structure definitions and `skills_list.zig` for usage pattern.
- **Unit tests belong in separate files** — Keep implementation (`.zig`) and tests (`_test.zig`) separate. This improves code organization, makes tests easier to find, and avoids cluttering the implementation with test code. Never inline tests in production code.
- **Always register new tests in test_runner.zig** — When creating a new `_test.zig` file, immediately add `_ = @import("path/to/test.zig")` to the appropriate test_runner.zig. This ensures tests are included in the test suite and won't be forgotten.
- **Desktop app: ALWAYS run `bun run build-only`** — After any Vue component changes (create, edit, delete), MUST run `bun run build-only` in `src/apps/desktop/` directory to verify build succeeds. This is MANDATORY before declaring the task complete.

## Key Tool Conventions

### text_replace Tool
Just use it - read the file first to see its current content.

**Diff View Response:** After successful text_replace, the response includes:

```xml
<success>true</success>
<path>/path/to/file.zig</path>
<diff_view>
<before>
original file content
</before>
<after>
modified file content
</after>
</diff_view>
```

**Structure:**
- `diff_view.before` — file content before the edit
- `diff_view.after` — file content after the edit

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
| GET | `/api/session` | List sessions (cursor pagination, sort support) |
| GET | `/api/session/stream` | SSE session events (session_created notifications) |
| GET | `/api/session/:session_id` | Get session |
| GET | `/api/session/:session_id/messages` | Get messages (includes `max_total_tokens`) |
| GET | `/api/session/exists/:session_id` | Check exists |
| GET | `/api/session/latest` | Get latest by directory |
| POST | `/api/session/:session_id/cancel` | Cancel session |
| POST | `/api/session/:session_id/compact` | Trigger compaction |
| DELETE | `/api/session/:session_id/queue/message?message=` | Delete queued message |
| GET | `/api/session/:session_id/queue/messages` | Get queued messages |
| GET | `/api/llm/session/:session_id/queue_messages` | Get queued messages (alias) |
| GET | `/api/llm/session/:session_id/queue_messages/stream` | SSE real-time queue message events |
| POST | `/api/llm/run` | Run LLM workflow |
| GET | `/api/ping/:session_id` | Health check |
| POST | `/api/worker` | Create/register a worker |
| GET | `/api/workers` | List all active workers |
| GET | `/api/worker/:session_id/status` | Get worker status |
| POST | `/api/worker/:session_id/cancel` | Cancel a worker |
| POST | `/api/workspaces/:workspace_id/items` | Create workspace item |
| GET | `/api/workspaces/:workspace_id/items` | List workspace items |
| GET | `/api/workspaces/:workspace_id/items/:item_id` | Get workspace item |
| PUT | `/api/workspaces/:workspace_id/items/:item_id` | Update workspace item |
| DELETE | `/api/workspaces/:workspace_id/items/:item_id` | Delete workspace item |
| GET | `/api/skills` | List skills (global + local with optional `cwd` param) |
| GET | `/api/skills?cwd=/path` | List skills from specific working directory (local skills only) |
| DELETE | `/api/skills?name=X&is_global=true` | Delete global skill by name |
| DELETE | `/api/skills?name=X&cwd=/path` | Delete local skill by name (requires `cwd` param) |

### Session Messages Response

The `GET /api/session/:session_id/messages` endpoint returns:
```json
{
  "messages": [
    {
      "id": "...",
      "session_id": "...",
      "role": "user|assistant",
      "content": "...",
      "timestamp": "...",
      "is_input": "0|1",
      "is_output": "0|1",
      "tool_name": "...",
      "finish_reason": "stop|tool_calls|...",
      "reasoning_content": "...",
      "diffview_before": "",
      "diffview_after": ""
    }
  ],
  "has_more": false,
  "next_cursor": null,
  "cwd": "/path/to/cwd",
  "max_total_tokens": 12345,
  "max_capacity_total_tokens": 200000
}
```

Where:
- `max_total_tokens`: Maximum total_tokens from LLM responses where `is_feed_to_llm = 1`
- `max_capacity_total_tokens`: Model's token capacity (e.g., 200000 for MiniMax-M2.7)
- `diffview_before`: Content before text_replace operation (for diff view)
- `diffview_after`: Content after text_replace operation (for diff view)

### Session List Sorting

The `GET /api/session` endpoint supports sorting with query parameters:

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `sort_by` | `created_at`, `session_name`, `agent` | `created_at` | Field to sort by |
| `direction` | `asc`, `desc` | `desc` | Sort direction |

**Example:**
```
GET /api/session?sort_by=session_name&direction=asc
```

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

**Sub-agent Detection:** Workers are identified as sub-agents by checking if their `session_id` contains "subagent" string:
```zig
// WorkerInfo.isSubAgent() - checks if session_id contains "subagent"
const is_sub_agent = std.mem.indexOf(u8, session_id, "subagent") != null;
```

## Data Locations

| Data | Path |
|------|------|
| Database | `~/.config/nalar/agent.db` |
| Log file | `/tmp/agentic_coding.log` |
| Panic log | Same as log file |

## Database Schema Notes

**Latest Migration:** `Migration029AddTimestampsToSessions` — added `created_at` and `updated_at` columns to `sessions` table

**Timestamp Columns (Migration030 & Migration031):**
- `Migration030AddTimestampsToWorkspaces` (v30) — added `created_at` and `updated_at` to `workspaces` table
- `Migration031AddTimestampsToWorkspaceItems` (v31) — added `created_at` and `updated_at` to `workspace_items` table
- Both use `DATETIME DEFAULT (datetime('now'))` for automatic timestamp on insert
- Updates automatically set `updated_at = datetime('now')` via `workspace_update.zig` and `workspace_items_table.zig`

**New Table (Migration034):**
- `Migration034CreateWorkspaceItemTasks` (v34) — created `workspace_item_tasks` table with columns: `id` (PK), `name`, `workspace_item_id`, `session_id`, `created_at`, `updated_at`

| Table | Key Column | Purpose |
|-------|------------|---------|
| `sessions` | `id` (PK), `name`, `cwd`, `created_at`, `updated_at` | Session metadata (cwd = working directory) |
| `llm_history` | `session_id` (FK) | References `sessions.id` |
| `workspace_items` | `id` (PK), `workspace_id`, `item_type`, `created_at`, `updated_at` | Workspace items table |
| `workspace_item_tasks` | `id` (PK), `workspace_item_id`, `session_id` | Tasks linked to workspace items |
| `workspaces` | `id` (PK), `name`, `created_at`, `updated_at` | Workspaces table |

**Schema Change (Migration023):**
- Removed `session_dir` column from `llm_history`
- `cwd` is now stored in `sessions.cwd` column
- `saveMessage()` updates `sessions.cwd` when saving messages
- All queries that read `session_dir` now JOIN with `sessions` table to get `cwd`

## Session Name Generation

When a session is created without a name (empty string or null), the LLM automatically generates a descriptive session name based on the user's first message intent.

**Implementation:**
- `session_table.zig` — `update_session_name()` function to update session name in DB
- `workflow.zig` — `generateSessionName()` method called after first LLM response
- `special.zig` — `GenerateSessionNameAgent` prompt for name generation

**Rules for generated names:**
- 2-5 words capturing the user's intent
- Max 50 characters
- Lowercase with hyphens (e.g., "fix-login-bug")
- Strip common prefixes ("help me", "can you", "please")

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
