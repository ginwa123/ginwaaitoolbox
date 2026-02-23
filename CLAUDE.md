# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
zig build          # Build the project
zig build run      # Run the executable (listens on /tmp/agent.sock)
zig build test     # Run all tests
```

To run a specific test file:
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

- **`src/main.zig`**: Entry point - loads env, initializes database, starts IPC server
- **`src/ai_workflow/ask_llm_workflow.zig`**: Workflow orchestration layer that coordinates agent calls
- **`src/modules/agent/agent.zig`**: `Agent` struct for LLM API calls with tool support
- **`src/modules/agent/tools/`**: Tool implementations (bash execution, tool schemas)
- **`src/modules/ipc/ipc.zig`**: Cross-platform IPC server (Unix sockets on POSIX, named pipes on Windows)
- **`src/modules/databases/sqlite/`**: SQLite wrapper with `SqliteBackend` struct

### Data Flow

```
[TUI/Frontend] → JSON over socket → [IPC Server @ /tmp/agent.sock]
    → [AskLLMWorkflow] → [Agent] → HTTP POST to OpenAI-compatible API
    → Tool execution (bash) → Response back through chain
```

### Environment Configuration

The app reads `src/.env` for:
- `API_KEY` - LLM API key
- `MODEL` - Model name (e.g., `glm-5`)
- `BASE_URL` - API endpoint

### Agent Tool Pattern

Tools follow OpenAI's function calling format:
```zig
const AgentTool = struct {
    type: []const u8,        // "function"
    function: AgentToolFunction,
};
```

Each tool defines a `bashTool`-like constant with JSON schema for parameters.

### TUI Frontend (`src/tui/`)

Separate TypeScript/Bun project using @opentui with SolidJS:
```bash
cd src/tui && bun install && bun run dev
```

## Module Structure

```
src/
├── main.zig           # Entry point + test imports
├── root.zig           # Library exports
├── ai_workflow/
│   ├── ask_llm_workflow.zig  # LLM interaction workflow
│   └── models.zig            # Context struct for IPC/TUI
└── modules/
    ├── agent/
    │   ├── agent.zig          # Agent core (HTTP client, JSON building, API calls)
    │   ├── prompt.zig         # System prompts
    │   └── tools/
    │       ├── bash.zig       # Bash tool implementation
    │       ├── models.zig     # Tool type definitions
    │       └── change_agent.zig
    ├── databases/
    │   ├── database.zig       # Database interface
    │   └── sqlite/
    │       └── sqlite.zig     # SQLite implementation
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
