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

- **`src/main.zig`**: Entry point - Unix socket server listening at `/tmp/agent.sock`
- **`src/modules/agent/agent.zig`**: `Agent` struct for LLM API calls with tool support
- **`src/modules/agent/tools/`**: Tool implementations (bash execution, tool schemas)
- **`src/modules/databases/sqlite/`**: SQLite wrapper with `SqliteBackend` struct

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
└── modules/
    ├── agent/
    │   ├── agent.zig          # Agent core (HTTP client, JSON building, API calls)
    │   ├── agent_test.zig     # Tests
    │   └── tools/
    │       ├── bash.zig       # Bash tool implementation
    │       ├── bash_test.zig  # Tests
    │       └── models.zig     # Tool type definitions
    └── databases/
        ├── database.zig       # Database interface
        └── sqlite/
            ├── sqlite.zig     # SQLite implementation
            └── sqlite_test.zig # Tests
```

## Import Patterns

Module imports use relative paths from the importing file:
```zig
const BashInput = @import("tools/models.zig").BashInput;
const SqliteBackend = @import("sqlite.zig").SqliteBackend;
```

Test files import the module they test with relative paths.
