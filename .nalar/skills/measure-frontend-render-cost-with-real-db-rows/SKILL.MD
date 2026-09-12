---
name: measure-frontend-render-cost-with-real-db-rows
description: "How to turn a vague \"the webview freezes / is slow\" report in ginwaaitoolbox into measured per-interaction main-thread milliseconds — export real llm_history rows with sqlite3 -json and drive the REAL frontend helpers from a throwaway vitest probe. Use before proposing any perf/freeze fix, so the fix is evidence-driven and the before/after is quotable in the PR."
---
---
name: measure-frontend-render-cost-with-real-db-rows
description: How to turn a vague "the webview freezes / is slow" report in ginwaaitoolbox into measured per-interaction main-thread milliseconds — export real llm_history rows with sqlite3 -json and drive the REAL frontend helpers from a throwaway vitest probe. Use before proposing any perf/freeze fix, so the fix is evidence-driven and the before/after is quotable in the PR.
tags: [workflow, performance, frontend, ginwaaitoolbox, debugging]
---

## When to Use

A user reports "the app/webview freezes/hangs/is slow" (often "sometimes", often "when opening")
and you need to know *which* code path costs what before touching it. Works for the ChatView
render path, virtual scroller, tool-output cards — anything driven by `llm_history` rows.

## Context

- Real DB: `~/.config/nalar/agent.db` (table **`llm_history`**, not `messages`). It is the user's
  live data — treat it read-only.
- Frontend helpers are plain TS modules (`src/apps/desktop/src/helpers/*.ts`) with no Vue
  dependency, so they run headless.
- `node --experimental-strip-types` CANNOT load these files (extensionless imports inside them
  break Node ESM resolution) and there is no `esbuild` binary. `vitest` (already installed in
  `src/apps/desktop/node_modules`, jsdom env) transforms them correctly — use it.

## Procedure

1. Find the real byte sizes first — never theorise before this:
   ```bash
   sqlite3 -header -column ~/.config/nalar/agent.db \
     "SELECT session_id, COUNT(*) n, SUM(LENGTH(COALESCE(response_content,''))) bytes,
             MAX(LENGTH(COALESCE(response_content,''))) max_row
      FROM llm_history GROUP BY session_id ORDER BY bytes DESC LIMIT 10;"
   ```
   Then the **open window** (what `ChatView` actually fetches — `PAGE_SIZE=100`, newest first):
   ```sql
   SELECT session_id, COUNT(*), SUM(LENGTH(COALESCE(response_content,''))), MAX(LENGTH(COALESCE(response_content,'')))
   FROM (SELECT session_id, response_content, ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY id DESC) rn
         FROM llm_history) WHERE rn <= 100 GROUP BY session_id ORDER BY 3 DESC LIMIT 10;
   ```
2. Export that window as JSON (sqlite3 `-json` helpers are safe with newlines/quotes):
   ```bash
   sqlite3 ~/.config/nalar/agent.db "SELECT json_group_array(json_object(
     'id',id,'role',role,'tool_name',COALESCE(tool_name,''),
     'content',COALESCE(response_content,''),'reasoning_content',COALESCE(reasoning_content,''),
     'tool_calls_json',COALESCE(tool_calls_json,'')))
   FROM (SELECT * , ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY id DESC) rn
         FROM llm_history WHERE session_id='<sid>') WHERE rn<=100;" > /tmp/heavy_rows.json
   ```
   Note: `sqlite3` appends a trailing newline — strip it in JS (`.replace(/\n$/,'')`) or
   `unwrapToolOutput`'s `endsWith('</tool>')` check fails.
3. Write a throwaway probe at `src/apps/desktop/src/__tests__/zz_perf_probe.spec.ts` that imports
   the REAL helpers (`@/helpers/stripTags`, `@/helpers/renderResponse`, `@/helpers/unwrapToolOutput`),
   reads `/tmp/heavy_rows.json`, and times (a) a cold pass of every computed ChatView runs on mount
   and (b) a warm pass per SSE chunk (state-mutating calls re-run; `renderResponse` re-parses only the
   streaming message because its cache key is the full content). Use `performance.now()` with 3
   iterations after a warm-up. Print `ms` per phase, plus "ms of main-thread work per second at
   20 chunks/s" — that last number is what tells you whether the UI can repaint at all.
4. Run it: `cd src/apps/desktop && npx vitest run src/__tests__/zz_perf_probe.spec.ts`
   (grep out the `sse-client` stdout noise).
5. Fix, re-run the SAME probe, quote before/after in the PR body.
6. Delete the probe before committing (it depends on `/tmp` exports). Add permanent *unit* tests
   for the memo/cache contract instead — assert on cache stats / entry counts, never on string
   reference identity (JS strings are primitives; `toBe` compares by value, so identity assertions
   are vacuous).

## Pitfalls

- `node --experimental-strip-types` fails with `ERR_MODULE_NOT_FOUND` on the repo's extensionless
  imports — don't waste time on a custom loader; use vitest.
- jsdom `document.createElement` is not a browser: costs measured through `escapeHtml` are inflated.
  Say so in the PR; stick to regex/string/parse costs for numbers you quote as wire-truth.
- `zig-out/bin/nalar` + Playwright (`tests/functional_ui/`) is the right tool for *wire* behaviour,
  but the Python deps (`pytest`/`playwright`) are NOT installed on this box — the vitest probe is
  the cheap path for render-cost questions.
- Never use the dev server on :8081 for repro (never kill it); a probe needs no server at all.

## Verification

- The probe prints a per-phase breakdown where one phase clearly dominates (>50%) — that is the
  fix target; if no phase dominates, the cost is in layout/compositing and JS measurement will not
  find it (say so instead of guessing).
- After the fix, the same probe (unchanged) shows the dominating phase collapse, and the repo's
  own gates pass: `npx vitest run src/__tests__/<touched>.spec.ts`, `pnpm run type-check`,
  `pnpm run build`.

