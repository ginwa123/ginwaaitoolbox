# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
zig build          # Build the project
zig build run      # Run the executable (listens on /tmp/agent.sock)
zig build test     # Run all tests
```

Cross-platform builds:
```bash
zig build install:linux      # Build for Linux x86_64
zig build install:windows    # Build for Windows x86_64 (MinGW)
zig build install:macos      # Build for macOS x86_64
zig build install:macos-arm  # Build for macOS aarch64 (Apple Silicon)
```

To run a specific test file (tests follow `*_test.zig` naming):
```bash
zig test src/modules/agent/agent_test.zig
zig test src/modules/databases/sqlite/sqlite_test.zig
```

## System Requirements

- **Zig version**: 0.15.2+
- **SQLite3**: System library required (`libsqlite3-dev` on Linux)

## Project Architecture

This is a **multi-agent AI system** with a Zig backend and a Zig TUI frontend. The system supports different agent types (GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent) that can route tasks to specialized handlers.

### Backend (Zig)

The core is an LLM agent that communicates via OpenAI-compatible chat completions API:

- **`src/main.zig`**: Entry point - loads env, initializes database, runs migrations, starts IPC server
- **`src/ai_workflow/ask_llm_workflow.zig`**: Workflow orchestration layer that coordinates agent calls, handles message history persistence
- **`src/modules/agent/agent.zig`**: `Agent` struct for LLM API calls with tool support
- **`src/modules/agent/prompt.zig`**: Multi-agent system prompts (GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent)
- **`src/modules/agent/tools/`**: Tool implementations (bash, change_agent)
- **`src/modules/ipc/ipc.zig`**: Cross-platform IPC server (Unix sockets on POSIX, named pipes on Windows)
- **`src/modules/databases/sqlite/`**: SQLite wrapper with `SqliteBackend` struct and migration system

### Data Flow

```
[TUI/Frontend] → JSON over socket → [IPC Server @ /tmp/agent.sock]
    → [AskLLMWorkflow] → [Agent] → HTTP POST to OpenAI-compatible API
    → Tool execution (bash, change_agent) → Response back through chain

Multi-Agent Routing:
    GeneralAgent → routes to ExplorationAgent, PlanningAgent, or ExecutingAgent
    based on task type (discovery, planning, or implementation)
```

### IPC Protocol

Messages sent to the socket are JSON with this structure:
```zig
const IPCMessage = struct {
    command_type: []const u8 = "",  // e.g., "tui"
    session_id: []const u8 = "",
    message: []const u8 = "",
    cwd_session: []const u8 = "",   // Working directory for the session
};
```

Responses are `AgentResponse` structs (from `agent.zig`) serialized to JSON.

### Environment Configuration

The app reads `src/.env` for:
- `API_KEY` - LLM API key
- `MODEL` - Model name (e.g., `glm-5`)
- `BASE_URL` - API endpoint

### Agent Configuration

The `Agent` struct has configurable HTTP options:
```zig
const HttpOptions = struct {
    read_timeout_ms: u32 = 300_000,  // 5 minutes default timeout for LLM APIs
};
```

### Agent Tool Pattern

Tools follow OpenAI's function calling format:
```zig
const AgentTool = struct {
    type: []const u8,        // "function"
    function: AgentToolFunction,
};
```

Each tool defines a constant (e.g., `bashTool`, `ChangeAgentTool`) with JSON schema for parameters. Tool execution functions (like `executeBash`) are separate from the schema definition.

### Database Migrations

Migrations are defined in `migrations.zig` using the `Migration` struct. The `MigrationManager` runs migrations on startup. To add a new migration:
1. Create a `Migration00X...` struct with `version`, `name`, and `up` function
2. Register it in `main.zig` via `migrationManager.registerMigration()`

### TUI Frontend (`src/tui/`)

A **Zig TUI client** that connects to the IPC server for interactive use:
```bash
zig build run-tui   # Run the TUI client (connects to /tmp/agent.sock)
```

Features:
- Connects to Unix socket at `/tmp/agent.sock`
- Raw terminal mode for interactive input
- Terminal color formatting for output
- Session-based message handling

## Module Structure

```
src/
├── main.zig           # Entry point + test imports
├── root.zig           # Library exports
├── .env               # Environment config (API_KEY, MODEL, BASE_URL)
├── ai_workflow/
│   ├── ask_llm_workflow.zig      # LLM interaction workflow
│   ├── ask_llm_workflow_test.zig # Workflow tests
│   └── models.zig                # ContextIPCTui struct
└── modules/
    ├── agent/
    │   ├── agent.zig              # Agent core (HTTP client, JSON building, API calls)
    │   ├── agent_test.zig         # Agent tests
    │   ├── prompt.zig             # Multi-agent system prompts (GeneralAgent, ExplorationAgent, PlanningAgent, ExecutingAgent)
    │   └── tools/
    │       ├── bash.zig           # Bash tool implementation + bashTool constant
    │       ├── bash_test.zig      # Bash tool tests
    │       ├── change_agent.zig   # Change agent tool for multi-agent routing
    │       ├── change_agent_test.zig  # Change agent tests (placeholder)
    │       └── models.zig         # Tool type definitions (AgentTool, BashInput, etc.)
    ├── databases/
    │   ├── database.zig           # Database interface
    │   └── sqlite/
    │       ├── sqlite.zig         # SqliteBackend implementation
    │       ├── sqlite_test.zig    # SQLite tests
    │       ├── migrations.zig     # MigrationManager + migration definitions
    │       └── migrations_test.zig # Migration tests
    ├── environment/               # Empty placeholder directory
    └── ipc/
        ├── ipc.zig                # Unix socket / Windows named pipe server
        └── ipc_test.zig           # IPC tests
└── tui/
    ├── main.zig                   # Zig TUI client (terminal interface)
    └── main_test.zig              # TUI tests
```

## Import Patterns

Module imports use relative paths from the importing file:
```zig
const BashInput = @import("tools/models.zig").BashInput;
const SqliteBackend = @import("sqlite.zig").SqliteBackend;
```

Test files import the module they test with relative paths.

## Memory Management

- Explicit allocator passing throughout the codebase
- `ArenaAllocator` used for scoped allocations (e.g., per-message in IPC handler)
- All structs with owned memory have `deinit()` methods for cleanup
- Tests use `std.testing.allocator` for leak detection

## Multi-Agent System

The system supports multiple specialized agent types defined in `prompt.zig`:

- **GeneralAgent**: Routes user requests to specialized agents, handles clarification
- **ExplorationAgent**: Read-only discovery, file listing, codebase search
- **PlanningAgent**: Solution design, architecture, step-by-step plans
- **ExecutingAgent**: Implementation, code writing, deliverable production

Agents can delegate to each other via the `change_agent` tool.
