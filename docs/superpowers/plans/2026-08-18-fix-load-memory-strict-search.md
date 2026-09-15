# Fix `load_memory` strict-search bug (FTS5 phrase → OR)

**Date:** 2026-08-18
**Branch:** `worktree/fix-load-memory-strict-search`
**Task:** task_1787050039216_3 ("load_memory issues")
**Goal:** Make `load_memory` recall succeed for multi-word natural-language queries. Today, `load_memory({query: "preferred model"})` returns **0 hits** because the query is wrapped in FTS5 phrase syntax, requiring the literal substring "preferred model" in the indexed text.

---

## The bug

`escapeFtsQuery` in `src/ai_workflow/tui/agentic_loop/llm_history.zig:1780` wraps the entire user query in FTS5 phrase syntax (`"..."`), then replaces FTS5 operators (`-`, `+`, `:`, etc.) with spaces inside the phrase. This was added to fix the `handle_tool.zig` syntax error (task_1785658329168), but it over-rotated: phrase syntax requires all tokens to be **adjacent** in the indexed text.

Direct evidence (live SQL against `/home/ginwa/.config/nalar/agent.db`, 64 memories):

| Query | Current behavior (phrase) | Should be (OR) |
|---|---|---|
| `preferred model` | **0 hits** | 13 hits |
| `CI frontend` | **0 hits** | 20 hits (OR) / 2 hits (AND) |
| `project ginwaaitoolbox` | 2 hits | 8 hits (AND) / 15+ hits (OR) |
| `CI` (single token) | 16 hits ✓ | 16 hits ✓ |
| `2026-08-06` (date) | 4 hits | needs OR |

The LLM is told (in `MemoryToolRule`) "just write the natural query" — but natural queries fail.

---

## Fix

### 1. `src/ai_workflow/tui/agentic_loop/llm_history.zig:1780` — `escapeFtsQuery`

Surgical change:
- **Keep** the operator sanitization (`-`, `+`, `*`, `^`, `:`, `(`, `)`, `"` → space).
- **Drop** the `"..."` phrase wrap.
- **Split** on whitespace into tokens.
- **Emit** the tokens joined with ` OR ` (FTS5 OR operator) — natural recall semantics.
- **Single-token** queries are emitted as-is (no `OR`, no quotes — FTS5 default tokenization handles `handle_tool.zig` correctly via the unicode61 tokenizer).
- **Empty** query after sanitization (all operators) returns empty string; callers already guard against `len == 0`.

Same function is used by the legacy history search (and other FTS5 callers). The fix affects both, which is correct — the legacy tool has the same recall problem. **All existing tests use single-token queries so they continue to pass.**

### 2. `src/modules/agent/tools/load_memory.zig` — tool description

Update the description block (around line 92-104) so the LLM knows:
- Multi-word queries are joined with **OR** — `CI frontend` matches memories mentioning either word.
- Single-token queries still match as before.
- Don't pre-escape; FTS5 operators are still auto-sanitized.

### 3. The legacy history tool file — tool description

Same description update for symmetry.

### 4. `src/modules/agent/prompts/core.zig` — `MemoryToolRule` (line 85) + the legacy history tool rule (line 62)

Replace the misleading "wraps your input in FTS5 phrase syntax" sentence with the new OR semantics. Without this fix, the LLM keeps using the tool wrong.

### 5. Tests — `src/modules/agent/tools/load_memory_test.zig`

Add 3 new tests at the end:
- `multi-token query joins with OR (regression for strict-search bug)` — `load_memory({query: "preferred model"})` against a memory containing "preferred" (but not adjacent to "model") returns ≥ 1 hit.
- `special chars don't crash and still match (sanitization preserved)` — `load_memory({query: "handle_tool.zig"})` against a memory containing "agentic_loop/handle_tool.zig" returns ≥ 1 hit. (Already partially covered, but make explicit.)
- `single-token query unchanged (regression guard)` — `load_memory({query: "dark"})` still returns the dark-mode memory.

### 6. Tests — `src/ai_workflow/tui/agentic_loop/llm_history.zig`

Add inline tests for `escapeFtsQuery` directly (none exist today):
- `escapeFtsQuery: single token is emitted as-is`
- `escapeFtsQuery: multiple tokens joined with OR`
- `escapeFtsQuery: FTS5 operators replaced with space before tokenizing`
- `escapeFtsQuery: empty input returns empty string`
- `escapeFtsQuery: special-char-only input returns empty string`

---

## Out of scope (deliberate)

- **Schema / migration changes** — the FTS5 index is correct.
- **`saveMemory` / `agent_memories.zig` write path** — no change.
- **Adding a `mode: "phrase"` flag for callers that want adjacent-only search** — YAGNI for now; can add later if a real use case emerges.
- **Adding column-restricted `tags:foo` syntax** — separate feature; out of scope for this fix.

---

## Verification

1. `zig build test --summary all` — all 2366 tests pass, 0 fail.
2. Direct SQL sanity check against the live DB:
   ```sh
   sqlite3 ~/.config/nalar/agent.db "SELECT COUNT(*) FROM agent_memories_fts WHERE agent_memories_fts MATCH 'preferred OR model';"
   # → 13 (was 0 with phrase wrap)
   ```
3. PR opened for human review.

---

## Files touched

| File | Change |
|---|---|
| `src/ai_workflow/tui/agentic_loop/llm_history.zig` | `escapeFtsQuery` body rewritten (~30 LOC). Inline tests added (~50 LOC). |
| `src/modules/agent/tools/load_memory.zig` | Tool description block (line ~92). |
| The legacy history tool file | Tool description block (line ~116). |
| `src/modules/agent/prompts/core.zig` | `MemoryToolRule` (line ~85) + the legacy history tool rule (line ~62). |
| `src/modules/agent/tools/load_memory_test.zig` | 3 new tests. |

**Total: 5 files modified, ~120 LOC.**