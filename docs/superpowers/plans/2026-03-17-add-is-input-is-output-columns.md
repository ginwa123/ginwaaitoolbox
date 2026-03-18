# Add is_input and is_output Columns to llm_history

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new boolean columns (`is_input`, `is_output`) to the `llm_history` table to distinguish between messages sent TO the LLM vs received FROM the LLM.

**Architecture:** Add new migration that adds `is_input` and `is_output` columns as INTEGER (0/1), then update all INSERT statements to set these values appropriately.

**Tech Stack:** Zig 0.15.2, SQLite

---

## Chunk 1: Database Migration

### Task 1: Create Migration to Add is_input and is_output Columns

**Files:**
- Modify: `src/modules/databases/sqlite/migrations.zig`
- Test: N/A (migration tested implicitly via existing tests)

- [ ] **Step 1: Add Migration016AddInputOutputColumns to migrations.zig**

Add this migration after Migration015AddSessionAgents:

```zig
pub const Migration016AddInputOutputColumns = struct {
    pub const version: u32 = 16;
    pub const name = "add_input_output_columns";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_input INTEGER DEFAULT 0", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE llm_history ADD COLUMN is_output INTEGER DEFAULT 0", &[_][]const u8{});
    }
};
```

- [ ] **Step 2: Add migration to allMigrations slice**

Add to the `allMigrations` slice in `migrations.zig`:

```zig
.{ .version = Migration016AddInputOutputColumns.version, .name = Migration016AddInputOutputColumns.name, .up = Migration016AddInputOutputColumns.up },
```

- [ ] **Step 3: Build to verify**

Run: `zig build 2>&1 | head -n 50`
Expected: SUCCESS (no errors)

---

## Chunk 2: Update INSERT Statements

### Task 2: Update save_message.zig INSERT Statement

**Files:**
- Modify: `src/ai_workflow/tui/save_message.zig:71`

- [ ] **Step 1: Update INSERT SQL to include is_input and is_output**

Current (line 71):
```zig
const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
```

Updated:
```zig
const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens, is_input, is_output) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
```

- [ ] **Step 2: Add is_input and is_output parameters to the bind call**

Find where parameters are bound and add two more values at the end:
- For save_message (which saves LLM responses): is_output should be 1, is_input should be 0
- Look for the `try self.db.bind` calls and add the two new values

- [ ] **Step 3: Build to verify**

Run: `zig build 2>&1 | head -n 50`
Expected: SUCCESS (no errors)

### Task 3: Update tui_workflow.zig INSERT Statement

**Files:**
- Modify: `src/ai_workflow/tui/tui_workflow.zig:470`

- [ ] **Step 1: Update INSERT SQL to include is_input and is_output**

Current (line 470):
```zig
const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)";
```

Updated - add is_input and is_output at the end:
```zig
const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, created_at, is_input, is_output) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)";
```

- [ ] **Step 2: Add is_input and is_output parameters**

Find where the statement is executed and add:
- is_input: 0 (tui_workflow saves LLM output responses)
- is_output: 1

- [ ] **Step 3: Build to verify**

Run: `zig build 2>&1 | head -n 50`
Expected: SUCCESS (no errors)

### Task 4: Update create_session.zig INSERT Statement

**Files:**
- Modify: `src/ai_workflow/kerjabot/create_session.zig:18`

- [ ] **Step 1: Update INSERT SQL to include is_input and is_output**

Current (line 18):
```zig
const insert_sql = "INSERT INTO llm_history (id, session_id, model, response_content, role, agent, temperature, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))";
```

Updated:
```zig
const insert_sql = "INSERT INTO llm_history (id, session_id, model, response_content, role, agent, temperature, created_at, is_input, is_output) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), ?, ?)";
```

- [ ] **Step 2: Add is_input and is_output parameters**

Add parameters for is_input and is_output:
- is_input: 0 (this is a session creation record, not input to LLM)
- is_output: 1 (the initial response from LLM when session is created)

- [ ] **Step 3: Build to verify**

Run: `zig build 2>&1 | head -n 50`
Expected: SUCCESS (no errors)

---

## Chunk 3: Final Verification

### Task 5: Final Build Verification

**Files:**
- N/A

- [ ] **Step 1: Run full build**

Run: `zig build 2>&1 | head -n 100`
Expected: SUCCESS (all code compiles)

- [ ] **Step 2: Run tests if any**

Run: `zig test 2>&1 | head -n 50`
Expected: All tests pass

---

## Summary

After this plan is executed, the `llm_history` table will have two new columns:
- `is_input INTEGER DEFAULT 0` - Set to 1 when the row contains content sent TO the LLM
- `is_output INTEGER DEFAULT 0` - Set to 1 when the row contains content received FROM the LLM

This allows queries to easily filter messages by direction:
- `SELECT * FROM llm_history WHERE is_input = 1` - All messages sent to LLM
- `SELECT * FROM llm_history WHERE is_output = 1` - All responses from LLM
