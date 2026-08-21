# Agent Mode UI/UX Improvements — Knowledge Detail + Tools Panel

**Date:** 2026-08-22
**Task:** task_1787349760976_1 ("agent mode: make the ui more better")
**Status:** PLAN — awaiting user approval before implementation
**Scope:** Frontend-only (AgentView.vue). No backend changes, no migration.

---

## Problem statement

The Agent Mode left panel has two UX gaps:

1. **Knowledge entries are opaque.** A row shows only the label/path and a
   60-char preview of inline text. There is no way to see the full content of
   a knowledge entry (inline text OR file-backed), no way to edit it after
   creation, and file-backed rows don't even show a preview.
2. **The Tools list is a wall of text.** All 44 tool descriptions render in
   full — `spawn_sub_agent`'s description alone is ~2000 chars. There is no
   expand/collapse, so scanning the list means scrolling through thousands of
   lines, and there is no "show only enabled" filter to review what an agent
   actually has.

---

## Current state (verified)

| Fact | Where |
|---|---|
| `GET /agent` returns knowledge rows **with `content` inline** | `agents_get.zig:130` SELECT includes `content` |
| `PATCH /knowledge/:id` accepts `{file_path?, label?, content?}` | `agent_knowledge_update.zig` |
| Tool registry = `{name, description}` only | `agent_tools_registry.zig` |
| Tools list renders full description, tooltip only | `AgentView.vue:350-356` |
| Knowledge row shows 60-char inline preview, nothing for files | `AgentView.vue:181-191` |
| Existing tests: 8 behavioural tests | `src/__tests__/AgentView.spec.ts` |

→ Both features are achievable with **zero backend work**.

---

## Feature A — Knowledge detail view

### A1. Expand/collapse per knowledge row

Each `<li>` gets a chevron toggle (like the tools plan below). Collapsed =
current row; expanded reveals a detail area:

- **Inline rows:** full `content` in a scrollable `<pre>` block
  (`max-h-48 overflow-y-auto`, monospace, dim bg).
- **File-backed rows:** preview is NOT in the GET payload (content column is
  '' for file rows), so show the absolute path + a hint line:
  "File-backed — agent reads this file at chat start". Optionally fetch
  content lazily via the existing `/system/folder` read action later
  (deferred — see Non-goals).

### A2. Edit support (label + inline content)

An "Edit" button on each row opens a small modal (reuse the visual language
of `AgentKnowledgeDialog.vue`):

- Label field (always editable).
- Content textarea — only for inline rows (file rows keep path editing out
  of scope for v1; delete+re-add covers it).
- Save → `api.updateAgentKnowledge(agentId, knowledgeId, {label?, content?})`
  → parent refetches `getAgent()` (the same flow as create).

New component: `AgentKnowledgeDetailDialog.vue` (edit mode) — or extend the
existing dialog with an `editKnowledge` prop. Decision: **separate small
component**, keeps the add-dialog simple.

### A3. Copy button

A copy-to-clipboard icon on expanded content (pattern exists in
tool_outputs components).

## Tasks — Feature A

- [ ] A1: chevron + expanded state map (`expandedKnowledge = ref(Set<string>)`)
      in AgentView.vue; render `<pre>` for inline content, path hint for files.
- [ ] A2: new `AgentKnowledgeDetailDialog.vue` (label + content edit, busy +
      error props mirroring the add dialog); wire `updateKnowledge` emit →
      AppLayout handler → `api.updateAgentKnowledge` → refetch.
- [ ] A3: copy button on expanded content.
- [ ] Tests: expand/collapse toggling, edit dialog open/save emits, copy
      button presence (extend `AgentView.spec.ts` + new spec for the dialog).

---

## Feature B — Tools panel: collapse descriptions + filter by enabled

### B1. Clamp + expand/collapse per tool description

- Default: clamp description to **2 lines** with CSS
  (`display:-webkit-box; -webkit-line-clamp:2`) + a subtle fade.
- Each tool row gets a chevron/expander. Expanded = full description,
  no clamp. State: `expandedTools = ref(new Set<string>())`.
- The existing `title` tooltip stays for hover.

### B2. Filter chips: All / Enabled / Disabled

Segmented control under the search box:

```
[ All (44) ] [ Enabled (3) ] [ Disabled (41) ]
```

- `toolsFilter = ref<'all' | 'enabled' | 'disabled'>('all')`
- Composes with search: `filteredTools` applies BOTH query AND filter.
- Counts update live; chip shows active state (violet).
- "Select all / Clear" continue to operate on the VISIBLE (filtered) set —
  already the case, unchanged semantics.

### B3. Small polish items

- Enabled count chip in section header already exists — keep.
- When filter = 'enabled' and the user disables the last visible tool, the
  empty-state message should say "No enabled tools match" with a
  "Show all" reset action (distinct from the search empty state).
- Row hover: slightly brighter border for scannability.

## Tasks — Feature B

- [ ] B1: line-clamp CSS class + expander chevron + `expandedTools` Set;
      clicking name/description toggles too (bigger hit target).
- [ ] B2: filter chips row (All/Enabled/Disabled with live counts),
      composed into `filteredTools`; update filter-status text.
- [ ] B3: empty-state variants + hover polish.
- [ ] Tests: clamp present by default, expand toggles, filter chips narrow
      the list, counts correct, combined search+filter, bulk ops still act
      on visible set.

---

## Out of scope (v1)

- Lazy-loading file-backed knowledge content from disk (needs a new
  endpoint or reuse of `/system/folder` read action — separate decision).
- Category grouping of tools (registry has no category field today).
- Reordering knowledge entries UI (backend `reorderAgentKnowledge` exists;
  drag-and-drop is its own task).

## Test plan

- Extend `src/__tests__/AgentView.spec.ts`: expansion toggles, filter chips,
  combined filtering, empty states.
- New `AgentKnowledgeDetailDialog.spec.ts`: open/populate, save emit payload,
  busy/error rendering.
- Run: `cd src/apps/desktop && bun run test` + `bun run type-check`.

## Risks / notes

- `-webkit-line-clamp` is fine in Chromium (Electron target).
- `updateAgentKnowledge` API wrapper already exists (added with manual-text
  feature) — no api/index.ts changes needed except none.
- Keep all data-testids stable; existing tests must stay green.
