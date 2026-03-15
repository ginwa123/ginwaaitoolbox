# Background Process Tracking Feature Design

> **Status:** Approved - Ready for Implementation

## Overview

Track background bash processes spawned during agent sessions in SQLite database, similar to how `session_skills` are tracked. This enables process status monitoring and proper cleanup on session cancellation.

## Requirements Confirmed

1. ✅ Poll and update status: 'running' → 'completed'/'failed' periodically
2. ✅ Only background processes (not foreground)
3. ✅ Keep log files forever (current behavior)

---

## Architecture

### New Database Table: `session_background_process`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `session_id` | TEXT | NOT NULL, PK part 1 | Session identifier |
| `pid` | INTEGER | NOT NULL, PK part 2 | Process ID from OS |
| `command` | TEXT | NOT NULL | The bash command executed |
| `log_path` | TEXT | NOT NULL | Path to stdout/stderr log file |
| `started_at` | INTEGER | NOT NULL | Unix timestamp when started |
| `status` | TEXT | NOT NULL DEFAULT 'running' | Process status: 'running', 'completed', 'failed', 'killed' |

**Primary Key:** `(session_id, pid)`  
**Indexes:** `idx_bg_process_session` on `session_id`

---

## Data Flow

### 1. Save Background Process (on spawn)

When bash tool is called with `background: true`:

```
1. Spawn process via nohup (existing behavior)
2. Get PID from shell output
3. Generate log path (/tmp/bg_{timestamp}.log)
4. INSERT INTO session_background_process VALUES (session_id, pid, command, log_path, started_at, 'running')
```

### 2. Retrieve Background Processes

Similar to skills retrieval pattern (build_skill_content.zig):

```zig
// Query: SELECT pid, command, log_path, started_at, status 
//        FROM session_background_process WHERE session_id = ?
while (try rows.next()) |row| {
    // Build process info for UI/agent
}
```

### 3. Poll and Update Status

Background loop (can be integrated with existing session monitor):

```
1. Query all 'running' processes for session
2. For each process, check if PID still exists (kill -0)
3. If process exists → status = 'running'
4. If process completed (exit code 0) → status = 'completed'
5. If process failed (exit code != 0) → status = 'failed'
6. If process was killed → status = 'killed'
7. UPDATE status in database
```

### 4. Cleanup on Session Cancellation

When session is cancelled:

```
1. Query all 'running' processes for session
2. For each process, send SIGTERM/SIGKILL to PID
3. UPDATE status to 'killed'
4. (Log files kept forever per requirement)
```

---

## Reference Patterns

### Skills Save Pattern (save_skill.zig)
```zig
try db.execute(
    "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content) VALUES (?, ?, ?)",
    .{ session_id, skill_name, content },
);
```

### Skills Retrieve Pattern (build_skill_content.zig)
```zig
var rows = try db.query(
    "SELECT skill_name, content FROM session_skills WHERE session_id = ?",
    .{session_id},
);
defer rows.deinit();

while (try rows.next()) |row| {
    const skill_name = row.values[0];
    const content = row.values[1];
    // Build content...
}
```

---

## File Changes

### New Files
- `src/modules/databases/sqlite/background_process.zig` - Database operations for background processes

### Modified Files
- `src/modules/databases/sqlite/migrations.zig` - Add migration for new table
- `src/modules/agent/tools/bash.zig` - Register process with database on spawn
- `src/modules/session/cancellation_registry.zig` - Add method to kill background processes
- `src/modules/session/session_monitor.zig` - Add periodic status polling

---

## Integration Points

1. **bash.zig** - Call save function after spawning background process
2. **session cancellation** - Call kill all processes function
3. **session monitor** - Add polling loop for status updates
4. **TUI/UI** - Optionally display running background processes

---

## Testing Strategy

1. Unit tests for background_process.zig (CRUD operations)
2. Integration test for bash spawn → save → query flow
3. Integration test for status polling
4. Integration test for cancellation → kill flow

---

## Notes

- Process status checking uses `kill(pid, 0)` to check if process exists without sending signal
- Exit code from last process output can be parsed from log file or tracked separately
- Consider adding `exit_code` column for future enhancement
