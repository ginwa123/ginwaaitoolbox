# Add `id` parameter to `load_memory` agent tool — Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Implementation is already complete on branch `worktree/load-memory-by-id`; this doc is the post-hoc record + PR description.

**Goal:** Let the LLM fetch a specific memory's FULL body (no 2 KiB cap) by passing `id="mem_xxx"` to `load_memory`, bypassing the FTS5 search when the id is already known.

**Architecture:** Add an optional `id` parameter to `LoadMemoryInput`. When `id` is non-empty, `executeLoadMemory` skips the FTS5 path entirely and calls the existing `agent_memories.getMemoryById` storage helper — no new SQL, no migration, no schema change. The output wraps the single row in the same `<count>/<total_count>/<results>/<memory>` shape as the FTS5 path so the LLM only learns one XML structure. OpenAI's tool-schema DSL has no `oneOf` for primitive strings, so the "query OR id" validation lives in `executeLoadMemory` (returns `<error>must supply either query or id</error>` when both are empty).

**Tech Stack:** Zig 0.16, SQLite (unchanged), Vue/TS frontend unchanged (schema is just a description passed to the LLM at runtime).

## Design choice: extend `load_memory` (Option A) vs separate tool (Option B)

Picked **Option A** after user approval: add `id` as a sibling parameter to the existing `query`. Reasoning:

- Single tool surface — the LLM only learns one name (`load_memory`), one envelope shape, and one error vocabulary.
- The OpenAI tool-schema DSL doesn't support per-parameter validation rules, so adding a separate tool doesn't actually remove the need for runtime validation. The "oneOf: query OR id" logic would still live in storage.
- Matches the existing convention of single-purpose + multi-mode tools (e.g. `update_element` covers all of `x`/`y`/`width`/`height` partial-update).
- Counter-argument (Option B would win if): the tool description was already over the LLM's "instruction-budget" — but `load_memory`'s description fits comfortably, and the by-id branch is documented as one short paragraph.

## Wire contract

**Input:**
```jsonc
{
  "id": "mem_xxx",   // NEW — when non-empty, FTS5 is skipped
  "query": "...",    // FTS5 keyword; required only when id is empty
  "tags": "bug",     // ignored when id is set
  "limit": 10,       // ignored when id is set (always 1)
  "offset": 0,       // ignored when id is set
  "with_content": false // ignored when id is set (always full content)
}
```

**Output — by-id path:**
```xml
<load_memory query="" id="mem_xxx" by_id="1" limit="10" offset="0" with_content="1">
  <count>1</count>
  <total_count>1</total_count>
  <results>
    <memory>
      <id>mem_xxx</id>
      <tags>...</tags>
      <created_at>...</created_at>
      <updated_at>...</updated_at>
      <content truncated="0">FULL BODY UP TO 1 MiB</content>
    </memory>
  </results>
</load_memory>
```

Same shape as a 1-row FTS5 response — LLM doesn't learn a second envelope.

**Output — error paths:**
- `id` and `query` both empty → `<error>must supply either query or id</error>`
- `id` set but row missing → `<error>not found: <id></error>` (no empty `<results>` envelope — clearer LLM signal)

## Behavioural guarantees

- **No content truncation in by-id path.** `MAX_FULL_CONTENT_BYTES` (2 KiB) only applies to FTS5 + `with_content=true`. The by-id path returns content up to the storage layer's `MAX_CONTENT_BYTES` (1 MiB), which `saveMemory` enforces at write time. The `<content truncated="0">` flag is hardcoded for by-id — never `1`.
- **`tags` ignored when `id` is set.** Documented in tool description + verified by `load_memory_tool: by-id ignores tags` test.
- **`limit`/`offset`/`with_content` echoed but inert in by-id path.** They still appear in `<load_memory>` attributes for input/response symmetry; the LLM can introspect what it sent. Single-row response has `<count>1</count>` and `<total_count>1</total_count>` regardless of `limit`.
- **Backward compatible.** The original "query only" FTS5 flow is unchanged — same FTS5 call, same snippet-vs-content shape, same error vocabulary. Existing agents / tests don't break.

## Files changed (2)

| File | Lines | What |
|---|---|---|
| `src/modules/agent/tools/load_memory.zig` | +154 / -19 | Add `id` field, branch `executeLoadMemory`, add `executeById` + `successByIdXml` helpers, update wire-shape header doc + tool description |
| `src/modules/agent/tools/load_memory_test.zig` | +178 / -2 | 5 new by-id tests, update existing "parameters include" test to assert `id` is present |

No migration, no schema change, no frontend change, no dependency change. Storage layer (`agent_memories.getMemoryById` at `agent_memories.zig:146`) was already in place from the 2026-08-06 plan — this is a tool-surface addition only.

## Tests added (5)

| Test | Asserts |
|---|---|
| `by-id lookup returns single row with full content` | Wire shape: `<results><memory>` wrapper, full body in `<content>`, `<count>1</count>`, `<total_count>1</total_count>` |
| `by-id lookup returns content beyond 2 KiB (no MAX_FULL_CONTENT_BYTES cap)` | Seeds a 4 KiB memory, asserts the tail token past the 2 KiB mark is reachable (would fail under the 2 KiB cap) and `<content truncated="1">` is NOT present |
| `by-id lookup returns error when id not found` | `<error>not found: ...</error>`, NO `<results>` envelope |
| `empty id + empty query returns error` | `<error>must supply either query or id</error>` |
| `by-id ignores tags (only one row can match anyway)` | Seeds two memories with conflicting tags; by-id returns only the matching one |

The pre-existing "parameters include query, tags, limit, offset, with_content" test was renamed + extended to assert `id` is also present (covers the schema change). All other 13 load_memory tests are unchanged and still pass.

## Verification

- `zig build test --summary all` → **2448 pass, 6 skip, 0 fail** (baseline ~2401 → +47 includes 5 new tests + other recent-test additions on main)
- `zig build nalar-desktop --summary all` → **10/10 steps succeeded**
- TDD discipline followed: tests added before implementation, compile errors confirmed at the schema level before the implementation patch (5 `.id = "..."` struct-initializer errors), all 5 + the updated schema test pass after the patch.

## What was NOT done (intentional)

- **No new tool entry.** Branching inside `executeLoadMemory` keeps the registry unchanged (`tools_equipped.zig:164` is untouched). One tool, one envelope.
- **No schema/migration.** Storage layer already had `getMemoryById` — this is purely a wire-surface change.
- **No frontend change.** The schema is a runtime JSON description consumed only by the LLM; the frontend renders chat history, not the schema itself.
- **No cache_read_input_tokens / prompt_tokens split for "by-id response size" accounting.** The response is bounded by `MAX_CONTENT_BYTES` (1 MiB), and the LLM context budget for one tool result is already a soft contract — the same context anti-bloat guarantees that exist for `with_content=true` (capped at 2 KiB × 50 rows = 100 KiB) apply. By-id responses are 1 row × ≤ 1 MiB, comfortably within any reasonable single-tool-result cap.

## Follow-up ideas (out of scope for this PR)

- If by-id lookups turn out to be hot, add a `created_after`/`created_before` filter on the FTS5 path (not the by-id path — by-id is always exact).
- Consider exposing `id` as a hint in the FTS5 snippet (the existing snippet format doesn't include the id in the visible text — only in the parent `<memory>` element).