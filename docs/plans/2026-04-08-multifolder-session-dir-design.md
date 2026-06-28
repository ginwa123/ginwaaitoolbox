# Multi-Folder Session Directory Filter — Design

## Status
- **Date:** 2026-04-08
- **Approved:** Yes

## Overview

Allow users to select multiple folders. Sessions from ANY selected folder appear in the sidebar. Simple add/remove UX with folder chips.

## Architecture

### Data Storage (SQLite)

Store as JSON array in `config` table:
- key = `session_dirs`
- value = `["/path/a", "/path/b", "/path/c"]`

New functions:
- `getSessionDirs()` → returns `string[]`
- `setSessionDirs(paths: string[])` → saves entire array
- `addSessionDir(path)` → appends if not exists
- `removeSessionDir(path)` → removes from array

### Backend API

Endpoint: `GET /api/session?session_dirs=/path/a,/path/b`

Query logic (OR — sessions matching ANY of the selected folders):
```sql
SELECT * FROM sessions WHERE session_dir IN (?, ?) OR session_dir IS NULL
```

### Frontend State

Signal: `selectedSessionDirs: string[]`
- Loaded from config on app mount
- Updated when user adds/removes folders

Config functions in `src/mainview/utils/config.ts`

## UI Design

### Folder Chips Bar

Located above session list in Sidebar:

```
┌────────────────────────────────────────┐
│ [📁 /path/a ×] [📁 /path/b ×] [+]      │
│                                        │
│ Sessions                               │
│ + session-1                            │
│ + session-2                            │
│ ...                                    │
└────────────────────────────────────────┘
```

- Each chip shows folder name (truncated path) with "×" button
- "+" button opens FolderPicker to add a folder
- Clicking "×" removes folder from list
- Empty state: just "+" button with tooltip "Add folder"

### FolderPicker

No UI changes — single folder select, returns path on confirm. Behavior unchanged.

### SessionChat

Uses `session_dirs` from store, not single `session_dir`. Behavior unchanged.

## Files to Modify

| File | Changes |
|------|---------|
| `src/bun/db/index.ts` | Add `getSessionDirs()`, `setSessionDirs()`, `addSessionDir()`, `removeSessionDir()` |
| `src/bun/config-handlers.ts` | Add `getSessionDirs`, `setSessionDirs` handlers |
| `src/bun/index.ts` | Register new RPC handlers |
| `src/mainview/utils/config.ts` | Add `getSessionDirs()`, `setSessionDirs()`, `addSessionDir()`, `removeSessionDir()` |
| `src/mainview/store/sessionStore.tsx` | Add `selectedSessionDirs` signal + helpers |
| `src/mainview/components/Sidebar.tsx` | Add folder chips UI, integrate with FolderPicker |

## API Change

```
GET /api/session?session_dirs=/home/user/a,/home/user/b
```

Multiple paths are comma-separated in the query param.

## Edge Cases

1. **Empty list** → show all sessions (no filter)
2. **Folder doesn't exist** → still saved, will show no sessions for that path
3. **Duplicate folder** → prevent adding if already exists
4. **Path with comma** → URL encode paths when passing to API
5. **Session with null session_dir** → always shown (backward compat)
