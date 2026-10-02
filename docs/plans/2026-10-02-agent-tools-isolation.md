# `src/modules/agent/tools` — structure review and isolation plan

**Question asked:** *"what do you recommend about that structure? I want code is isolated."*

**Scope of measurement:** 56 files / 48,296 LOC in `src/modules/agent/tools/`, plus
the dispatch layer it plugs into (`src/agentic_loop/`, 72,954 LOC).

Everything below was verified by reading source, not by grepping and assuming.
Where a plausible-sounding claim turned out to be false on inspection, it says so.

---

## TL;DR

The directory is **much better than it looks, and its real problem is one level up.**

- Dispatch is *already* table-driven — there is no god-if-chain to dismantle.
- The shell family is *already* correctly factored and is the model to copy.
- What actually prevents isolation is **`tools_equipped.zig`**, which is three
  hand-maintained arrays that are not derived from each other, and the
  **`@import("nalarcore")` root import** that drags 451 `.zig` files into every
  "pure" tool file.

Adding one tool costs **7 files minimum, 8 to be visible in the UI**. That number
is the thing to attack, not file sizes.

This PR lands the zero-risk slice of that. The rest is sequenced below.

---

## What is already right (do not "fix" these)

| Fact | Evidence |
|---|---|
| Dispatch is a linear scan over one table, not an `else if` ladder | `handle_tool.zig:217-222` scans `UNIFIED_TOOL_REGISTRY()`; `dispatchFromRegistry` at `:282` calls `entry.exec` |
| Per-tool post-dispatch behaviour is **type-driven, not name-driven** | `ToolResult.skill_saved/agent_saved/progressive_tool_saved` set generically at `handle_tool.zig:310-322` |
| The shell family is properly layered | `shell.zig` (core) ← `command.zig` (OS dispatch) ← `bash.zig`/`pwsh.zig` (deprecated shims). `bash.zig:28` delegates to `command.execute_command`. Schema reuse is structural, so the wire shape *cannot* drift |
| Only 4 real intra-`tools/` library edges | `pr_cli→pr_provider`, `skill_tools→skills`, `list_memory→memories`, `present_files→file_sandbox` |
| The 9 design tools share zero state | none of them imports another — they are independent copies, which is the problem, not the virtue |

`shell.zig` is the pattern the rest of the directory should be pulled toward.
Note it was only possible because `shell.zig` was made a **leaf** that owns the
types, and `bash`/`pwsh` became **thin shims that reuse it**.

---

## The five problems, ranked by cost-to-user

### P1 — The registry is not a registry (highest value)

`src/agentic_loop/tools_equipped.zig` holds **three independent, hand-written
arrays in four non-adjacent regions**:

| Array | Line | Entries | What it decides |
|---|---|---|---|
| `equips()` | 78–165 | 44 | what the model is **shown** |
| `UNIFIED_TOOL_REGISTRY()` | 167 | 49 | what the dispatcher can **run** |
| `DEFAULT_AGENT_TOOLS` | 331 | 28 | what a fresh agent is **seeded with** |

Plus a 4th region of module aliases at lines 8–73. None is derived from
another. `isKnownToolName` (`:400`), `filterToRegistry` (`:477`) and the alias
table all derive from the registry — those are fine.

**The failure mode:** a name in `equips()` with no registry entry. The model is
shown the tool, emits a call, `handle_tool`'s scan misses, `isMCPTool` misses,
and the call dies as `error.UnknownTool` with the placeholder never replaced —
which renders in the UI exactly like a hung tool. **Nothing in the tree
cross-checked the two lists** before this PR.

**Cost:** 7 files per new tool (backend), 8 with the desktop checkbox.

### P2 — `@import("nalarcore")` in a "pure" tool file

`nalarcore` resolves to `src/root.zig`, the whole app façade. **26 of 56 tool
files import it.** The transitive closure is **451 `.zig` files, including all
128 files under `src/agentic_loop/`.**

Consequence: you cannot compile one tool without the world. "Isolated" is not
currently achievable, and no amount of file-splitting fixes it while this edge
exists.

Most only need two things:
- `nalar.sqlite` — 13 files
- `nalar.ai_mod.design_model` — 10 files (and `design_model.zig` is itself
  9,408 lines living in `agentic_loop`, which is why the design tools can't be
  tested alone)

There is already a written rule being violated: `progressive_tools.zig:12-16`
says a module under `src/modules/` *"must not import from `src/agentic_loop/`
(that would close an import cycle through the `nalarcore` root)"* — and
`get_plan.zig:41`, `update_plan.zig:47` and `spawn_sub_agent.zig:7` do exactly
that.

### P3 — The file name lies about where the tool lives

Only **30 of 48** wired tools have `tools/<wire_name>.zig` and
`tools_exec_<wire_name>.zig`. The rest:

| Wire name | Schema file | Exec adapter |
|---|---|---|
| `add_element` | `add_design_element.zig` | `tools_exec_add_element.zig` |
| `update_element` | `update_design_element.zig` | `tools_exec_update_element.zig` |
| `group_elements` | `group_design_elements.zig` | `tools_exec_group_elements.zig` |
| `save_memory`, `load_memory` | `memory.zig` | `tools_exec_memory.zig` |
| `search_skills`, `use_skill`, `remove_skill`, `add_skill`, `edit_skill` | `skill_tools.zig` | `tools_exec_skills.zig` |
| `search_tool`, `view_tool`, `use_tool` | `progressive_tools.zig` | `tools_exec_progressive_tools.zig` |
| `add_document`, `edit_document` | `document.zig` | `tools_exec_document.zig` |

**This is the single thing that makes the directory feel unisolated.** You
cannot navigate it by tool name: `grep read_file` finds the file, `grep glob`
finds nothing. Every lookup is a memorised mapping.

### P4 — Duplication that already drifted

| Cluster | Copies | Note |
|---|---|---|
| `errorJSON` + `errorJSONOwned` | 9 + 7 | byte-identical — **collapsed in this PR** |
| `validateElementIdShape` | 3 | only the baked-in tool name differed — **collapsed in this PR** |
| `GitignoreContext` + `gitignoreGlobMatch` + directory walker | 2 | `glob.zig` vs `indexing_semantic_search.zig`, ~400 LOC |
| `nanosleep` / `pollSleep10ms` | 2 | `shell.zig` vs `search.zig`, both self-document the copy |
| `joinPath` | 3 | `glob.zig`, `memories.zig`, `skills.zig` — byte-identical |
| `parseYamlFrontmatter` | 2 | `skills.zig` vs `agents.zig` |
| `sanitizeControlChars` | 2 | `search.zig:1278` has a private copy instead of the `helpers` one |

**Important correction:** 4 of the 13 `errorJSON` look-alikes are *not*
identical and must not be merged. `create_kanban_task.zig` and
`kanban_move_task.zig` deliberately emit `{"success":false,"error":...}` so the
exec adapter can surface a structured error. Merging them would change the
payload the model sees.

Also: the 3 `validateElementIdShape` copies had drifted in **check order**
(`update_element` tested `item_` before `page_`). That is **cosmetic, not a live
bug** — an id cannot begin with both prefixes, so the branch taken is the same.
Worth fixing because it is a copy that already diverged, not because it
misfires today.

### P5 — Dead weight

| Thing | Evidence | Action |
|---|---|---|
| `src/modules/agent/tools/tools.zig` barrel | 18 re-exports; the only importer is `root.zig:749` and **nothing reads `nalar.tools.*`** | delete the barrel, **keep** its two contract tests |
| `handle_semantic_search.zig` | 7 lines, a comment banner and 3 imports, zero functions, zero refs | **deleted in this PR** |
| `glob.zig` legacy gitignore | `Gitignore` struct + `loadGitignore` + `isIgnoredByGitignore` + `matchGitignorePattern` + `getGitignoreNegationContent` — **0 refs outside their own cluster** | **deleted in this PR** (132 lines) |
| `execChangeAgent` / `execListAgents` / `execRemoveAgent` | adapters + schemas exist, no registry entry; the `// === AGENT MANAGEMENT ===` section at `tools_equipped.zig:213` is **empty** | leave — see open question below |
| `auto_save_agent` field | `tools_equipped.zig:163`, never set true on any entry | remove, or wire up |
| 2 empty registry sections | `AGENT MANAGEMENT` (`:213`), `LSP TOOLS` (`:303`) | remove or fill |

**A claim that did NOT survive checking:** a sub-agent reported
`skills.zig` (615 LOC) as dead. It is live — `root.zig:903` exports it as
`skill_mod` and `skill_evals.zig`, `skill_detail.zig`, `skill_delete.zig` all
read it. Verified before acting; not touched.

---

## What this PR lands (Phase 1 — all zero behavior change)

1. **`src/helpers/tool_json.zig` (new)** — the single `{"error":...}` envelope.
   9 byte-identical copies collapsed onto it. Wired into `helpers/mod.zig` and
   given its own `test:helpers:tool_json` build step, because `helpers` is a
   standalone package whose inline tests are not reachable from `src/root.zig`
   (same reason `run_captured.zig` and `test_path.zig` each have their own root).
2. **`src/modules/agent/tools/design_ids.zig` (new)** — one
   `validateElementIdShape(allocator, element_id, tool_name)`. The tool name
   becomes a parameter instead of something each copy bakes in.
3. **Registry consistency guards (4 new tests)** in `tools_equipped.zig`:
   every advertised tool is dispatchable / registry names are unique /
   every default-seeded name is dispatchable / registry key matches the
   schema's own `function.name`.
4. **Dead code removed** — `glob.zig` legacy gitignore, the
   `handle_semantic_search.zig` stub, the `shell.zig:36` dead `schemas` import
   (which also collapses the `command ↔ schemas ↔ shell` import cycle).
5. **Test discovery made explicit** — `tools_equipped.zig` and
   `design_ids.zig` are now listed in their `test_runner.zig`. The
   `tools_equipped` tests were previously reachable only by accident via
   `workflow.zig`'s import.

**Guard proven to bite:** injecting a `ghost_tool` entry into `equips()` with no
registry row fails the build —
`error: 'agentic_loop.tools_equipped.test.every advertised tool is dispatchable' failed:
return error.AdvertisedToolNotDispatchable;`

`zig build install:linux` and `zig build test` are green (4,229 tests).

---

## Phases 2–4 (recommended, NOT done here — each needs its own PR)

### Phase 2 — break the 451-file closure *(the actual isolation fix)*

Add `src/modules/agent/tools/deps.zig` exposing only what tools reach the world
for:

```zig
pub const sqlite = nalarcore.sqlite;
pub const design_model = nalarcore.ai_mod.design_model;
```

Then move the 26 tool files from `@import("nalarcore")` to `@import("deps.zig")`.
Purely mechanical, no signature changes. Expected closure: **451 → ~60 files**,
and the cycle class that `progressive_tools.zig` warns about stops being
reachable from a tool file.

**Better still:** move `design_model.zig` (9,408 lines) out of `agentic_loop/`
into `src/models/`. It is a model, not a loop, and its presence there is why
10 design tools pull in the agent loop. Do this *before* `deps.zig` — it makes
`deps.zig` much smaller.

**Verify:** a new static-contract test that fails if any file under
`src/modules/agent/tools/` imports `nalarcore`. That is the guard that makes the
boundary real instead of aspirational.

### Phase 3 — make the registry a single source of truth

1. Add `default_on: bool` and `mode_scoped` to `ToolInfo` (`tools_equipped.zig:159`),
   so `DEFAULT_AGENT_TOOLS` and the mode strips stop being separate arrays.
2. **Derive `equips()` from `UNIFIED_TOOL_REGISTRY()`** rather than maintaining
   it. ⚠️ *This changes the order tools are advertised in.* That is a prompt-shape
   change, so it wants its own PR with a before/after prompt diff — not a
   drive-by.

### Phase 4 — make the directory navigable

Adopt **one** convention — `file == wire name == exec fn == registry key` — and
add the test that enforces it. Then rename incrementally behind `@import`
aliases so nothing else breaks. Start with the worst offenders
(`add_design_element.zig` → `add_element.zig`, `skill_tools.zig` → `skills/`,
`progressive_tools.zig` → `progressive/`).

Also worth folding in: collapse the two `GitignoreContext` copies
(`glob.zig` + `indexing_semantic_search.zig`, ~400 LOC) into one
`tools/gitignore.zig`. That is the largest remaining duplication and the
copy has already diverged — glob's entry carries `directory_only`, indexing's
does not.

---

## Open questions for the human

1. **`change_agent` / `list_agents` / `remove_agent`** have full schemas and exec
   adapters but no registry entry, and `auto_save_agent` is never set true.
   Is agent-switching meant to ship (in which case wire it up), or was it
   superseded by `spawn_sub_agent` (in which case delete it)?
2. **`move_element_to_page`** is dispatchable (registry `:289`) but absent from
   `equips()`, so no session can ever be offered it. The new guard only covers
   the dangerous direction (advertised-but-uncallable); this is the inverse gap
   and it is a **product** decision whether that tool should be advertised.
3. `list_memory`, `web_search`, `semantic_search`, `index_codebase` are all
   fully built and commented out of the registry. Re-enable or delete?
