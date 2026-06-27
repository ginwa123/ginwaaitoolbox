# Multi-Folder Session Directory Filter — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to select multiple folders. Sessions from ANY selected folder appear in sidebar.

**Architecture:**
- Store `session_dirs` as JSON array in SQLite `config` table (key=`session_dirs`)
- Backend: `GET /api/session?session_dirs=/path/a,/path/b` — comma-separated, SQL uses `IN` clause
- Frontend: Folder chips UI with add/remove, persists full list

**Tech Stack:** Zig 0.15.2 backend, Bun/ElectroBun desktop app, SolidJS frontend

---

## Chunk 1: Backend — Update session_db.zig to support multiple directories

**Files:**
- Modify: `src/ai_workflow/tui/session_db.zig`
- Modify: `src/ai_workflow/tui/http_handlers/session_list.zig`

---

### Task 1: Update `getSessionListWithCursor` to accept `session_dirs: ?[][]const u8`

**Modify:** `src/ai_workflow/tui/session_db.zig:63-155`

- [ ] **Step 1: Read the current file to see exact content at line 63**

Run: `head -n 160 src/ai_workflow/tui/session_db.zig`

- [ ] **Step 2: Replace the function signature and implementation**

Old function (lines 63-155):
```zig
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    session_dir: ?[]const u8,
    limit: u32,
    cursor: ?[]const u8,
) !struct { sessions: []SessionInfo, total: u32 } {
```

New function:
```zig
pub fn getSessionListWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    status: ?[]const u8,
    agent_type: ?[]const u8,
    session_dirs: ?[][]const u8,
    limit: u32,
    cursor: ?[]const u8,
) !struct { sessions: []SessionInfo, total: u32 } {
```

- [ ] **Step 3: Update the query building logic (lines 83-101)**

Replace the single `session_dir` filter with `session_dirs` array support:

```zig
    // Build query with session_dirs filter and cursor condition
    const sql_final: []u8 = if (session_dirs) |dirs| blk: {
        if (dirs.len == 0) {
            // No filter - show all sessions
            if (cursor) |c| {
                break :blk try std.fmt.allocPrint(allocator,
                    "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                    .{c, limit});
            } else {
                break :blk try std.fmt.allocPrint(allocator,
                    "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                    .{limit});
            }
        } else {
            // Build IN clause with placeholders
            var placeholders = std.ArrayList(u8).empty;
            errdefer placeholders.deinit(allocator);
            for (0..dirs.len) |i| {
                if (i > 0) try placeholders.appendSlice(allocator, ", ");
                try placeholders.appendSlice(allocator, "?");
            }
            
            const in_clause = try std.fmt.allocPrint(allocator, "session_dir IN ({s})", .{placeholders.items});
            defer allocator.free(in_clause);
            
            if (cursor) |c| {
                break :blk try std.fmt.allocPrint(allocator,
                    \\SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') 
                    \\FROM llm_history WHERE 1=1 AND {s} AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d},
                    .{in_clause, c, limit});
            } else {
                break :blk try std.fmt.allocPrint(allocator,
                    \\SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') 
                    \\FROM llm_history WHERE 1=1 AND {s} GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d},
                    .{in_clause, limit});
            }
        }
    } else blk: {
        // No session_dirs filter - show all sessions
        if (cursor) |c| {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 AND created_at < '{s}' GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{c, limit});
        } else {
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history WHERE 1=1 GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT {d}",
                .{limit});
        }
    };
```

- [ ] **Step 4: Update the query call to pass `session_dirs` array as args**

Replace the query call:
```zig
    var rows = try db.query(allocator, sql_final, &.{});
```
With:
```zig
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(allocator);
    
    if (session_dirs) |dirs| {
        for (dirs) |d| {
            try argv.append(allocator, d);
        }
    }
    if (cursor) |c| {
        try argv.append(allocator, c);
    }
    
    var rows = try db.query(allocator, sql_final, argv.items);
```

- [ ] **Step 5: Update the count query similarly**

Replace lines 127-136 with:
```zig
    // Build count query with session_dirs filter
    const count_sql: []u8 = if (session_dirs) |dirs| blk: {
        if (dirs.len == 0) {
            break :blk try allocator.dupe(u8, "SELECT COUNT(DISTINCT session_id) FROM llm_history");
        } else {
            var placeholders = std.ArrayList(u8).empty;
            errdefer placeholders.deinit(allocator);
            for (0..dirs.len) |i| {
                if (i > 0) try placeholders.appendSlice(allocator, ", ");
                try placeholders.appendSlice(allocator, "?");
            }
            break :blk try std.fmt.allocPrint(allocator,
                "SELECT COUNT(DISTINCT session_id) FROM llm_history WHERE session_dir IN ({s})",
                .{placeholders.items});
        }
    } else
        try allocator.dupe(u8, "SELECT COUNT(DISTINCT session_id) FROM llm_history");
    defer allocator.free(count_sql);
    
    // Build count argv
    var count_argv = std.ArrayList([]const u8).empty;
    errdefer count_argv.deinit(allocator);
    if (session_dirs) |dirs| {
        for (dirs) |d| {
            try count_argv.append(allocator, d);
        }
    }
    var count_rows = try db.query(allocator, count_sql, count_argv.items);
```

---

### Task 2: Update `session_list.zig` HTTP handler

**Modify:** `src/ai_workflow/tui/http_handlers/session_list.zig`

- [ ] **Step 1: Read file to confirm current content**

- [ ] **Step 2: Replace the handler to parse `session_dirs` as comma-separated**

Replace lines 14-17:
```zig
    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const cursor = query.get("cursor");
    const session_dir = query.get("session_dir"); // Optional filter by directory
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 50;
```

With:
```zig
    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const cursor = query.get("cursor");
    const session_dirs_raw = query.get("session_dirs"); // Comma-separated directories
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 50;
    
    // Parse comma-separated session_dirs into array
    var session_dirs: ?[][]const u8 = null;
    if (session_dirs_raw) |raw| {
        if (raw.len > 0) {
            var parts = std.ArrayList([]const u8).empty;
            errdefer parts.deinit(alloc);
            var start: usize = 0;
            for (0..raw.len) |i| {
                if (i == raw.len or raw[i] == ',') {
                    const trimmed = std.mem.trim(u8, raw[start..i], " ");
                    if (trimmed.len > 0) {
                        try parts.append(alloc, try alloc.dupe(u8, trimmed));
                    }
                    start = i + 1;
                }
            }
            if (parts.items.len > 0) {
                session_dirs = try parts.toOwnedSlice(alloc);
            }
        }
    }
```

- [ ] **Step 3: Update the getSessionListWithCursor call**

Replace:
```zig
            const result = session_db.getSessionListWithCursor(alloc, sqlite_db, null, null, session_dir, limit_val, cursor) catch {
```
With:
```zig
            const result = session_db.getSessionListWithCursor(alloc, sqlite_db, null, null, session_dirs, limit_val, cursor) catch {
```

- [ ] **Step 4: Add defer to free session_dirs memory**

After the `defer { for (result.sessions) |s| s.deinit(alloc); ... }` block, add:
```zig
            // Free session_dirs array if allocated
            if (session_dirs) |dirs| {
                for (dirs) |d| alloc.free(d);
                alloc.free(dirs);
            }
```

---

### Task 3: Build and test backend

- [ ] **Step 1: Build the project**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && zig build 2>&1 | head -n 100`

Expected: Compiles without errors

- [ ] **Step 2: Run tests**

Run: `zig build test 2>&1 | head -n 100`

Expected: All tests pass

---

## Chunk 2: Frontend (Bun) — Config DB functions for multi-folder storage

**Files:**
- Modify: `src/apps/desktop-bun/src/bun/db/index.ts`
- Modify: `src/apps/desktop-bun/src/bun/config-handlers.ts`
- Modify: `src/apps/desktop-bun/src/bun/index.ts`

---

### Task 4: Add multi-folder config functions to db/index.ts

**Modify:** `src/apps/desktop-bun/src/bun/db/index.ts`

- [ ] **Step 1: Read the file**

- [ ] **Step 2: Add JSON parsing helpers at top of file**

Add after the imports:
```typescript
/**
 * Parse a JSON array string to string array
 */
function parseJsonArray(value: string | null): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    if (Array.isArray(parsed)) {
      return parsed.filter((v): v is string => typeof v === 'string');
    }
    return [];
  } catch {
    return [];
  }
}

/**
 * Serialize string array to JSON string
 */
function serializeJsonArray(arr: string[]): string {
  return JSON.stringify(arr);
}
```

- [ ] **Step 3: Add new functions after `dbListConfig`**

Add before the closing `}`:
```typescript
/**
 * Get session_dirs as string array from config
 */
export function dbGetSessionDirs(): string[] {
  const value = dbGetConfig('session_dirs');
  return parseJsonArray(value);
}

/**
 * Set session_dirs array in config
 */
export function dbSetSessionDirs(dirs: string[]): void {
  dbSetConfig('session_dirs', serializeJsonArray(dirs));
}

/**
 * Add a directory to session_dirs (if not already present)
 */
export function dbAddSessionDir(dir: string): void {
  const dirs = dbGetSessionDirs();
  if (!dirs.includes(dir)) {
    dirs.push(dir);
    dbSetSessionDirs(dirs);
  }
}

/**
 * Remove a directory from session_dirs
 */
export function dbRemoveSessionDir(dir: string): void {
  const dirs = dbGetSessionDirs();
  const filtered = dirs.filter(d => d !== dir);
  dbSetSessionDirs(filtered);
}
```

---

### Task 5: Add config handlers for new functions

**Modify:** `src/apps/desktop-bun/src/bun/config-handlers.ts`

- [ ] **Step 1: Read file to confirm imports**

- [ ] **Step 2: Add import for new functions**

Add to the import line:
```typescript
import { dbDeleteConfig, dbGetConfig, dbListConfig, dbSetConfig, dbGetSessionDirs, dbSetSessionDirs, dbAddSessionDir, dbRemoveSessionDir } from './db';
```

- [ ] **Step 3: Add new handlers after `listConfig`**

Add before the closing `}`:
```typescript
/**
 * Get session_dirs as JSON array
 */
export async function getSessionDirs(): Promise<{ dirs: string[] }> {
  const dirs = dbGetSessionDirs();
  return { dirs };
}

/**
 * Set session_dirs array
 */
export async function setSessionDirs(dirs: string[]): Promise<{ success: boolean }> {
  dbSetSessionDirs(dirs);
  return { success: true };
}

/**
 * Add a directory to session_dirs
 */
export async function addSessionDir(dir: string): Promise<{ success: boolean }> {
  dbAddSessionDir(dir);
  return { success: true };
}

/**
 * Remove a directory from session_dirs
 */
export async function removeSessionDir(dir: string): Promise<{ success: boolean }> {
  dbRemoveSessionDir(dir);
  return { success: true };
}
```

---

### Task 6: Register new RPC handlers

**Modify:** `src/apps/desktop-bun/src/bun/index.ts`

- [ ] **Step 1: Update the import**

Replace:
```typescript
import { deleteConfig, getConfig, listConfig, setConfig } from './config-handlers';
```
With:
```typescript
import { deleteConfig, getConfig, listConfig, setConfig, getSessionDirs, setSessionDirs, addSessionDir, removeSessionDir } from './config-handlers';
```

- [ ] **Step 2: Add RPC handlers after `listConfig` handler**

Find the `listConfig` handler and add after it:
```typescript
      // === SESSION DIRS OPERATIONS ===
      // Get session_dirs array
      getSessionDirs: () => {
        console.log('[Bun] getSessionDirs called');
        return getSessionDirs();
      },

      // Set session_dirs array
      setSessionDirs: ({ dirs }) => {
        console.log(`[Bun] setSessionDirs called: ${JSON.stringify(dirs)}`);
        return setSessionDirs(dirs);
      },

      // Add a directory to session_dirs
      addSessionDir: ({ dir }) => {
        console.log(`[Bun] addSessionDir called: ${dir}`);
        return addSessionDir(dir);
      },

      // Remove a directory from session_dirs
      removeSessionDir: ({ dir }) => {
        console.log(`[Bun] removeSessionDir called: ${dir}`);
        return removeSessionDir(dir);
      },
```

---

## Chunk 3: Frontend (SolidJS) — Config utils and sessionStore

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/utils/config.ts`
- Modify: `src/apps/desktop-bun/src/mainview/store/sessionStore.tsx`

---

### Task 7: Update config.ts with multi-folder functions

**Modify:** `src/apps/desktop-bun/src/mainview/utils/config.ts`

- [ ] **Step 1: Read the file**

- [ ] **Step 2: Replace the file content**

```typescript
import { electroview } from '../main';

// Config keys
const CONFIG_KEY_SESSION_DIRS = 'session_dirs';
const DEFAULT_SESSION_DIRS: string[] = [];

/**
 * Get the selected session directories from config
 * Returns empty array if not set
 */
export async function getSessionDirs(): Promise<string[]> {
  try {
    const result = await electroview.rpc.request.getSessionDirs();
    return result.dirs ?? DEFAULT_SESSION_DIRS;
  } catch (err) {
    console.warn('[Config] Failed to get session_dirs, using default:', err);
    return DEFAULT_SESSION_DIRS;
  }
}

/**
 * Set the selected session directories in config
 */
export async function setSessionDirs(dirs: string[]): Promise<void> {
  try {
    await electroview.rpc.request.setSessionDirs({ dirs });
  } catch (err) {
    console.error('[Config] Failed to set session_dirs:', err);
    throw err;
  }
}

/**
 * Add a directory to session_dirs
 */
export async function addSessionDir(dir: string): Promise<void> {
  try {
    await electroview.rpc.request.addSessionDir({ dir });
  } catch (err) {
    console.error('[Config] Failed to add session_dir:', err);
    throw err;
  }
}

/**
 * Remove a directory from session_dirs
 */
export async function removeSessionDir(dir: string): Promise<void> {
  try {
    await electroview.rpc.request.removeSessionDir({ dir });
  } catch (err) {
    console.error('[Config] Failed to remove session_dir:', err);
    throw err;
  }
}

/**
 * Legacy: Get single session directory (for backward compatibility)
 * Returns first directory from the list or '/'
 */
export async function getSessionDir(): Promise<string> {
  const dirs = await getSessionDirs();
  return dirs.length > 0 ? dirs[0] : '/';
}

/**
 * Legacy: Set single session directory (for backward compatibility)
 * Replaces the entire list with just this one directory
 */
export async function setSessionDir(path: string): Promise<void> {
  if (path === '/' || path === '') {
    await setSessionDirs([]);
  } else {
    await setSessionDirs([path]);
  }
}

// Keep other existing functions
export async function getConfig(key: string): Promise<string | null> {
  const result = await electroview.rpc.request.getConfig({ key });
  return result.value;
}

export async function setConfig(key: string, value: string): Promise<void> {
  const result = await electroview.rpc.request.setConfig({ key, value });
  if (!result.success) {
    throw new Error('Failed to set config');
  }
}

export async function deleteConfig(key: string): Promise<void> {
  const result = await electroview.rpc.request.deleteConfig({ key });
  if (!result.success) {
    throw new Error('Failed to delete config');
  }
}

export async function listConfig(): Promise<Array<{ key: string; value: string }>> {
  const result = await electroview.rpc.request.listConfig();
  return result.entries;
}
```

---

### Task 8: Update sessionStore.tsx with selectedSessionDirs

**Modify:** `src/apps/desktop-bun/src/mainview/store/sessionStore.tsx`

- [ ] **Step 1: Read the file**

- [ ] **Step 2: Add new exports after `setSelectedFolderValue`**

Add:
```typescript
// Signal to track selected folders for session_dirs filtering
const [selectedSessionDirs, setSelectedSessionDirsInternal] = createSignal<string[]>([]);

export { selectedSessionDirs };

/**
 * Set the entire session_dirs array
 */
export function setSelectedSessionDirs(dirs: string[]) {
  setSelectedSessionDirsInternal(dirs);
}
```

- [ ] **Step 3: Add helper function to add a folder**

Add after `setSelectedSessionDirs`:
```typescript
/**
 * Add a folder to session_dirs
 */
export async function addSelectedSessionDir(dir: string): Promise<void> {
  const current = selectedSessionDirs();
  if (!current.includes(dir)) {
    const updated = [...current, dir];
    setSelectedSessionDirsInternal(updated);
    await setSessionDirs(updated);
  }
}

/**
 * Remove a folder from session_dirs
 */
export async function removeSelectedSessionDir(dir: string): Promise<void> {
  const current = selectedSessionDirs();
  const updated = current.filter(d => d !== dir);
  setSelectedSessionDirsInternal(updated);
  await setSessionDirs(updated);
}
```

---

## Chunk 4: Frontend (SolidJS) — Sidebar UI with folder chips

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/components/Sidebar.tsx`

---

### Task 9: Add folder chips UI to Sidebar

**Modify:** `src/apps/desktop-bun/src/mainview/components/Sidebar.tsx`

- [ ] **Step 1: Read the file**

- [ ] **Step 2: Update imports**

Replace:
```typescript
import { getSessionDir } from '../utils/config';
```
With:
```typescript
import { getSessionDirs, addSessionDir as persistAddSessionDir, removeSessionDir as persistRemoveSessionDir } from '../utils/config';
import { selectedSessionDirs, setSelectedSessionDirs, addSelectedSessionDir, removeSelectedSessionDir } from '../store/sessionStore';
```

- [ ] **Step 3: Replace folder picker state management**

Replace lines 40-42:
```typescript
  // Folder picker state (modal only - open/close)
  const [folderPickerOpen, setFolderPickerOpen] = createSignal(false);
  // Current session_dir filter (loaded from config)
  const [currentSessionDir, setCurrentSessionDir] = createSignal<string | undefined>(undefined);
```
With:
```typescript
  // Folder picker state (modal only - open/close)
  const [folderPickerOpen, setFolderPickerOpen] = createSignal(false);
  // selectedSessionDirs is now in sessionStore
```

- [ ] **Step 4: Update the onMount to load session_dirs instead of single session_dir**

Replace lines 159-172:
```typescript
    // Load session_dir from config first
    setLoading(true);
    try {
      const savedDir = await getSessionDir();
      log.info(`[Sidebar] onMount loaded session_dir from config: ${savedDir}`);
      const sessionDir = savedDir !== '/' ? savedDir : undefined;
      setCurrentSessionDir(sessionDir);
      // Also update shared sessionStore so ChatInput uses the correct cwd_session
      setSelectedFolderValue(savedDir);
      fetchSessions(undefined, sessionDir).finally(() => setLoading(false));
    } catch (err) {
      log.warn('[Sidebar] onMount failed to load session_dir:', err);
      setCurrentSessionDir(undefined);
      fetchSessions(undefined, undefined).finally(() => setLoading(false));
    }
```

With:
```typescript
    // Load session_dirs from config first
    setLoading(true);
    try {
      const savedDirs = await getSessionDirs();
      log.info(`[Sidebar] onMount loaded session_dirs from config: ${JSON.stringify(savedDirs)}`);
      setSelectedSessionDirs(savedDirs);
      // Use first dir for backward compat with ChatInput cwd_session
      const firstDir = savedDirs.length > 0 ? savedDirs[0] : '/';
      setSelectedFolderValue(firstDir);
      fetchSessions(undefined, savedDirs).finally(() => setLoading(false));
    } catch (err) {
      log.warn('[Sidebar] onMount failed to load session_dirs:', err);
      setSelectedSessionDirs([]);
      fetchSessions(undefined, []).finally(() => setLoading(false));
    }
```

- [ ] **Step 5: Update fetchSessions call to pass session_dirs array**

Replace lines 54-58:
```typescript
        // Initial fetch with loaded session_dir
        if (initialized) {
          fetchSessions(undefined, sessionDir);
        }
```

With:
```typescript
        // Initial fetch with loaded session_dirs
        if (initialized) {
          fetchSessions(undefined, selectedSessionDirs());
        }
```

And update lines 92-100 to handle array:
```typescript
  const fetchSessions = async (cursor?: string, sessionDirs?: string[]) => {
    try {
      let url: string;

      if (sessionDirs && sessionDirs.length > 0) {
        // Fetch sessions filtered by session_dirs (comma-separated)
        const dirsParam = sessionDirs.map(d => encodeURIComponent(d)).join(',');
        url = cursor
          ? `${baseUrl()}/api/session?session_dirs=${dirsParam}&limit=20&cursor=${encodeURIComponent(cursor)}`
          : `${baseUrl()}/api/session?session_dirs=${dirsParam}&limit=20`;
      } else {
        // Fetch all sessions (existing behavior)
        url = cursor
          ? `${baseUrl()}/api/session?limit=20&cursor=${encodeURIComponent(cursor)}`
          : `${baseUrl()}/api/session?limit=20`;
      }
```

And update lazyLoadMore:
```typescript
  const lazyLoadMore = async () => {
    if (!hasMore() || loadingMore() || !nextCursor()) return;
    setLoadingMore(true);
    log.info(`[Sidebar] lazyLoadMore - selectedSessionDirs: ${JSON.stringify(selectedSessionDirs())}`);
    // Pass current session_dirs filter for pagination
    await fetchSessions(nextCursor()!, selectedSessionDirs());
    setLoadingMore(false);
  };
```

- [ ] **Step 6: Update handleFolderSelect to add to array instead of replace**

Replace lines 244-259:
```typescript
  // Handle folder selection
  const handleFolderSelect = async (path: string) => {
    log.info(`[Sidebar] Folder selected: ${path}`);
    const sessionDir = path !== '/' ? path : undefined;
    setCurrentSessionDir(sessionDir);
    // Also update shared sessionStore so ChatInput uses the correct cwd_session
    setSelectedFolderValue(path);
    setFolderPickerOpen(false);

    // Persist to config
    try {
      const { setSessionDir } = await import('../utils/config');
      await setSessionDir(path);
      log.info(`[Sidebar] Session dir persisted to config: ${path}`);
    } catch (err) {
      log.warn('[Sidebar] Failed to persist session_dir:', err);
    }

    // Reset and refetch sessions
    setSessions([]);
    setNextCursor(null);
    setHasMore(true);
    fetchSessions(undefined, sessionDir);
  };
```

With:
```typescript
  // Handle folder selection - adds to session_dirs
  const handleFolderSelect = async (path: string) => {
    log.info(`[Sidebar] Folder selected: ${path}`);
    // Add to session_dirs
    await addSelectedSessionDir(path);
    // Also update shared sessionStore so ChatInput uses the correct cwd_session
    setSelectedFolderValue(path);
    setFolderPickerOpen(false);

    // Reset and refetch sessions
    setSessions([]);
    setNextCursor(null);
    setHasMore(true);
    fetchSessions(undefined, selectedSessionDirs());
  };
```

- [ ] **Step 7: Add function to remove folder from session_dirs**

Add after `handleFolderSelect`:
```typescript
  // Handle folder removal
  const handleFolderRemove = async (path: string) => {
    log.info(`[Sidebar] Folder removed: ${path}`);
    await removeSelectedSessionDir(path);
    
    // Update cwd_session if we removed the active one
    const dirs = selectedSessionDirs();
    const firstDir = dirs.length > 0 ? dirs[0] : '/';
    setSelectedFolderValue(firstDir);

    // Reset and refetch sessions
    setSessions([]);
    setNextCursor(null);
    setHasMore(true);
    fetchSessions(undefined, dirs);
  };
```

- [ ] **Step 8: Add folder chips UI to the Sidebar render**

Find the section where the "Sessions" header is (around line 205). Add folder chips before it:

```tsx
        {/* Folder Chips Bar */}
        <div class="px-4 mb-2 flex items-center gap-2 flex-wrap">
          <For each={selectedSessionDirs()}>
            {(dir) => {
              const dirName = dir.split('/').filter(Boolean).pop() || dir;
              return (
                <div class="flex items-center gap-1 px-2 py-1 bg-[#18181b] border border-[#27272a] hover:border-[#fbbf24] group transition-colors">
                  <span class="text-xs font-mono text-[#71717a] group-hover:text-[#fbbf24]" title={dir}>
                    📁 {dirName}
                  </span>
                  <button
                    onClick={() => handleFolderRemove(dir)}
                    class="ml-1 w-4 h-4 flex items-center justify-center text-[#52525b] hover:text-[#ef4444] transition-colors"
                    title="Remove folder"
                  >
                    ×
                  </button>
                </div>
              );
            }}
          </For>
          <button
            onClick={() => setFolderPickerOpen(true)}
            class="flex items-center justify-center w-6 h-6 rounded bg-[#18181b] hover:bg-[#27272a] border border-[#3f3f46] hover:border-[#fbbf24] text-[#52525b] hover:text-[#fbbf24] transition-all text-lg font-bold"
            title="Add folder"
          >
            +
          </button>
        </div>
```

Replace the FolderPicker button in the header (around line 290):
```tsx
          {/* Folder Picker Button - Now opens add folder */}
          <button
            onClick={() => setFolderPickerOpen(true)}
            class="flex items-center justify-center w-7 h-7 rounded-md bg-[#18181b] hover:bg-[#27272a] border border-[#3f3f46] hover:border-[#fbbf24] text-[#52525b] hover:text-[#fbbf24] transition-all font-mono shadow-sm"
            title="Add Folder"
          >
            <span class="text-base">📁</span>
          </button>
```

- [ ] **Step 9: Update FolderPicker props**

Replace the FolderPicker component at bottom:
```tsx
      {/* Folder Picker Modal */}
      <FolderPicker
        isOpen={folderPickerOpen()}
        onSelect={handleFolderSelect}
        onClose={() => setFolderPickerOpen(false)}
      />
```

---

## Chunk 5: SessionChat updates (minor)

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`

---

### Task 10: Update SessionChat to use session_dirs array

**Modify:** `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`

- [ ] **Step 1: Read the file to find config loading code**

- [ ] **Step 2: Update config imports**

Replace:
```typescript
import { getSessionDir, setSessionDir as saveSessionDir } from '../utils/config';
```

With:
```typescript
import { getSessionDirs, setSessionDirs } from '../utils/config';
```

- [ ] **Step 3: Update state and effects to use array**

Replace lines 252-293 with:
```typescript
  // FolderPicker state
  const [folderPickerOpen, setFolderPickerOpen] = createSignal(false);
  const [sessionDirs, setSessionDirsState] = createSignal<string[]>([]);
  const [configLoaded, setConfigLoaded] = createSignal(false);

  // Load saved session directories from config on mount
  createEffect(async () => {
    if (!configLoaded()) {
      try {
        const savedDirs = await getSessionDirs();
        if (savedDirs.length > 0) {
          setSessionDirsState(savedDirs);
        }
        setConfigLoaded(true);
      } catch (err) {
        console.warn('[SessionChat] Failed to load session_dirs from config:', err);
        setConfigLoaded(true);
      }
    }
  });

  // Handle folder selection
  const handleFolderSelect = async (path: string) => {
    console.log('[SessionChat] Folder selected:', path);
    // Add to session_dirs
    const current = sessionDirs();
    if (!current.includes(path)) {
      const updated = [...current, path];
      setSessionDirsState(updated);
      await setSessionDirs(updated);
    }
    setFolderPickerOpen(false);
  };
```

- [ ] **Step 4: Update FolderPicker component props**

Replace FolderPicker at bottom:
```tsx
      {/* Folder Picker Modal */}
      <FolderPicker
        isOpen={folderPickerOpen()}
        onSelect={handleFolderSelect}
        onClose={() => setFolderPickerOpen(false)}
      />
```

---

## Verification

### Backend (Zig)
- [ ] `zig build` compiles without errors
- [ ] `zig build test` passes

### Frontend (Bun)
- [ ] `cd src/apps/desktop-bun && bun run dev` starts without errors
- [ ] Open desktop app
- [ ] Click 📁 button → select a folder → folder chip appears
- [ ] Add another folder → both show as chips
- [ ] Sessions from both folders appear in sidebar
- [ ] Click × on a chip → folder removed, sessions update
- [ ] Close and reopen app → folders persist

---

## Summary of Files Modified

| File | Changes |
|------|---------|
| `src/ai_workflow/tui/session_db.zig` | `getSessionListWithCursor` accepts `session_dirs: ?[][]const u8` |
| `src/ai_workflow/tui/http_handlers/session_list.zig` | Parse `session_dirs` comma-separated, pass array to DB |
| `src/apps/desktop-bun/src/bun/db/index.ts` | Add `dbGetSessionDirs`, `dbSetSessionDirs`, `dbAddSessionDir`, `dbRemoveSessionDir` |
| `src/apps/desktop-bun/src/bun/config-handlers.ts` | Add handlers for new functions |
| `src/apps/desktop-bun/src/bun/index.ts` | Register new RPC handlers |
| `src/apps/desktop-bun/src/mainview/utils/config.ts` | Rewrite to use `session_dirs` array |
| `src/apps/desktop-bun/src/mainview/store/sessionStore.tsx` | Add `selectedSessionDirs` signal + helpers |
| `src/apps/desktop-bun/src/mainview/components/Sidebar.tsx` | Add folder chips UI |
| `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx` | Update to use `session_dirs` |
