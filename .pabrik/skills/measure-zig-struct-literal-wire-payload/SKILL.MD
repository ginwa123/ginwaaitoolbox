---
name: measure-zig-struct-literal-wire-payload
description: "How to measure how many bytes a Zig codebase ships to an external API from comptime struct literals (e.g. pabrik's 37 AgentTool schemas → the LLM tools[] array) — with the literal-masking step that makes brace-matching correct. Use when asked \"how big is our prompt/tools payload\" or before proposing a context-bloat fix."
---
---
name: measure-zig-struct-literal-wire-payload
description: How to measure how many bytes a Zig codebase ships to an external API from comptime struct literals (e.g. pabrik's 37 AgentTool schemas → the LLM tools[] array) — with the literal-masking step that makes brace-matching correct. Use when asked "how big is our prompt/tools payload" or before proposing a context-bloat fix.
tags: [measurement, zig, context-bloat, token-cost, ginwaaitoolbox, pattern]
---

## When to Use

You need a number for "how many bytes/tokens does this codebase send to the
external API", and the payload is assembled from Zig struct literals rather
than from a serialized dump. In pabrik specifically: the `tools[]` array built
from `AgentTool{…}` literals in `src/modules/agent/tools/*.zig`.

Use this BEFORE proposing any context/token optimization, so the fix is
evidence-driven and the before/after is quotable in the PR.

## Context

- The payload text lives in the literal fields: `.name = "…"`,
  `.description = \\multiline…`, and every `ToolProperty.description`.
  JSON structural overhead (keys, braces, punctuation) is NOT in the literals
  — budget roughly +15–25 % and say so.
- `system_prompt` on the same struct is a SECOND cost centre that does not ship
  in `tools[]` — it gets aggregated into the system message. Measure it
  separately or you will under-report by ~20 %.
- pabrik reference run (2026-09-12): 70,008 B of literals for 36/37 equipped
  tools → ≈83 KB on the wire → ≈21k tokens per call.
- A compiled dump is strictly better when you can get it. In pabrik,
  `Agent.buildJsonAnthropicRequest` / `buildJsonOpenAIRequest` are `pub fn`
  (`src/modules/agent/Agent.zig:1310`, `:1618`), so a Zig test can serialize
  the real body and assert `body.len`. Prefer that when the plan allows a code
  change; use this script when you must be read-only.

## Procedure

1. Find the registry that lists the literals (pabrik:
   `src/agentic_loop/tools_equipped.zig:66-119`, `equips()`), and write down the
   exact set of tool NAMES it references. Do not glob the whole directory —
   it also contains unequipped tools, and including them over-counts.
2. For each `pub const <x>_tool = AgentTool{ … };`, **mask every string literal
   to a same-length placeholder BEFORE brace-matching**, then brace-match on the
   masked source. Two traps make the naive version wrong:
   - Descriptions contain `{` and `}` as literal text (e.g. `{a,b,c}`,
     `.{ }`), which unbalances the brace counter and makes the "block" run to
     the end of the file.
   - Quotes inside `//` comments (e.g. `` // don't construct it from the
     name ``) desync a naive string scanner, which then masks real code and
     makes declarations silently disappear from the results.
   Mask line-by-line (Zig string literals never span lines except `\\`
   multiline literals, which are always the first non-space token on the line):
   for each line, if `lstrip().startswith("\\\\")` mask the whole line, else
   mask `"…"` runs and everything after `//`. Offsets are preserved, so you can
   sum literals on the ORIGINAL slice afterwards.
3. Handle BOTH declaration spellings. Most tools use
   `pub const x_tool = AgentTool{`, but some use
   `pub const x_tool: AgentTool = .{`. Match `AgentTool\{` first, then
   `\w+_tool\s*=\s*\{` as a second pass.
4. Map const names to wire names with an explicit alias table
   (`text_replace → text_replace_tool`, `add_element → add_design_element_tool`,
   …). A heuristic "name appears in the const name" fallback is fine as a
   cross-check but it silently picks the wrong const when several share a prefix.
5. Print per-item bytes sorted descending, then the total and `total/4` as the
   token estimate. Always print the count matched vs expected (`36/37`) and the
   list of misses — a silent miss is how you get a wrong headline number.
6. Sanity-check the top entry by hand: open that file and count the
   description lines. If the top entry is an order of magnitude above the
   second, your brace matching is still broken (that was the 31,772 B vs 4,930 B
   `search` discrepancy).
7. State the method and its exclusions in one line wherever you quote the
   number ("literal-text reconstruction, excludes JSON structure and
   system_prompt text").

## Pitfalls

- Reporting a number from a script whose misses you did not print. The first
  version of this measurement said 92,860 B (inflated ~30 %) because brace
  matching ran past the end of the block, and a later one said 67,800 B
  (deflated) because comment quotes masked four declarations out of existence.
  Both looked plausible.
- `grep`/`awk`-based block extraction: `awk '/AgentTool\{/,/^\};/'` fails
  outright because the closing `};` is indented differently across files, and
  shell `"`/`\\` escaping eats the literal prefixes.
- Counting `system_prompt` in the `tools[]` total. It does not ship there.
- Forgetting `bash` escaping: a command containing `$$` (e.g. a `sed` cleanup)
  trips this environment's self-kill protection and is refused.

## Verification

- Re-run the script and confirm the matched-count line reads `N/N` with an
  empty miss list (or an explicitly explained miss).
- Confirm `tools_bytes` ≈ `sum(per-item bytes)` and that
  `tokens ≈ bytes/4` is in the same ballpark as the provider's own estimate
  (pabrik logs `[TOKEN ESTIMATE]` as `(json_body.len+3)/4` at
  `src/modules/agent/Agent.zig:2779`).
- Cross-check one item against the provider's view: an OpenAI-shaped
  `tools[].function.description` for a known tool should be within a few bytes
  of the literal sum for that tool.

