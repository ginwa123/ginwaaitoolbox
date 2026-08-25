# delete_memory Agent Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new LLM agent tool `delete_memory({ id })` that permanently removes a row from the SQLite `agent_memories` store (and its FTS5 index), wired end-to-end: storage layer → tool module → exec wrapper → registry → prompts → frontend tool-output card.

**Architecture:** Mirror the existing `save_memory` / `load_memory` pattern exactly. A pure function `deleteMemory(allocator, db, id) !bool` in `agent_memories.zig` issues `DELETE FROM agent_memories WHERE id = ?` — the `agent_memories_ad` AFTER DELETE trigger (already installed by Migration 070) keeps the FTS5 index in sync automatically. A new `delete_memory.zig` tool module defines the input struct + `AgentTool` schema + XML envelope builders; a 48-line exec wrapper parses JSON and delegates; the registry entry makes it discoverable by `dispatchTool` with zero dispatch-code changes. Frontend gets a small presentational Vue component following `SaveMemory.vue`.

**Tech Stack:** Zig 0.16 (std.json, nalarcore sqlite backend), SQLite + FTS5 (Migration 070 schema), Vue 3 `<script setup>` + vitest.

## Global Constraints

- **Do NOT touch port 8081** (mandatory project rule). No live-server testing needed for this task anyway — all verification is `zig build test --summary all` + `bun run test:unit`.
- **No migration needed.** Migration 070 already created the `agent_memories_ad` AFTER DELETE trigger specifically as future-proofing for this feature. Do NOT add a new migration.
- **Delete is permanent by design** — there is no soft-delete, no undo. The tool description and prompt rule must say so explicitly so the LLM treats it as a deliberate action.
- **Wire format:** single required string param `id`. No arrays on the wire (project convention). Empty `id` is a validation error.
- **Idempotent semantics:** deleting a non-existent id returns success with `<deleted>false</deleted>`, not an error. The LLM should not retry or treat it as failure.
- **Zig style:** follow sibling files exactly — inline `test "..."` blocks at the bottom of each impl file, registered via `_ = @import(...)` in the directory's `test_runner.zig`.
- **Known pre-existing failures:** ~36 tests fail/leak/crash on main HEAD unrelated to this work (see memory `mem_a1eabbc7daa573fa`). Compare against baseline before/after; do not chase them.
- **Worktree gotcha:** fresh worktrees need `node_modules` symlinked from the main repo (`ln -s /home/ginwa/ginwaaitoolbox/src/apps/desktop/node_modules src/apps/desktop/node_modules`) before `bun run test:unit`.

## File Map (all changes)

| # | File | Action | Purpose |
|---|------|--------|---------|
| 1 | `src/ai_workflow/tui/agentic_loop/agent_memories.zig` | EDIT | Add `pub fn deleteMemory(allocator, db, id) !bool` + tests |
| 2 | `src/modules/agent/tools/delete_memory.zig` | NEW | Input struct, `AgentTool` schema, `executeDeleteMemory`, XML envelopes, tests |
| 3 | `src/root.zig` (~line 497) | EDIT | `pub const delete_memory = @import("modules/agent/tools/delete_memory.zig");` |
| 4 | `src/modules/agent/test_runner.zig` (~line 85) | EDIT | `_ = @import("tools/delete_memory.zig");` |
| 5 | `src/ai_workflow/tui/agentic_loop/tools_exec_delete_memory.zig` | NEW | Exec wrapper (mirror `tools_exec_save_memory.zig`) |
| 6 | `src/ai_workflow/tui/agentic_loop/tools.zig` (~line 20) | EDIT | `pub const execDeleteMemory = @import("tools_exec_delete_memory.zig").execDeleteMemory;` |
| 7 | `src/ai_workflow/tui/agentic_loop/test_runner.zig` | EDIT | `_ = @import("tools_exec_delete_memory.zig");` |
| 8 | `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (lines 17, 81, 164) | EDIT | Import mod, add to `equips()`, add registry entry |
| 9 | `src/modules/agent/prompts/core.zig` (lines 76–83) | EDIT | Update `MemoryToolRule`: THREE tools now; drop "no delete_memory" claim |
| 10 | `src/apps/desktop/src/components/tool_outputs/DeleteMemory.vue` | NEW | Presentational tool-output card |
| 11 | `src/apps/desktop/src/components/views/ChatView.vue` (lines 52–53, 3069–3078) | EDIT | Import + dispatcher branch |
| 12 | `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue` (lines 353–360) | EDIT | Dispatcher branch |
| 13 | `src/apps/desktop/src/components/tool_outputs/__tests__/DeleteMemory.spec.ts` | NEW | Vitest spec |

Out of scope (deliberate): `src/migrations/migration.zig:3464` comment says "no delete_memory tool by user decision" — historical migration comments are immutable records of past state; leave as-is. `prompts/special.zig` cross-session handoff block stays save/load-only (compaction agents must never delete user data).

---

## Task 1 — Storage layer: `deleteMemory` in agent_memories.zig

The single source of truth for deletion. Everything else calls this.

- [ ] Write failing tests first. Append to the inline test block section of `src/ai_workflow/tui/agentic_loop/agent_memories.zig` (tests start at line 446; copy the `setupDb()` helper usage from `test "saveMemory: inserts a new row..."` at line 519):

```zig
test "deleteMemory: removes an existing row and returns true" {
    // setupDb(); saveMemory(.{ .content = "x", .tags = &.{}, .id = "del-me" });
    // try std.testing.expect(try deleteMemory(alloc, db, "del-me"));
    // try std.testing.expectEqual(@as(?MemoryRow, null), try getMemoryById(alloc, db, "del-me"));
}

test "deleteMemory: returns false for unknown id (idempotent)" {
    // expect(deleteMemory(...) == false); no error raised
}

test "deleteMemory: empty id returns InvalidId" {
    // expectError(error.InvalidId, deleteMemory(alloc, db, ""));
}

test "deleteMemory: FTS5 index no longer finds deleted content" {
    // saveMemory(content="unique-delete-marker-xyz", tags=&.{"fts"});
    // loadMemoriesByFts(query="unique-delete-marker-xyz") -> 1 hit
    // deleteMemory(id)
    // loadMemoriesByFts again -> 0 hits   ← proves the _ad trigger fired
}
```

- [ ] Run `zig build test --summary all 2>&1 | rg "deleteMemory"` — confirm the 4 new tests FAIL (compile error: function doesn't exist yet is acceptable TDD failure).
- [ ] Implement. Insert after `getMemoryById` (after line 167, before `freeMemoryRow`):

```zig
/// Delete a memory by id. Returns `true` when a row was removed,
/// `false` when no row matched (idempotent — callers treat both as
/// success). The `agent_memories_ad` AFTER DELETE trigger (Migration
/// 070) removes the matching FTS5 index entry automatically.
///
/// Errors:
///   - `error.InvalidId` — id is empty
///   - DB errors propagate verbatim
pub fn deleteMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !bool {
    if (id.len == 0) return error.InvalidId;

    const sql = "DELETE FROM agent_memories WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
    return db.changes() > 0;
}
```

Note: `db.changes()` exists at `src/modules/databases/src/sqlite/Sqlite.zig:699` returning `i64`. Call it immediately after `exec` — it reads `sqlite3_changes` for the most recent statement on that connection.

- [ ] Run `zig build test --summary all 2>&1 | rg "deleteMemory"` — all 4 pass.
- [ ] Commit: `feat(memory): add deleteMemory storage primitive to agent_memories`

## Task 2 — Tool module: delete_memory.zig

- [ ] Write failing tests first. Create `src/modules/agent/tools/delete_memory.zig` containing ONLY the test blocks initially (plus minimal stubs so it compiles), mirroring `save_memory.zig`'s test style (line 229+). Tests to write:

```zig
test "delete_memory_tool: tool name is 'delete_memory'"
// asserts tool.function.name == "delete_memory"

test "delete_memory_tool: parameters include only id, which is required"
// asserts properties.len == 1, properties[0].name == "id", required == &.{"id"}

test "delete_memory_tool: returns success envelope with deleted=true on existing row"
// setupDb-style :memory: DB; saveMemory first; executeDeleteMemory;
// assert output contains <success> shape: <delete_memory><id>...</id><deleted>true</deleted></delete_memory>

test "delete_memory_tool: returns success envelope with deleted=false on unknown id"
// assert <deleted>false</deleted>, NO <error>

test "delete_memory_tool: returns error envelope on empty id"
// assert <delete_memory><error>...id is required...</error></delete_memory>

test "delete_memory_tool: round-trip — deleted row is gone from getMemoryById"
```

- [ ] Register in `src/modules/agent/test_runner.zig` next to line 85 (`_ = @import("tools/save_memory.zig");`): add `_ = @import("tools/delete_memory.zig");`
- [ ] Run `zig build test --summary all 2>&1 | rg "delete_memory"` — confirm failures.
- [ ] Implement the full file, structurally mirroring `save_memory.zig`:

```zig
//! delete_memory — permanent removal of one agent-memory row.
//!
//! Wire: delete_memory({ id }) — id is REQUIRED (the exact id returned
//! by save_memory / load_memory). Deleting an unknown id succeeds with
//! <deleted>false</deleted>. There is NO undo.

pub const DeleteMemoryInput = struct { id: []const u8 = "" };

pub const delete_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_memory",
        .description =
        \\Permanently delete ONE saved memory by its exact `id`.
        \\...
        ,
        .parameters = .{ .type = "object", .properties = &.{
            .{ .name = "id", .type = "string", .description = "Exact memory id (mem_<16-hex> or caller slug)" },
        }, .required = &.{"id"} },
    },
};

pub fn executeDeleteMemory(allocator, db, input: DeleteMemoryInput) ![]u8 {
    // empty id -> errorXml("id is required...")
    // deleted = try agent_memories.deleteMemory(...)
    // return successXml(id, deleted)
}
```

Envelope shapes (keep consistent with siblings):
- Success: `<delete_memory><id>{id}</id><deleted>true|false</deleted><note>...</note></delete_memory>`
- Error: `<delete_memory><error>{msg}</error></delete_memory>`
- XML-escape the echoed `id` with `helpers.xml_escape` (same import pattern as `save_memory.zig` line 44).
- Tool `.description` must include: permanent/no-undo warning, "get the id from `load_memory` first when unsure", and the idempotency note.

- [ ] Run `zig build test --summary all 2>&1 | rg "delete_memory"` — all pass.
- [ ] Export from root: in `src/root.zig` directly below line 497 (`pub const load_memory = ...`) add:
  `pub const delete_memory = @import("modules/agent/tools/delete_memory.zig");`
- [ ] Commit: `feat(tools): add delete_memory tool module with schema + envelopes`

## Task 3 — Exec wrapper + registry wiring

- [ ] Write failing static-contract tests first. Create `src/ai_workflow/tui/agentic_loop/tools_exec_delete_memory.zig` with the wrapper implementation AND inline tests at the bottom (pattern used by `tools_exec_update_plan.zig` per test_runner comment line 42). Tests:

```zig
test "execDeleteMemory: surfaces inner <error> as success=false"
// Build fake ToolCall with arguments = {"id":""}; call execDeleteMemory with
// a ctx whose db is a :memory: migrated DB; assert output contains
// success=false and the error text. Copy ctx-construction from
// tools_exec_get_plan.zig's inline tests.

test "execDeleteMemory: happy path wraps success=true"
// arguments = {"id":"x"} after saving x; assert output contains
// <success>true</success> and <deleted>true</deleted>
```

- [ ] Register in `src/ai_workflow/tui/agentic_loop/test_runner.zig` (add near line 42): `_ = @import("tools_exec_delete_memory.zig");`
- [ ] Run `zig build test --summary all 2>&1 | rg "execDeleteMemory"` — confirm failures.
- [ ] Implement the wrapper — byte-for-byte mirror of `tools_exec_save_memory.zig` (48 lines) with these substitutions: `save_memory_mod` → `nalarcore.delete_memory`, `SaveMemoryInput` → `DeleteMemoryInput`, `executeSaveMemory` → `executeDeleteMemory`, tool-name strings `"save_memory"` → `"delete_memory"`. Keep the three branches identical: JSON parse failure → wrapToolOutput(false), inner `<error>` detection → wrapToolOutput(false, err_msg, inner), success → wrapToolOutput(true, null, inner).
- [ ] Re-export: in `src/ai_workflow/tui/agentic_loop/tools.zig` next to line 19 add:
  `pub const execDeleteMemory = @import("tools_exec_delete_memory.zig").execDeleteMemory;`
- [ ] Registry — `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`, three edits:
  1. Line ~18 (after `load_memory_mod`): `const delete_memory_mod = nalarcore.delete_memory;`
  2. Line ~81 (after `load_memory_mod.load_memory_tool` in `equips()`): `delete_memory_mod.delete_memory_tool,`
  3. Line ~164 (in `UNIFIED_TOOL_REGISTRY()` under `// === MEMORY TOOLS ===`):
     `.{ .name = "delete_memory", .exec = tools.execDeleteMemory, .tool_def = delete_memory_mod.delete_memory_tool },`
  
  No other dispatch edits — `handle_tool.zig` discovers tools purely from this registry.
- [ ] Run `zig build test --summary all --summary all` full suite — new tests pass, no NEW failures vs baseline (~36 pre-existing non-pass documented in memory `mem_a1eabbc7daa573fa`).
- [ ] Commit: `feat(agentic-loop): wire delete_memory into exec layer + unified registry`

## Task 4 — Prompt rule update (MemoryToolRule)

The system prompt currently tells every agent the tool does NOT exist. This must flip in the same PR, or the model will distrust/hallucinate around the new capability.

- [ ] Edit `src/modules/agent/prompts/core.zig` `MemoryToolRule` (lines 67–107):
  - Line 68 heading: `## Memory Tools — save_memory + load_memory (FTS5, cross-session) — MANDATORY USE` → `## Memory Tools — save_memory + load_memory + delete_memory (FTS5, cross-session) — MANDATORY USE`
  - Line 76: `**TWO TOOLS — UPSERT + FTS SEARCH:**` → `**THREE TOOLS — UPSERT + FTS SEARCH + PERMANENT DELETE:**`
  - After line 78 insert:
    ```
    \\- `delete_memory({ id })` — PERMANENTLY removes one row (no undo, no soft-delete). Pass the exact `id` from a prior `save_memory`/`load_memory`. Unknown id → `<deleted>false</deleted>` (not an error). Deleting an unknown/superseded note is fine; NEVER delete a user-preference memory unless the user explicitly asks.
    ```
  - Line 83: replace `- Storage is **permanent** — there is no \`delete_memory\` tool by design. To "forget" something, \`save_memory\` a new entry that supersedes it.` with:
    `- Storage is durable but not sacred — \`save_memory\` upserts supersede old content, and \`delete_memory({ id })\` permanently removes a row when it's genuinely obsolete (e.g. user asks to forget, or a correction invalidates the old note entirely). When in doubt, prefer overwriting via \`save_memory\` over deleting.`
- [ ] Check `src/modules/agent/tools/save_memory.zig` tool description (line ~79 contains "There is NO delete_memory tool"): update that sentence to point at the new tool instead ("To remove an entry entirely, use `delete_memory({ id })`."). Keep the rest of the description untouched.
- [ ] Leave `src/migrations/migration.zig:3464` historical comment untouched (immutable record).
- [ ] Run `zig build test --summary all 2>&1 | rg "prompts"` — note: some `modules.agent.prompts_test` failures are PRE-EXISTING (memory `mem_a1eabbc7daa573fa` lists 6). Verify no NEW failures beyond those.
- [ ] Commit: `feat(prompts): document delete_memory in MemoryToolRule, drop 'no delete tool' claim`

## Task 5 — Frontend: DeleteMemory.vue + dispatchers

- [ ] Create `src/apps/desktop/src/components/tool_outputs/DeleteMemory.vue` — copy `SaveMemory.vue` (205 lines) and simplify:
  - Props: `{ content: string, expanded?: boolean }` (identical).
  - Parsers: `errorMessage` (`/<error>([\s\S]*?)<\/error>/`), `memoryId` (`/<id>...<\/id>/`), `deleted` (`/<deleted>([\s\S]*?)<\/deleted>/` → boolean via `=== 'true'`).
  - Header: `delete_memory → <truncated id> ✓` on success; `delete_memory → error ✗` on failure. Show `∅` glyph or "removed" chip when `deleted === true`; show "not found" muted chip when `deleted === false`.
  - Expanded body: id row (with copy button, reuse SaveMemory's), deleted status row, and a persistent red-tinted note: "Deletion is permanent."
  - Keep the same scoped styling conventions (monospace, rounded-md, violet tool-name, ✗/✓).
- [ ] Wire ChatView.vue:
  - Line ~53: `import DeleteMemory from '../tool_outputs/DeleteMemory.vue'`
  - After the LoadMemory branch (line 3074–3078) insert:
    ```vue
    <DeleteMemory
      v-else-if="msg.tool_name === 'delete_memory'"
      :content="innerToolData(msg)"
      :expanded="expandedToolIds.has(toolExpandKey(msg, groupIndex, idx))"
    />
    ```
- [ ] Wire SubAgentPeekPanel.vue (sub-agent transcripts render tool cards too):
  - Add `DeleteMemory` import alongside the existing SaveMemory/LoadMemory imports.
  - After line 356–360 (LoadMemory branch) insert the same branch WITHOUT the `expanded` prop (matching its siblings: `:content="innerToolData(msg) ?? msg.content"`).
- [ ] Write failing vitest spec FIRST (before creating the .vue, or stub-and-fill): create `src/apps/desktop/src/components/tool_outputs/__tests__/DeleteMemory.spec.ts` modeled on `__tests__/SaveMemory.spec.ts`. Cover: renders success header with truncated id; shows "removed" state for `<deleted>true</deleted>`; shows "not found" state for `<deleted>false</deleted>`; renders error block for `<error>` body; expand toggle works.
- [ ] Run `cd src/apps/desktop && bun run test:unit -- DeleteMemory` — pass. (In a fresh worktree: symlink node_modules first — see Global Constraints.)
- [ ] Typecheck/build: `bun run build` (vue-tsc + vite) clean.
- [ ] Commit: `feat(desktop): render delete_memory tool output card in chat + sub-agent peek panel`

## Task 6 — Full verification + docs

- [ ] Backend: `zig build test --summary all` — compare to baseline; ZERO new failures/leaks vs the documented pre-existing set.
- [ ] Frontend: `bun run test:unit` full suite green (baseline ~2509 passing per memory `mem_04ef2b6a7a7d7625`); `bun run build` clean.
- [ ] Grep sweep — the SSE-pairs lesson applies to tool names too; verify consistency:
  ```bash
  rg -n "delete_memory" src/ | sort
  ```
  Expected hits: agent_memories.zig (fn + tests), delete_memory.zig, root.zig, tools.zig, tools_exec_delete_memory.zig, tools_equipped.zig (×3 sites), prompts/core.zig, save_memory.zig (description pointer), ChatView.vue, SubAgentPeekPanel.vue, DeleteMemory.vue + spec, modules/agent/test_runner.zig, agentic_loop/test_runner.zig. Any site missing = incomplete wiring.
- [ ] Manual smoke (optional, no server): run the desktop app dev build, ask an agent session to `save_memory` then `delete_memory` the returned id, confirm the card renders and a subsequent `load_memory` by-id returns "not found".
- [ ] Update AGENTS.md changelog with a dated entry (follow the format of the 2026-08-19 entries).
- [ ] Commit: `docs: changelog entry for delete_memory agent tool`
- [ ] Open PR from `worktree/delete-memory-agent-tool` for human review; move kanban task to `in_review_task`.

## Notes

- **Why `db.changes()`:** simplest reliable "did anything get deleted" signal without a pre-SELECT. Alternative (SELECT existence first) costs an extra query and has a TOCTOU gap; `changes()` is atomic with the DELETE.
- **Why no confirmation prompt in the tool:** the guardrail lives in the prompt rule ("NEVER delete unless user asks") + permanence messaging, matching how `remove_file`/`remove_skill` already behave in this codebase.
- **FTS sync proof:** Task 1's fourth test is the critical one — it proves Migration 070's `agent_memories_ad` trigger actually fires on plain DELETE (the migration author installed it for exactly this future feature but it has never been exercised).
