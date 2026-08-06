# 2026-08-06 — Enhance prompts to teach the agent `save_memory` + `load_memory`

## Context

`save_memory` and `load_memory` shipped in PR #... (task_1785990166273, 2026-08-06)
as two new SQLite FTS5-backed LLM tools. They are wired and tested, but the
main-agent prompt does NOT teach the agent WHEN to call them. Without the
rule, the agent has no signal to reach for these tools proactively — it
will keep asking the user for preferences it should remember, and keep
re-discovering facts it should have persisted.

This work adds a `MemoryToolRule` section following the established
`SearchHistoryToolRule` pattern (gated on the runtime tool list via
`requires_tool`), and a small block on the `CompactionAgent` so the
compaction step also uses memory appropriately.

The prompt already auto-injects `.md` memories (`loadGlobalKnowledge`,
`loadLocalKnowledge`) and lists the skills-system surface. The new
section explicitly distinguishes the FTS5 `save_memory` / `load_memory`
surface from the hand-curated `.md` files (both stay).

## Architecture

| File | Edit |
|---|---|
| `src/modules/agent/prompts/core.zig` | **NEW** `MemoryToolRule` constant (after `SearchHistoryToolRule`, line 65). Mirrors the existing tool-rule style — lead paragraph, TWO TOOLS block, wire-format notes, when-to-call bullets, self-check. |
| `src/modules/agent/prompts/prompts.zig` | Re-export `MemoryToolRule` (after line 26's `SearchHistoryToolRule`). |
| `src/modules/agent/prompts.zig` | (a) Re-export `MemoryToolRule` (after line 42). (b) Add to `PROMPT_SECTIONS` with `requires_tool = "load_memory"`, immediately after the `search_history_tool_rule` slot (line 91). |
| `src/modules/agent/prompts/special.zig` | Add a `## CROSS-SESSION MEMORY` block at the end of `CompactionAgent` (after the existing `## HOW THE NEXT AGENT WILL USE THIS OUTPUT` block) — short, teaching compaction to forward save/load cues to the next agent. |
| `src/modules/agent/prompts_test.zig` | **NEW** 3 tests: (1) section rendered when `load_memory` in tools, (2) section omitted when `load_memory` absent, (3) CompactionAgent contains the new CROSS-SESSION MEMORY block. |

## Content shape

`MemoryToolRule` covers:

1. **Lead** — when to use these tools (don't re-ask user, don't re-derive facts).
2. **Surface distinction** — FTS5-backed agent-managed notes, vs. `.md` files in
   `~/.config/nalar/memories/` (auto-injected as `## Global Knowledge`).
3. **TWO TOOLS** — `save_memory` UPSERT by id, `load_memory` FTS5 search with
   snippets + `with_content` opt-in.
4. **WIRE FORMAT — 3 contracts stay in sync** — `tags` is a single string
   (NOT array; this is the documented contract after the bugfix); `id` is
   `mem_<16-hex>` or caller slug; storage is permanent, no delete.
5. **FTS5 sanitization** — auto-applied, mirrors search_history.
6. **WHEN TO CALL save_memory** — 4 trigger categories with examples.
7. **WHEN TO CALL load_memory** — 4 trigger categories with examples.
8. **Self-check** — re-state check + re-derive check.

`CompactionAgent` extension is short (10-12 lines) — extends the existing
"how the next agent will use this output" teaching to include memory tools.

## Why `requires_tool = "load_memory"` (not `save_memory`)

1. `load_memory` is the READ primitive — the agent needs recall much more
   often than persistence in any given turn.
2. The two tools ship as a pair in `tools_equipped.zig` — gating on either
   is effectively the same runtime check.
3. Mirrors the `search_history` precedent (gate on the primary tool).

If a kanban/folder session ever has its memory tools stripped by the
`filteringTools` filter (currently it doesn't), the section will silently
disappear — correct behaviour.

## TDD sequence

### Stage 1 — RED: failing tests (3 new)

Add to `prompts_test.zig`:

```zig
test "build_agent_prompt renders Memory Tools section when load_memory is in tool list"
test "build_agent_prompt omits Memory Tools section when load_memory is absent"
test "CompactionAgent constant teaches save_memory + load_memory (cross-session memory block)"
```

Run `zig build test --summary all` — these 3 tests fail (section doesn't exist).

### Stage 2 — GREEN: add rule + wire it up

1. Add `MemoryToolRule` constant to `core.zig` after line 65.
2. Add `pub const MemoryToolRule = core.MemoryToolRule;` in `prompts.zig`.
3. Add `pub const MemoryToolRule = prompts.MemoryToolRule;` in `prompts.zig` (outer).
4. Add `.{ .name = "memory_tool_rule", .content = MemoryToolRule, .requires_tool = "load_memory" }` to `PROMPT_SECTIONS` after the `search_history_tool_rule` entry.
5. Append `## CROSS-SESSION MEMORY (save_memory / load_memory)` block to
   `CompactionAgent` in `special.zig`.

Run tests again — all 3 pass.

### Stage 3 — VERIFY

```bash
timeout 180 zig build test --summary all
# Expect: 2 new pass, baseline preserved (was 2350, expect 2353+ pass; 6 skip; 5 fail pre-existing)

timeout 240 bash -c 'rm -rf zig-out/bin && zig build'
# Expect: 3 binaries produced (nalar, nalarcore-linux-x86_64, nalar-desktop; nalarcli)

zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expect: clean (the section body is plain text)

zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expect: clean
```

## Out of scope (deferred)

1. **Adding FTS5 row to `GlobalMemorySystem` surface table** in
   `prompts/memory.zig` — that section is commented out in
   `PROMPT_SECTIONS`. Uncommenting it is a separate decision.
2. **Fixing the `load_memory` description's `tags` "array" mentions**
   (two places + the example). That's a `load_memory.zig` description
   inconsistency, not a prompt issue. Tracked separately.
3. **Adding FTS5 to the existing memory-domain knowledge in
   `prompts/memory.zig::skills_system_prompt`** — out of scope; the new
   `MemoryToolRule` covers it.
4. **`requires_tool` to gate on `save_memory` instead** — single-tool
   gate matches precedent; can be revisited later.
5. **Adding `delete_memory` tool** — by design there is no delete (per
   `save_memory` description: "memory is permanent").

## Pitfalls (record for future agents)

1. **`PROMPT_SECTIONS` is module-scope, single source of truth.** Adding
   a section here wires it into ALL main-agent prompts via the
   `build_agent_prompt` composer loop. The `requires_tool` gate is the
   only filter — without the gate, every agent sees the section.
2. **`hasTool` does exact `std.mem.eql` on `tool.function.name`** (line
   119). The tool names are `"save_memory"` and `"load_memory"` —
   confirmed in `tools/save_memory.zig:68` and `tools/load_memory.zig:90`.
3. **CompactionAgent is NOT assembled via `PROMPT_SECTIONS`** — it's a
   single-shot prompt passed directly to the compaction LLM. To teach it,
   edit the literal `\\…` string in `special.zig`.
4. **Tailwind / shell-quirk with `<tool-name>` syntax in markdown docs**
   — the rule text uses backticks `\\`\`` for tool-call examples; the
   Zig `\\` continuation treats them as literal text. No escaping needed
   inside the docstring.
5. **The 3-contract reminder (`tags` is a string)** must mirror the
   post-bugfix reality (per `save-memory-bug-2026-08-06.md`). The
   prompt is the user's last-line safety net against the LLM sending
   `tags: ["a", "b"]` again.
6. **CompactionAgent target section** — must precede the closing
   backslash-newline that ends the `\\…` string. Append just before
   the trailing `;`.
