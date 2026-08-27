# save_memory: id always appends nano suffix (dedup-proof) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `save_memory` call produces a UNIQUE row id — the `id` always gets a unix-nanosecond suffix appended (auto-generated AND caller-provided ids alike), so a repeated save with the same slug can never collide with or overwrite an earlier row.

**Architecture:** No schema change, no migration. The change is confined to `agent_memories.saveMemory`'s id resolution step: instead of "empty → generate, non-empty → use as-is", it becomes "always append `-<unix-nano>` to whatever id is in play". The `INSERT OR REPLACE` statement stays (it's now effectively a plain INSERT — the PK collision case becomes unreachable), and the tool description + tests are updated to document the new uniqueness contract.

**Tech Stack:** Zig 0.16 (`std.time.nanoTimestamp()` → i128), SQLite via `SqliteBackend`, existing Migration 070 schema untouched.

## Global Constraints

- **Never kill the port 8081 server.** For any manual testing use port 8080 or another free port. (No HTTP surface changes in this task.)
- **NO new column, NO migration.** The user explicitly rejected the `created_at_nano` column approach. The nano stamp lives INSIDE the `id` string itself.
- **Nano format inside id:** decimal unix nanoseconds from `std.time.nanoTimestamp()` (i128), formatted `{d}`. Appended as `<id>-<nano>` for caller-provided slugs, or `mem_<16-hex>-<nano>` for auto-generated ones.
- **Every call = new row.** Two saves with identical content + identical slug create TWO rows. This is intentional ("to handle case duplicated" — the user wants duplicates preserved, not merged).
- **FTS5 contract untouched:** `agent_memories_fts` indexes `content` + `tags` only; triggers mirror automatically on INSERT — no changes needed since we still go through plain SQL INSERT/REPLACE on the source table.
- **Blast radius verified:** `saveMemory` has exactly ONE caller (`src/modules/agent/tools/save_memory.zig::executeSaveMemory`). `load_memory.zig` consumes by id passthrough (getMemoryById / FTS) — unaffected. `models/agent_memory.zig` is a passive model — no id-format logic.
- **Wire shape unchanged:** input `{content, tags?, id?}` stays; only the SEMANTICS of `id` change (it's now a prefix/slug, not a primary key). Output XML `<id>` echoes the final suffixed id so the agent learns the real lookup key.
- **Test convention:** walk all migrations from scratch (`registerAllMigrations`) on `:memory:`; no hand-rolled CREATE TABLE.
- **Commit after each task.**

## Files

| File | Action | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/agent_memories.zig` | EDIT | Id-resolution logic in `saveMemory`: always append nano suffix; update doc comments + inline tests |
| `src/modules/agent/tools/save_memory.zig` | EDIT | Tool description + param docs reflect "id is a slug; nano suffix auto-appended; every save = unique row"; update inline tests |

---

## Task 1 — Storage layer: always append nano suffix to id

### Steps

- [ ] **1.1 Write failing tests** in `src/ai_workflow/tui/agentic_loop/agent_memories.zig` inline test section:
  - Test "saveMemory: caller-provided id gets nano suffix appended":
    ```zig
    const row = try saveMemory(alloc, &ctx.db, .{
        .content = "note body long enough",
        .tags = &.{},
        .id = "user-preferred-model",
    });
    defer freeMemoryRow(alloc, row);
    try testing.expect(std.mem.startsWith(u8, row.id, "user-preferred-model-"));
    // Suffix parses as a decimal integer (the unix-nano stamp).
    const suffix = row.id["user-preferred-model-".len..];
    _ = std.fmt.parseInt(i128, suffix, 10) catch return error.BadNanoSuffix;
    ```
  - Test "saveMemory: two saves with same slug produce two distinct rows": save twice with `.id = "dup-slug"` and different content; assert `!std.mem.eql(u8, first.id, second.id)`; assert `SELECT COUNT(*) FROM agent_memories WHERE id LIKE 'dup-slug-%'` returns `"2"`.
  - Test "saveMemory: auto-generated id also carries nano suffix": save with `.id = ""`; assert startsWith `"mem_"`, contains `-`, and the part after the last `-` parses as i128.
  - Update the EXISTING test "saveMemory: UPSERTs when caller passes an existing id" — its premise (same id → replaced row, COUNT == 1) is now INVALID. Rewrite it as the two-distinct-rows test above (or delete if fully redundant).
  - Run: `zig build test --summary all 2>&1 | tail -n 20` — expect FAIL/compile error (logic doesn't exist yet).
- [ ] **1.2 Implement** in `agent_memories.zig`:
  - Add a small helper next to `generateMemoryId`:
    ```zig
    /// Append the unix-nano stamp to any memory id. Guarantees every
    /// save lands on a fresh PRIMARY KEY — duplicate slugs never
    /// overwrite earlier rows (user request, task_1787545300911_7:
    /// "id always append nano ... to handle case duplicated").
    fn appendNanoSuffix(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, std.time.nanoTimestamp() });
    }
    ```
  - In `saveMemory`, replace the current conditional id generation:
    ```zig
    // OLD:
    // const id: []const u8 = if (args.id.len == 0)
    //     try generateMemoryId(allocator)
    // else
    //     args.id;

    // NEW — ALWAYS suffix, whether auto or caller-provided:
    const owned_id: []u8 = blk: {
        const base = if (args.id.len == 0)
            try generateMemoryId(allocator)
        else
            args.id;
        break :blk try appendNanoSuffix(allocator, base);
    };
    defer allocator.free(owned_id);
    const id: []const u8 = owned_id;
    ```
    Note this SIMPLIFIES the existing ownership dance below (lines ~135–137): `generated_id` / `defer free(generated_id)` can be deleted because `owned_id` is now unconditionally owned + freed. The read-back via `getMemoryById(allocator, db, id)` keeps working verbatim (binds the full suffixed id).
  - Update the function doc comment: "UPSERT by id" wording → "every save creates a NEW row; the id always carries a `-<unix-nano>` suffix so duplicate slugs never collide".
  - Update the module header comment block ("Why `mem_<16-hex>` auto-generated ids") to document the suffix contract.
- [ ] **1.3 Run tests** — `zig build test --summary all`; expect green including rewritten UPSERT test.
- [ ] **1.4 Commit** — `git commit -am "saveMemory: always append unix-nano suffix to id (duplicate-safe)"`

---

## Task 2 — Tool layer: document + verify the new id semantics

### Steps

- [ ] **2.1 Write failing test** in `src/modules/agent/tools/save_memory.zig` inline tests:
  - Test "success XML id carries nano suffix even when caller provides id": execute with `.id = "my-slug"`, assert output contains `<id>my-slug-</id>`... precisely: parse out the `<id>...</id>` value, assert startsWith `"my-slug-"` and the remainder parses as an integer.
  - Test "two identical saves both succeed with distinct ids": run `executeSaveMemory` twice with same content + same slug; extract both `<id>` values; assert they differ.
- [ ] **2.2 Implement doc updates** in `save_memory.zig`:
  - Tool description sentence currently reading "This is a UPSERT: if you provide an `id` that already exists, the existing row's content and tags are replaced..." → replace with: "The `id` you provide is used as a SLUG PREFIX — a unix-nanosecond suffix is always appended, so every save creates a NEW unique row (saving twice with the same id never overwrites; you get two versions). Omit `id` to get an auto-generated `mem_<16-hex>-<nano>`."
  - `id` parameter description: "Optional id slug. A unix-nano suffix is ALWAYS appended (e.g. 'my-note' → 'my-note-1756...' ) so duplicate saves never collide — each save is a distinct row."
  - Top-of-file wire-shape doc comment: note the suffix behavior.
- [ ] **2.3 Run tests** — `zig build test --summary all`; full suite green.
- [ ] **2.4 Commit** — `git commit -am "save_memory tool: document nano-suffixed id semantics"`

---

## Task 3 — Full verification

### Steps

- [ ] **3.1** `zig build test --summary all` — 0 fail, 0 leak.
- [ ] **3.2** Grep sweep: confirm no other code depends on stable memory ids across saves (`search pattern="getMemoryById|loadMemoriesByFts"` shows consumers pass through ids returned by prior calls — safe).
- [ ] **3.3** Manual smoke (optional): chat session → save_memory twice with same id → load_memory by either returned id → both retrievable.
- [ ] **3.4** Push branch / open PR.

## Pitfalls

- **Don't keep the old ownership dance.** The old code conditionally freed `generated_id` only when auto-generated. With unconditional suffixing, the composed id is ALWAYS heap-owned — one `defer allocator.free(owned_id)` replaces the whole `generated_id ?[]u8` block. Missing this leaks (tests fail with leak detector).
- **`std.time.nanoTimestamp()` returns i128** — format with `{d}` directly; never cast down to i64/u64.
- **Two saves within the same nanosecond are theoretically possible** but practically unreachable (each save does DB I/O between stamps); do NOT add extra randomness — the existing 16-hex random component already covers the auto-id path, and the user explicitly wants deterministic slug+suffix.
- **Existing UPSERT test must be REWRITTEN, not patched** — its core assertion (`COUNT(*) == 1` after double-save) contradicts the new contract. Leaving it in place guarantees a red suite.
- **Tool description is load-bearing** — the LLM reads it to decide behavior. If it still says "UPSERT/replaced", the model will assume overwrites happen and may skip re-saving. Update it in the same commit as the behavior change.
- **load_memory by-id lookups need the FULL suffixed id** — that's why the success XML must echo the final id (it already does via `row.id`). Don't "helpfully" strip the suffix anywhere.

## Verification

- [ ] All tasks' checkboxes ticked
- [ ] `zig build test --summary all` fully green (0 fail, 0 leak)
- [ ] Double-save with same slug → 2 distinct rows, both retrievable via their echoed ids
- [ ] Auto-generated ids still match `mem_<16-hex>-<nano>`
