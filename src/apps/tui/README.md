# nalar-tui

**Terminal UI application for interacting with the AI agentic coding assistant.**

## Overview

The TUI provides an interactive terminal interface for sending queries to the nalarcore HTTP server and receiving streamed AI responses. It supports both interactive mode (full TUI with keyboard shortcuts) and non-interactive CLI mode (single query).

## Features

- **Interactive TUI Mode** — Full terminal interface with ANSI colors, raw mode input, and live response streaming
- **Query Mode (`-q`)** — Single query execution from command line, useful for scripting
- **Session Management** — Continue previous sessions with `-c` flag
- **Slash Commands** — Built-in commands: `/sessions`, `/exit`, `/help`, `/clear`, `/ping`, `/model`, `/config`, `/session`
- **SSE Streaming** — Real-time streamed responses via Server-Sent Events
- **Auto-completion** — Tab completion for commands and context
- **Copy/Paste Support** — Bracketed paste mode for terminal

## Usage

```bash
# Interactive mode
./zigout/bin/nalar-tui --port 8080

# Query mode (single query, exit after response)
./zigout/bin/nalar-tui --port 8080 -q "your query here"

# Continue last session
./zigout/bin/nalar-tui --port 8080 -c

# Continue specific session
./zigout/bin/nalar-tui --port 8080 -c <session_id>

# Show help
./zigout/bin/nalar-tui --help
```

## Architecture

```
src/apps/tui/
├── main.zig              # Entry point, App struct, CLI parsing
├── globals.zig           # Global constants (version, colors)
├── keybindings.zig       # Keyboard shortcut definitions
├── box.zig               # Box drawing utilities
├── text.zig              # Text formatting helpers
├── cli/
│   └── opts.zig          # CLI argument parsing
├── commands/
│   ├── command_defs.zig  # Slash command definitions
│   └── handlers.zig      # Command implementations
├── display/
│   ├── response.zig      # Response rendering
│   └── tool_results.zig  # Tool execution display
├── input/
│   ├── handle_input.zig  # Input processing loop
│   └── escape.zig        # Escape sequence handling
├── network/
│   ├── sse.zig           # SSE/chunked decoding
│   ├── streaming.zig     # LLM response streaming
│   ├── connection.zig    # HTTP connection management
│   └── messaging.zig     # Message sending/receiving
└── terminal/
    ├── raw_mode.zig      # Terminal raw mode setup
    └── backend.zig        # Backend process spawning
```

## Requirements

- Running nalarcore HTTP server on the specified port
- Terminal with ANSI color support
- POSIX-compatible system (Linux, macOS)

## Key Bindings

| Key | Action |
|-----|--------|
| `Enter` | Send message |
| `Ctrl+C` | Exit |
| `Tab` | Auto-complete |
| `Escape` | Cancel / Clear |
| `Ctrl+L` | Clear screen |
