# Desktop App Process Discovery Design

## Overview

The desktop-bun app currently hardcodes `http://127.0.0.1:8080`. This design enables dynamic discovery of the nalar backend's HTTP port by inspecting the running "nalar" process's command-line arguments.

## Problem

- `Sidebar.tsx` hardcodes `http://127.0.0.1:8080`
- `SessionChat.tsx` hardcodes `http://127.0.0.1:8080`
- If backend runs on different port, desktop app breaks

## Solution: Process Discovery

**Linux:** Read `/proc/<pid>/cmdline` for processes named "nalar", parse `--port` argument.

**Windows/macOS:** Fallback to default port 8080 (or implement platform-specific discovery later).

## Architecture

```
┌─────────────────┐     ┌──────────────────┐
│  desktop-bun    │────▶│ getBaseUrl.js    │
│  (TypeScript)   │     │  (process lookup)│
└─────────────────┘     └──────────────────┘
                              │
                              ▼
                        ┌──────────────────┐
                        │ /proc/<pid>/cmd  │  (Linux)
                        │ (parse --port)   │
                        └──────────────────┘
```

## Components

### 1. `src/apps/desktop-bun/src/utils/processDiscovery.ts` (NEW)
- `findNalarPort(): Promise<number>` — scans `/proc/*/cmdline` on Linux
- Returns port number or default 8080
- Caches result to avoid repeated filesystem reads

### 2. `src/apps/desktop-bun/src/utils/baseUrl.ts` (MODIFY)
- Replace hardcoded `getBaseUrl()`
- Use `processDiscovery.findNalarPort()` 
- Compose: `http://127.0.0.1:${port}`

### 3. Files to Update
- `Sidebar.tsx` — remove local `getBaseUrl`, import from utils
- `SessionChat.tsx` — remove local `getBaseUrl`, import from utils

## Data Flow

1. Desktop app loads → calls `findNalarPort()`
2. Function scans `/proc/*/cmdline` for processes containing "nalar"
3. Parses `--port NNNN` from command line
4. Returns port (default 8080 if not found)
5. `getBaseUrl()` uses cached port

## Error Handling

- Process not found → return default port 8080
- Port arg not found → return default port 8080
- Invalid port format → return default port 8080
- Windows/macOS → return default port 8080 (future enhancement)

## Testing Strategy

1. With nalar running on port 8080 → returns 8080
2. With nalar running on port 9090 → returns 9090
3. With nalar not running → returns 8080

## File Changes

| File | Action |
|------|--------|
| `src/apps/desktop-bun/src/utils/processDiscovery.ts` | Create |
| `src/apps/desktop-bun/src/utils/baseUrl.ts` | Create |
| `src/apps/desktop-bun/src/mainview/components/Sidebar.tsx` | Modify |
| `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx` | Modify |

## Tech Stack

- TypeScript (desktop app)
- Bun runtime (for file system access)
- Node.js `/proc` API on Linux
