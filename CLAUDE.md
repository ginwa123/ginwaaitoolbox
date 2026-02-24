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

This is an AI agent system with a Zig backend and optional TUI frontend.

### Backend (Zig)

The core is an LLM agent that communicates via OpenAI-compatible chat completions API:

- **`src/main.zig`**: Entry point - loads env, initializes database, runs migrations, starts IPC server
- **`src/ai_workflow/ask_llm_workflow.zig`**: Workflow orchestration layer that coordinates agent calls, handles message history persistence
- **`src/modules/agent/agent.zig`**: `Agent` struct for LLM API calls with tool support
- **`src/modules/agent/tools/`**: Tool implementations (bash, change_agent)
- **`src/modules/ipc/ipc.zig`**: Cross-platform IPC server (Unix sockets on POSIX, named pipes on Windows)
- **`src/modules/databases/sqlite/`**: SQLite wrapper with `SqliteBackend` struct and migration system

### Data Flow

```
[TUI/Frontend] → JSON over socket → [IPC Server @ /tmp/agent.sock]
    → [AskLLMWorkflow] → [Agent] → HTTP POST to OpenAI-compatible API
    → Tool execution (bash) → Response back through chain
```

### IPC Protocol

Messages sent to the socket are JSON with this structure:
```zig
const IPCMessage = struct {
    command_type: []const u8,  // e.g., "agent_ask"
    session_id: []const u8,
    message: []const u8,
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
    read_timeout_ms: u32 = 60000,  // 60 second default timeout
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

Each tool defines a constant (e.g., `bashTool`) with JSON schema for parameters. Tool execution functions (like `executeBash`) are separate from the schema definition.

### Database Migrations

Migrations are defined in `migrations.zig` using the `Migration` struct. The `MigrationManager` runs migrations on startup. To add a new migration:
1. Create a `Migration00X...` struct with `version`, `name`, and `up` function
2. Register it in `main.zig` via `migrationManager.registerMigration()`

### TUI Frontend (`src/tui/`)

Separate TypeScript/Bun project using @opentui with SolidJS:
```bash
cd src/tui && bun install && bun run dev
bun run format   # Format code with Biome
bun run lint     # Lint with Biome
```

## Module Structure

```
src/
├── main.zig           # Entry point + test imports
├── root.zig           # Library exports
├── ai_workflow/
│   ├── ask_llm_workflow.zig  # LLM interaction workflow
│   └── models.zig            # ContextIPCTui struct
└── modules/
    ├── agent/
    │   ├── agent.zig          # Agent core (HTTP client, JSON building, API calls)
    │   ├── prompt.zig         # System prompts (AgenticCoding)
    │   └── tools/
    │       ├── bash.zig       # Bash tool implementation + bashTool constant
    │       ├── change_agent.zig
    │       └── models.zig     # Tool type definitions (AgentTool, BashInput, etc.)
    ├── databases/
    │   ├── database.zig       # Database interface
    │   └── sqlite/
    │       ├── sqlite.zig     # SqliteBackend implementation
    │       └── migrations.zig # MigrationManager + migration definitions
    └── ipc/
        └── ipc.zig            # Unix socket / Windows named pipe server
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
