# Skills Table + `search_skill` Implementation Plan (rev 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two changes that land together, because each is the other's precondition.

1. **`list_skills` → `search_skill`.** Delete the "dump every skill" tool and replace it with a **regex, paged** search tool whose contract mirrors the existing `search_tool` (`progressive_tools.zig:62-102`) — `query` / `literal` / `limit` / `offset` / `scope`, paged rows, `<total>`, `<pattern_warning>`, `did_you_mean`. Skill bodies never appear in search results; `use_skill` loads one.
2. **A `skills` table becomes the source of truth.** Today a skill *is* a `SKILL.MD` file on disk and the path is the handle the LLM passes around. That moves into a `skills` table (Migration 086); the filesystem becomes an **import/export surface**, not the runtime handle. `use_skill` takes a `skill_name`, not a path.

**Why these two are one change:** search-by-regex needs a store it can query in one pass without opening ~70 KB of `SKILL.MD` (the perf plan already measured `list_skills` reading 17 files twice each to emit ~2 KB of listings — `docs/superpowers/plans/2026-09-11-agentic-loop-perf-memory.md:41`), and it needs `tags` — which the frontmatter carries but **nothing parses today**. A table gives both. Conversely, a table with no search tool would mean "dump the whole table", which is the bloat we are removing.

**Architecture:** One new table, one extracted query core, one renamed tool.

1. **Migration 086** creates `skills` and **renames the existing `list_skills` tool rows** in `agent_tools` / `agent_kanban_tools` — without that data migration every existing agent silently loses skill discovery (its allowlist row would name a tool that no longer exists).
2. **`text_query.zig` (NEW, leaf)** — the regex/literal/fallback/paging core currently welded into `progressive_catalog.zig:165-272` is extracted so `search_tool` and `search_skill` call **one** implementation and cannot drift. This mirrors Task 1 of the progressive-tools plan, which did the same for tool eligibility.
3. **`skills_db.zig` (NEW)** — CRUD + search over the table, next to `agent_memories.zig` (the established home for a table's SQL).
4. **`use_skill` becomes name-based**, keeping its exact output envelope so the `skill_save` → `session_skills` snapshot path (`tools_exec_skills.zig:52-84` → `handle_tool.zig:643-647`) is **untouched**. That snapshot is what compaction uses for content-drift detection; it must not move in this change.

**Tech Stack:** Zig 0.16 (`AgentTool`, `ToolExecContext`), SQLite (`SqliteBackend.exec`/`query`), Vue 3 + vitest, python functional harness (isolated tmpdir HOME, ports 8080..8199 excl. 8081).

## Global Constraints

- **Port 8081 is never touched.** Functional tests use the harness's random port; never `nohup ./nalar --port 8081`.
- **No new live-server + `curl` verification.** Wire behaviour goes through `tests/functional/harness.py`; storage behaviour goes through in-memory SQLite (`SqliteBackend.init(io, ":memory:")`); pure logic goes through Zig inline tests.
- **Empty slices bind as SQL NULL.** `SqliteBackend.exec` collapses `""` to NULL, which a `NOT NULL` column rejects. Every write to `skills` wraps free-text params in `COALESCE(?, '')`. Precedent: Migration 085's `saveProgressiveTool` and Migration 079's `content` column. This gets its own test — it is the single most likely runtime failure in this plan.
- **The `skills` table is the runtime source of truth.** Disk is import + export only (Decision 1). No read path may stat a `SKILL.MD` to answer a query.
- **`cwd` keys are canonicalized.** Local skills are keyed by `cwd`; importer and lookup must both use the same `realpath`-canonicalized value, or the same workspace addresses two different rows and local skills become invisible — the exact failure `tools_exec_skills.zig:21-24` warns about.
- **`session_skills` is not migrated, renamed, or re-queried differently.** Only its upstream file read is replaced by a table read.
- **The skills listing is removed from the prompt.** No skill index is injected; discovery is `search_skill` plus a rule. `appendSkillsListing` (`prompts_build_messages_for_agent_prompt.zig:1648-1718`) is deleted with its call site.
- No `// NEW (plan: …)` comments. Comments explain *why*, not *when*.
- Cross-platform compile check for every touched Zig file (Linux/macOS/Windows).
- `vue-tsc --build` emits stray `.js` next to `.ts` — delete before committing.
- Verification gates: `zig build test --summary all`; `pnpm test:unit` (from `src/apps/desktop`); `bun run build`; `zig build install:linux` then `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v`.
- Work in the git worktree at `/home/ginwa/.config/nalar/.worktrees/adjust-skill-tool-mechanism-1789248644109`, open a PR.

## Current State (verified 2026-09-12 via 5 parallel explorers)

### What a skill is today

| Fact | Location |
|---|---|
| A skill **is** `<dir>/<name>/SKILL.MD`. No table, no cache, no index | `skills.zig:59` (`LOCAL_SKILLS_DIR=".nalar/skills"`), `:62` (`SKILL_FILE_NAME="SKILL.MD"`), `:527-570` (`list_skill_files_in_dir`) |
| Two roots: global `$XDG_CONFIG_HOME/nalar/skills/` else `$HOME/.config/nalar/skills/`; local `<cwd>/.nalar/skills/` | `skills.zig:488-503`, `:507-522` |
| Frontmatter parsed for `name` + `description` **only** — `tags:` is read by nothing | `skills.zig:87-138` (`parseYamlFrontmatter`, `ParsedFrontmatter{name,description}`) |
| The **prompt itself** mandates `tags: [workflow, environment, api, agent, fix, pattern]` and tells the agent to consult by tag — the data model has no tag column | `memory.zig:322-479`, esp. the `[workflow]` line and the SKILL FORMAT block |
| Every listing re-scans disk; open + stat per file, then a second open to read | `skills.zig:575-614`, `:302-336`; measured in `2026-09-11-agentic-loop-perf-memory.md:41` |
| Real path is the LLM-facing handle, and the prompt spends 8 lines warning the model how to pass it | `skill_tools.zig:262,267`; `prompts_build_messages_for_agent_prompt.zig:1681-1691` |
| `use_skill` accepts **any path** and reads it with no size cap (`Limit.limited(maxInt(usize))`), while the *listing* path caps at 100 KB | `skill_tools.zig:295-345` vs `skills.zig:7,317-323` |

### The five skill tools as registered

| Tool | Required args | Persistence side effect |
|---|---|---|
| `list_skills` | *(none, `cwd` optional)* | none |
| `use_skill` | `["path","is_global"]` | `skill_save` → `INSERT OR REPLACE INTO session_skills` (`llm_history.zig:3696-3710`) — **keep verbatim** |
| `add_skill` | `["name","description","content"]` | writes `<dir>/<name>/SKILL.MD`; also `skill_save` |
| `edit_skill` | `["skill_name"]` | rewrites the file; also `skill_save` |
| `remove_skill` | `["skill_name","session_id"]` | `deleteTree` on the folder |

All five are in `equips()` (`tools_equipped.zig:84,90-93`), `UNIFIED_TOOL_REGISTRY` (`:182-188`), and `DEFAULT_AGENT_TOOLS` (`:302-307`).

### Where skills surface (every consumer a table must feed)

| Surface | Location | Reads |
|---|---|---|
| `GET /api/skills` | `http_handlers/skills_list.zig:27-44,56`; route `main.zig:496` | `listAllSkills` → `{global_skills,local_skills,cwd}` |
| `GET /api/skills/:name` | `http_handlers/skill_detail.zig:23-102`; route `main.zig:497` | scans folders, matches frontmatter `name` |
| `DELETE /api/skills` | `http_handlers/skill_delete.zig:87-166`; route `main.zig:498` | `findSkillFolderByName` + `deleteTree` |
| Injected prompt listing | `prompts_build_messages_for_agent_prompt.zig:1648-1718` | `listAllSkills` **on every turn** |
| Skill instructions | `prompts/memory.zig:322-479` (`skills_system_prompt`), gated at `pbfap.zig:119-121` | static text |
| Escalation rule | `prompts/execution.zig:42` — "Same error twice → skill re-load" | static text |
| Equipped-skills badge | `session_skills` → REST `skills` (`llm_history.zig:772,821`) + SSE `session_skills` (`sse_on_event_send_llm_history.zig:139-177`) | **unchanged by this plan** |
| Frontend list/detail | `SkillList.vue`, `RightSideBarSkillList.vue`, `SkillDetail.vue`, `api/index.ts:2675-2734` | REST above |
| Frontend chat cards | `ListSkills.vue`, `UseSkill.vue`, `AddSkill/EditSkill/RemoveSkill.vue`, `toolOutputParser.ts:183-445`, `renderResponse.ts:214-221`, `ChatView.vue:3220-3249` | tool XML envelopes |
| Agent's default chat tools | `api/index.ts:1348-1358` (`DEFAULT_CHAT_TOOLS`) | names `list_skills`,`use_skill` |

### Pre-existing facts worth knowing

- **Next free migration number is 086** (085 = `session_progressive_tool`, `migration.zig:4695`).
- `uq_agent_tools_agent_tool ON agent_tools(agent_id, tool_name)` (`migration.zig:3439`) and `uq_agent_kanban_tools_kanban_tool ON agent_kanban_tools(kanban_id, tool_name)` (`:4518`) are **unique** — the tool rename must not violate them.
- The progressive-tools precedent solved "new tool never reaches existing agents" by making the meta-tools **allowlist-exempt** (`tools_equipped.zig:170-178`). A rename needs no such exemption: the row already exists and is renamed. Do not copy the exemption (Decision 4).
- `progressive_catalog.zig` already exports the pieces worth sharing: `QueryMode` (`:172-182`), `MatchOptions` (`:184-189`), `QueryResult` (`:191-197`), `matchQuery` (`:210`), `pageSlice` (`:840-844`), `didYouMean` (`:348-380`), `containsIgnoreCase` (`:274-282`), and the compiled-pattern warning string (`:241-247`).
- `matchQuery` is typed on `[]const Entry` (progressive-specific), so it is **not** directly reusable — only the predicate layer is. See Task 1.
- `UseSkill.vue:21` already reads `skill_name` from `parameters` while the backend takes `path` — a latent display bug that the rename **fixes**.
- `execListSkills` passes `ctx.cwd` deliberately (`tools_exec_skills.zig:21-24`) and `ToolExecContext` also carries `cwd_override` (`tools.zig:101`), `environment` (`:98`), and `db` (`:88`).

## Design Decisions (for reviewer)

1. **Disk demoted to import/export; the table wins on conflict.** `add_skill` / `edit_skill` / `remove_skill` write the table **and** mirror to `SKILL.MD` (best-effort, log-and-continue on failure). The boot/session importer uses `INSERT OR IGNORE` — it never overwrites an existing row. Consequences, stated honestly:
   - A skill committed to `.nalar/skills/` in a repo still appears on a fresh machine/DB (no row → imported). **The existing user workflow survives.**
   - Hand-editing `SKILL.MD` after the row exists does **not** change what the agent sees. Re-importing is deliberate (`remove_skill` then let it re-import, or a future `nalar skills sync`).
   - `edit_skill` through the agent is no longer silently reverted by the next boot — which is why "disk wins on every boot" was rejected.
   *Alternatives rejected:* import-once-then-ignore-disk (breaks the git-tracked workflow with no upside) and disk-wins-reconcile (agent edits vanish on restart — worse than the bug we are fixing).
2. **`search_skill`, not `search_skills`.** Singular matches `use_skill` and the table name. Renaming the tool also fixes the registry/`DEFAULT_CHAT_TOOLS` inconsistency in one step.
3. **No `cwd` parameter on `search_skill`/`use_skill`.** The tool reads `ctx.cwd` (canonicalized), exactly as `execListSkills` does. `list_skills`' optional `cwd` exists only because the HTTP route shares its implementation; the tool should never let the model retarget which workspace's local skills it sees.
4. **Data migration, not allowlist exemption, for the rename.** Migration 086 renames `list_skills` → `search_skill` in both tool tables. Exempting `search_skill` from the allowlist (the progressive-tools trick) would also hand it to a user who deliberately unchecked skill tools, overriding their intent. Recommended: rename. *Fallback if review distrusts the data migration:* a one-line exemption in `tool_eligibility.allowlistFilter` — cheap defense in depth, but it makes unchecking a lie.
5. **`scope` is a real column, `'global' | 'local'`.** Not a boolean: `use_skill`'s local-first resolution needs to say *which* row it loaded, and the UI renders two sections. Global rows carry `cwd=''`.
6. **`tags` become real.** Parse the frontmatter `tags:` line (both `[a, b]` and bare comma form) into a `||`-joined column, mirroring `agent_memories.tags`. This is the fix for a documented-but-unimplemented capability: the prompt already tells the agent to consult skills by tag (`memory.zig:428-433`) and the data model never had tags. `search_skill` matches tags as a third field.
7. **`use_skill` breaks its input contract deliberately.** `path` and `is_global` are **deleted**; `skill_name` (required) + `scope` (optional, local-first when omitted) replace them. Keeping `path` as a fallback would reintroduce a second source of truth, which is the entire thing being removed. An in-flight model calling `use_skill({path})` gets a validation error naming `skill_name` — self-healing in one turn.
8. **`use_skill` gains the size cap the listing path already has.** `MAX_SKILL_BYTES = 100 * 1024` (`skills.zig:7` has this number already, as `MAX_SKILLS_SIZE`); today `use_skill` reads unbounded. A row that exceeds it returns `<loaded>false</loaded>` with the byte count rather than silently flooding the context.
9. **No FTS5 table for skills in v1.** `search_tool` is regex-over-two-fields and that is the contract being mirrored; adding a second, differently-behaving search engine (BM25) over the same data would guarantee divergent results between the two tools. If semantic skill lookup is wanted later it is additive.
10. **No `view_skill`.** The prompt already mandates that a skill's `description` be "scannable in 1 second — it's what you read when skimming the index". With the index gone, the description *is* the search result. A second round trip to read a description that is already in the row would be pure overhead.
11. **`session_skills` keeps its verbatim `content` snapshot.** It is intentionally a snapshot: compaction compares the loaded text against the current row to detect drift. A DB-backed skill store makes that comparison *easier* (one indexed read instead of a file open) but does not change the design.
12. **Skill names are unique per scope, case-sensitive.** `UNIQUE(name) WHERE scope='global'` and `UNIQUE(cwd,name) WHERE scope='local'` via partial indexes. The same name in global and local is legal and `use_skill` reports which one loaded.

## Wire Contract

### Table (Migration 086)

```sql
CREATE TABLE IF NOT EXISTS skills (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  tags        TEXT NOT NULL DEFAULT '',       -- '||'-joined, mirrors agent_memories.tags
  content     TEXT NOT NULL,
  scope       TEXT NOT NULL DEFAULT 'global', -- 'global' | 'local'
  cwd         TEXT NOT NULL DEFAULT '',       -- canonicalized abspath for local; '' for global
  source_path TEXT NOT NULL DEFAULT '',       -- provenance only; never an LLM-facing handle
  created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skills_global_name
  ON skills(name) WHERE scope = 'global';
CREATE UNIQUE INDEX IF NOT EXISTS uq_skills_local_cwd_name
  ON skills(cwd, name) WHERE scope = 'local';
CREATE INDEX IF NOT EXISTS idx_skills_scope_cwd ON skills(scope, cwd);
CREATE INDEX IF NOT EXISTS idx_skills_updated ON skills(updated_at DESC);

-- Rename the tool for every existing agent. DELETE-then-UPDATE because
-- uq_agent_tools_agent_tool / uq_agent_kanban_tools_kanban_tool are unique
-- on (owner_id, tool_name) and would reject the update if a row for the new
-- name somehow already exists.
DELETE FROM agent_tools WHERE tool_name = 'search_skill';
UPDATE agent_tools SET tool_name = 'search_skill' WHERE tool_name = 'list_skills';
DELETE FROM agent_kanban_tools WHERE tool_name = 'search_skill';
UPDATE agent_kanban_tools SET tool_name = 'search_skill' WHERE tool_name = 'list_skills';
```

`session_skills` (Migration 008 / column renamed in 075) is **not touched**.

### `search_skill`

```json
{ "query": "zig|build", "literal": false, "limit": 40, "offset": 0, "scope": "global" }
```
All five optional; zero args = first page of every skill.

```xml
<search_skill><query>zig|build</query><pattern_mode>regex</pattern_mode>
<count>2</count><total>2</total><offset>0</offset><limit>40</limit>
<skills>
<skill><name>debug-hanging-zig-test</name><scope>local</scope><loaded>no</loaded>
<tags>zig||testing||debug</tags>
<summary>Use when a `zig test` run produces no output and times out — separates compile from run to identify the hanging test.</summary></skill>
</skills>
<hint>Call use_skill with the exact <name> (and <scope> when the same name appears in both) to load the full instructions. Skills already loaded this session are marked loaded=yes.</hint>
</search_skill>
```

- Match: compiled regex (case-insensitive, unanchored, the `progressive_regex.zig` subset) against `name` **or** `description` **or** `tags`. `literal: true` → case-insensitive substring. `scope` is an exact filter.
- Invalid pattern is **never an error**: degrades to substring, `<pattern_mode>literal_fallback</pattern_mode>` + `<pattern_warning>` carrying the same supported-syntax text as `search_tool`.
- `summary` = `summaryOf(description, 120)`. `loaded` = `yes` when a `session_skills` row exists for `(session_id, name)` — prevents a pointless re-load.
- `limit` default 40, max 200; `limit<1`, `limit>200`, `offset<0` are **rejections** with the same wording shape as `tools_exec_progressive_tools.zig:124-154`.
- Never includes `content` or `source_path`.
- No match → `<count>0</count><skills></skills>` + hint, not an `<error>`.

### `use_skill`

```json
{ "skill_name": "debug-hanging-zig-test", "scope": "local" }
```
`scope` omitted → local-first (canonicalized `ctx.cwd`), then global. Output envelope is **byte-identical to today** so `tools_exec_skills.zig:52-84` keeps extracting `skill_save`:

```xml
<skill_name>debug-hanging-zig-test</skill_name>
<content>---\nname: ...\n---\n## When to Use\n...</content>
<loaded>true</loaded>
<scope>local</scope>
```

Unknown name (**zero writes**) → `<loaded>false</loaded>` + `<error>unknown skill 'x' — use search_skill to list candidates</error>` + `<did_you_mean>` (reuses the extracted `didYouMean`). Oversized → `<loaded>false</loaded>` + `<error>skill 'x' is 214933 bytes, over the 102400-byte limit</error>`.

### HTTP

| Route | Change |
|---|---|
| `GET /api/skills?query=&literal=&limit=&offset=&scope=&cwd=` | table read; `{skills:[…], count, total, offset, limit, pattern_mode, pattern_warning, cwd}`. No params = whole list, so the two existing frontend list components keep working with a one-line change |
| `GET /api/skills/:name?scope=&cwd=` | table read; `{skill:{name,description,tags,content,scope,source_path,updated_at}|null, error_message}` |
| `DELETE /api/skills?name=&scope=&cwd=` | `DELETE FROM skills`, plus the mirrored `SKILL.MD` folder when one exists; `{success, skill_name, deleted_from, error_message}` |

No `POST`/`PATCH` routes in v1 — the settings UI has no create/edit form, and `add_skill`/`edit_skill` already provide the write path to the agent.

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Migration 086 (DDL + tool rename) + register in `allMigrations` (`:1791`) + inline tests in the `085` block's style (`:5200-5277`) |
| `src/agentic_loop/text_query.zig` | NEW | **Leaf.** `Query` = compiled-regex-or-literal predicate over N text fields; `init(query, literal)`, `matchesAny(fields)`, `mode`, `warning`, `deinit`. Plus `pageSliceGeneric`, `containsIgnoreCase`, `didYouMean`. Moved **verbatim** from `progressive_catalog.zig:165-282,348-380,840-844` |
| `src/agentic_loop/progressive_catalog.zig` | EDIT | `matchQuery` / `didYouMean` / `pageSlice` delegate to `text_query.zig`. **Behaviour must not change** — its 40+ inline tests are the regression net |
| `src/agentic_loop/skills_db.zig` | NEW | `upsertImportedSkill`, `saveSkill`, `getSkillByName(scope?, cwd)`, `searchSkills`, `listSkills`, `deleteSkill`, `tagsToDisplay`. Every free-text bind `COALESCE(?,'')` |
| `src/agentic_loop/skills_import.zig` | NEW | `importGlobalSkills`, `importLocalSkills` (`INSERT OR IGNORE`, idempotent), `mirrorToDisk` (export), `canonicalCwd` |
| `src/modules/agent/tools/skills.zig` | EDIT | keep for path resolution + `SKILL.MD` scanning + frontmatter parsing; add `parseYamlFrontmatter` tag support (`tags:` → `[]const u8` `||`-joined); keep the constant names |
| `src/modules/agent/tools/skill_tools.zig` | EDIT | `list_skills_tool` → `search_skill_tool`; `UseSkillInput{skill_name,scope}`; `SearchSkillInput`; `execute_search_skill`; rewrite `execute_use_skill_to_string` to read the DB; `add/edit/remove` write the table (+ mirror) |
| `src/agentic_loop/tools_exec_skills.zig` | EDIT | `execListSkills` → `execSearchSkill`; `execUseSkill` passes `ctx.db`/`ctx.cwd` |
| `src/agentic_loop/tools_equipped.zig` | EDIT | `equips()`, `UNIFIED_TOOL_REGISTRY`, `DEFAULT_AGENT_TOOLS`: `list_skills` → `search_skill`; import + re-export names |
| `src/agentic_loop/tools.zig`, `src/root.zig` | EDIT | re-exports: `list_skills_tool` → `search_skill_tool`, `execListSkills` → `execSearchSkill` |
| `src/agentic_loop/handle_tool.zig` | EDIT | dispatch: `list_skills` → `search_skill` |
| `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | EDIT | **delete** `appendSkillsListing` (`:1648-1718`) + its call (`:223-224`); gate `skills_system_prompt` on `search_skill` (`:119-121`) |
| `src/modules/agent/prompts/memory.zig` | EDIT | rewrite the discovery/tags/path paragraphs of `skills_system_prompt` (`:322-479`) for search-based discovery + name-based `use_skill` |
| `src/modules/agent/prompts/execution.zig` | EDIT | `:42` "skill re-load" → `search_skill` then `use_skill` |
| `src/http_handlers/skills_list.zig`, `skill_detail.zig`, `skill_delete.zig` | EDIT | read/write the table |
| `src/main.zig` | EDIT | run `importGlobalSkills` after migrations; optional `importLocalSkills` at session start |
| `src/apps/desktop/src/api/index.ts` | EDIT | `Skill` gains `tags`/`scope`/`source_path?`, loses `path`; `getSkills(params)`; `DEFAULT_CHAT_TOOLS` (`:1348-1358`): `list_skills` → `search_skill` |
| `src/apps/desktop/src/components/tool_outputs/ListSkills.vue` → `SearchSkill.vue` | RENAME+EDIT | new envelope; `loaded`/`scope`/`tags` chips |
| `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` | EDIT | `parseListSkills` → `parseSearchSkill` |
| `src/apps/desktop/src/components/preview/UseSkill.vue` | EDIT | keep `skill_name` parsing (already correct); add `scope` |
| `src/apps/desktop/src/components/{shell/RightSideBarSkillList,shell/SkillDetail,tool_outputs/SkillList}.vue` | EDIT | drop `path` display → `scope` badge + `tags`; `Path:` → `Source:` |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | `list_skills` branch → `search_skill` (`:3220-3249`) |
| `src/apps/desktop/src/helpers/renderResponse.ts` | EDIT | `:214-221` name list |
| `tests/functional/skills_table_test.py` | NEW | wire + DB assertions |
| `tests/functional/memories_skills_test.py` | EDIT | its 3 skill tests now assert table semantics (import-on-write, delete-a-row) |
| `docs/superpowers/plans/2026-09-12-skills-table-and-search-skill.md` | THIS FILE | Plan under review |

## Tasks

### Task 1 — Extract the shared query core (pure refactor, no behaviour change)

- [ ] Create `src/agentic_loop/text_query.zig`: `QueryMode` (`all`/`regex`/`literal`/`regex_fallback`), `MatchOptions{literal}`, `Query` with `init(allocator, query, opts) !Query`, `matchesAny(fields: []const []const u8) bool`, `.mode`, `.warning`, `.deinit()`. Move the regex-compile + fallback + warning string **verbatim** from `progressive_catalog.zig:227-272` and `containsIgnoreCase` (`:274-282`). Add `pageSlice`/`didYouMean` as generic helpers (they are already type-agnostic except for the element type).
- [ ] `progressive_catalog.matchQuery` keeps its signature and its `[]const Entry` filtering, but its predicate becomes `q.matchesAny(&.{entry.name, entry.tool.function.description})`. `renderSearchResult` keeps consuming `QueryResult`.
- [ ] `text_query_test.zig`: for each case `progressive_catalog`'s existing test list covers — `^mcp_.*_create`, `docs|documentation`, `\bsearch\b`, invalid `^(list` → fallback + warning text, `literal:true` A/B, empty query → `all`, step/instruction caps → warning — assert the same outcome **through the new API**.
- [ ] Run the full `progressive_catalog` + `tools_exec_progressive_tools` suites unmodified. They must be green before Task 6 touches anything. This is the refactor gate.
- [ ] Register `text_query.zig` in `src/ai_workflow/tui/test_runner.zig` (pattern: `_ = @import("../../agentic_loop/<file>.zig");`).
- [ ] `Commit:` `refactor(agentic-loop): extract the regex/literal query core into a leaf module`

### Task 2 — Migration 086 + `skills` CRUD

- [ ] Add `Migration086AddSkillsTable` with the DDL above; register in `allMigrations`.
- [ ] Inline tests: columns exist; re-running is idempotent; `uq_skills_global_name` rejects a second global row with the same name; the same name is allowed in global *and* local; `uq_skills_local_cwd_name` rejects a duplicate `(cwd,name)` but allows the same name at a different `cwd`; the tool rename moves `list_skills` rows in both tables, is idempotent on re-run, and leaves exactly one row per owner (assert counts, not just "no error"); an owner holding both names ends with one row.
- [ ] `skills_db.zig`: `saveSkill` (`INSERT ... ON CONFLICT DO UPDATE SET description/tags/content/updated_at`, preserving `created_at` — do **not** use `INSERT OR REPLACE`), `getSkillByName`, `searchSkills(query, literal, scope, cwd, limit, offset)`, `listSkills`, `deleteSkill`, `upsertImportedSkill` (`INSERT OR IGNORE`).
- [ ] **The NULL-bind test:** save a skill with `description=""` and `tags=""` and `source_path=""`; assert it round-trips as `""` (not an error, not NULL) and that `searchSkills("")` returns it. Then assert the same for a local row with `cwd=""`→ every write path has `COALESCE(?,'')`.
- [ ] Inline tests: `searchSkills` regex hit on name / description / **tags**; literal A/B; invalid pattern → `literal_fallback` + warning; `scope` filter; `limit`/`offset` paging over a 5-row fixture is disjoint and `total` stays pre-page; unknown name → null.
- [ ] `Commit:` `feat(db): migration 086 skills table + skills_db CRUD`

### Task 3 — Disk → table importer + export mirror

- [ ] `skills_import.zig`: `canonicalCwd(allocator, io, cwd) ![]const u8` (realpath; `""` on failure so a bad cwd yields no local rows rather than a crash).
- [ ] `importGlobalSkills(allocator, io, db, environment) !ImportStats` — scan `get_global_skills_path_from_env`, one `upsertImportedSkill(scope='global', cwd="")` each. `importLocalSkills(..., cwd)` — scan `joinPath(canonical, ".nalar/skills")`, `scope='local', cwd=canonical`.
- [ ] **`INSERT OR IGNORE`, never overwrite** (Decision 1). Tag/description parsing reuses the extended `parseYamlFrontmatter`.
- [ ] `mirrorToDisk(allocator, io, row) !void` — best-effort write of `<dir>/<name>/SKILL.MD` with frontmatter rebuilt from the row (`buildSkillContent` at `skill_tools.zig:668-690` already does this shape). Log-and-continue on failure; never fail the tool call.
- [ ] `main.zig`: run `importGlobalSkills` after `runMigrations()`; log row counts. Local import runs where a session's cwd is known (the chat-start / workspace-activate path) so a repo's `.nalar/skills/` is picked up.
- [ ] Inline tests: empty DB + fixture dir → N rows; second run → still N rows and **no `updated_at` bump**; a hand-edited fixture after import → content unchanged (pins Decision 1); a dir with no `SKILL.MD` or with empty `SKILL.MD` → skipped; malformed frontmatter → skipped (matches today's silent-skip behaviour).
- [ ] `Commit:` `feat(skills): import SKILL.MD into the skills table; mirror writes back to disk`

### Task 4 — `search_skill` tool + exec adapter

- [ ] `skill_tools.zig`: `search_skill_tool: AgentTool` (wire name `search_skill`, 5 optional props, `required = &.{}`) + `search_skill_system_prompt` (regex, paging, `<total>`, `literal:true`, tags, `loaded`, "bodies come from `use_skill`"). Copy `search_tool`'s description shape (`progressive_tools.zig:62-102`) — it is the contract being mirrored.
- [ ] `SearchSkillInput{query?,literal?,limit?,offset?,scope?}`; `execute_search_skill(allocator, io, db, session_id, cwd, input)` → `skills_db.searchSkills` + `pageSlice` + renderer. `scope` outside `{"","global","local"}` → error naming the allowed values.
- [ ] Renderer produces the `Wire Contract` envelope, incl. `loaded=yes` from `llm_history.isSkillLoaded` (`:3676-3693` — currently has **no callers**; this is its first real one).
- [ ] `execSearchSkill` in `tools_exec_skills.zig`: validate `limit`/`offset` with `search_tool`'s exact rejection wording (`tools_exec_progressive_tools.zig:124-154`), then `wrapToolOutput`.
- [ ] Inline tests: schema shape (0 required, 5 props, `limit` mentions `default 40`/`max 200`); regex hit; `literal:true` flips the result set; invalid pattern → `<pattern_mode>literal_fallback</pattern_mode>` + `<pattern_warning>`; paging disjoint with stable `total`; each rejection; `scope=local` excludes global rows; **no `<content>` anywhere in the output**; `loaded=yes` after a `session_skills` fixture row; empty table → `count=0` and no `<error>`.
- [ ] `Commit:` `feat(tools): search_skill — regex, paged skill search`

### Task 5 — `use_skill` becomes name-based

- [ ] `UseSkillInput{skill_name?, scope?}`; delete `path` + `is_global`. `execute_use_skill_to_string(allocator, io, db, session_id, cwd, input)`: local-first when `scope` is empty, then global; `<loaded>true</loaded>` + `<scope>` on hit.
- [ ] Enforce `MAX_SKILL_BYTES = 100 * 1024` (the number already in `skills.zig:7`) with the byte-count error from the Wire Contract. Do **not** silently truncate.
- [ ] Unknown name → `<loaded>false</loaded>` + `<error>` + `<did_you_mean>` via `text_query.didYouMean`; zero writes.
- [ ] Confirm the `skill_save` extraction (`tools_exec_skills.zig:52-84`) and `handle_tool.zig:643-647` need **no change** — the outer envelope is identical. If they do, stop: that means the envelope drifted.
- [ ] `execUseSkill` passes `ctx.db`, `ctx.cwd`.
- [ ] Inline tests: global-by-name; local-by-name; local-first when a name exists in both (assert `<scope>local</scope>`); `scope=global` wins despite a local row; unknown → did-you-mean + `loaded=false`; oversized row → `loaded=false` + byte count; `session_skills` gains exactly one row after a successful load and **zero** after a failure.
- [ ] `Commit:` `feat(tools): use_skill loads by name from the skills table`

### Task 6 — Registry, seeding, dispatch, re-exports

- [ ] `tools_equipped.zig`: `equips()` entry → `search_skill` (imported as `skill_tools_mod`; `search_skill_tool`); `UNIFIED_TOOL_REGISTRY` row `.name = "search_skill"`; `DEFAULT_AGENT_TOOLS` entry → `search_skill`. Fix the comment at `:122-125` if it names `list_skills`.
- [ ] `tools.zig` + `root.zig`: `execSearchSkill`, `search_skill_tool` re-exports; delete the `list_skills` aliases.
- [ ] `handle_tool.zig`: registry dispatch name `search_skill`.
- [ ] Static-contract test (copy `tools_exec_progressive_tools.zig:527-550`): `equips()`, `UNIFIED_TOOL_REGISTRY()` and `DEFAULT_AGENT_TOOLS` all agree `search_skill` exists and `list_skills` exists **nowhere** in `src/`. Grep-style assertion, so a missed string is a test failure, not a runtime surprise.
- [ ] `Commit:` `feat(tools): register search_skill; retire list_skills`

### Task 7 — Prompts: drop the index, teach the search

- [ ] **Delete** `appendSkillsListing` (`prompts_build_messages_for_agent_prompt.zig:1648-1718`) and its call at `:223-224`. Deleting it removes a per-turn full-disk scan — record the byte/time delta for the PR (Task 10).
- [ ] `:119-121`: gate on `hasTool(filtered_tools, "search_skill")` before appending `skills_system_prompt`.
- [ ] `prompts/memory.zig` `skills_system_prompt`: rewrite the discovery paragraphs. Specifically —
  - `"## WHEN TO CONSULT SKILLS"`: keep the intent, but the trigger is a `search_skill` call with a domain regex (`zig|build`, `deploy|release`, `vitest|test`), not an injected index.
  - `"## BEFORE WRITING: CHECK FOR AN EXISTING SKILL"`: `list_skills` → `search_skill`.
  - The `[workflow]`, `[environment]`, `[api]` tags line becomes **actionable for the first time** (tags are now stored and matched) — say so.
  - The `use_skill` paragraph teaching case-sensitive `SKILL.MD` paths and `~` non-expansion (`pbfap.zig:1681-1691`'s text is the same warning) is **deleted** — there is no path argument any more.
  - `"Description must be scannable in 1 second — it's what you read when skimming the index"` → re-anchor on search: the description is what `search_skill` returns and how the next session decides whether to load the skill. The requirement survives; its justification is now truthful.
  - The `| .nalar/skills/<name>/SKILL.MD |` table row (`:141`) → `| skills table |`.
- [ ] `prompts/execution.zig:42`: "skill re-load" → "`search_skill` then `use_skill`".
- [ ] Update the per-tool `system_prompt` strings that reference `list_skills`: `add_skill` (`skill_tools.zig:552-558` "Check for existing skill with `list_skills` first") and any sibling.
- [ ] `prompts_test.zig:92-155`: the two tests seed a `SKILL.MD` under a fake `XDG_CONFIG_HOME` and assert the `Available Skills` section. **Rewrite** them for the new contract: the section is *gone*, so assert absence-of-listing + presence of the search rule when `search_skill` is equipped, and presence of neither when it is not.
- [ ] `Commit:` `docs(prompt): skill discovery is search_skill, not an injected index`

### Task 8 — HTTP handlers read the table

- [ ] `skills_list.zig`: `{skills:[…], count, total, offset, limit, pattern_mode, pattern_warning, cwd}` from `skills_db.searchSkills`; all params optional so `GET /api/skills` still returns everything. Import `skills_db` directly (`nalarcore.skills_db`) rather than going through `skill_tools` — the route is not a tool.
- [ ] `skill_detail.zig`: table read; `{skill:{name,description,tags,content,scope,source_path,updated_at}|null, error_message}`; drop the folder scan + `100*1024` file read.
- [ ] `skill_delete.zig`: `DELETE FROM skills` by `(name, scope, cwd)`; also remove the mirrored folder when `source_path` points at one. Local delete still **requires** `cwd` (keep `:87-93`'s 400).
- [ ] Register `skills_db` + `skills_import` in `root.zig`.
- [ ] Inline/handler tests where the existing files have them; otherwise rely on Task 10's functional tests.
- [ ] `Commit:` `feat(http): skills routes read the skills table`

### Task 9 — Frontend

- [ ] `api/index.ts`: `Skill` → `{name, description, tags, scope, source_path?, updated_at?}` (drop `path`); `getSkills(params?: {query?,literal?,limit?,offset?,scope?,cwd?})` returning the new shape; `SkillDetail` keeps `content` + `is_global` derived from `scope` (or replace with `scope` and update consumers — prefer the latter, one less lie in the type). `DEFAULT_CHAT_TOOLS`: `list_skills` → `search_skill`.
- [ ] Rename `ListSkills.vue` → `SearchSkill.vue` (+ `__tests__/ListSkills.successArgs.spec.ts` → `SearchSkill.successArgs.spec.ts`) and `parseListSkills` → `parseSearchSkill` in `toolOutputParser.ts`; render `scope`/`tags`/`loaded` chips and the paged `<hint>`.
- [ ] `UseSkill.vue`: keep `skill_name` (already correct), add `scope`, keep the in-progress spec green.
- [ ] `RightSideBarSkillList.vue`, `SkillList.vue`, `SkillDetail.vue`: replace `path` display with a `scope` badge + `tags`; `SkillDetail`'s `Path:` block becomes `Source:` (optional `source_path`) so provenance is not lost.
- [ ] `ChatView.vue:3220-3249` + `renderResponse.ts:214-221`: `list_skills` → `search_skill`.
- [ ] `pnpm test:unit` + `bun run build`; delete stray `.js` emitted next to `.ts`.
- [ ] `Commit:` `feat(desktop): search_skill card; skills are table rows, not paths`

### Task 10 — Functional tests + measurement

- [ ] `tests/functional/skills_table_test.py` (harness, isolated HOME, non-8081 port):
  - **Import:** write `$HOME/.config/nalar/skills/my-skill/SKILL.MD` with `name`/`description`/`tags` frontmatter **before** boot; assert a `skills` row exists (direct `sqlite3` on `<tmp>/.config/nalar/agent.db`) and `GET /api/skills` lists it with `scope=global` and the parsed tags. (This is `memories_skills_test.py:221` rewritten for the table.)
  - **Search:** `GET /api/skills?query=` with a regex, a literal, an invalid pattern (→ `literal_fallback` + warning), and a paging pair; assert `total` stays pre-page.
  - **Delete:** `DELETE /api/skills?name=…&scope=global` → row gone, `GET` no longer lists it, second delete is a clean miss.
  - **Tags are real:** a skill whose *description* does not contain the query but whose `tags` do is returned. This is the assertion that proves the new capability.
- [ ] `tests/functional/memories_skills_test.py`: update the 3 skill tests to table semantics; keep the memory tests untouched.
- [ ] `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/skills_table_test.py tests/functional/memories_skills_test.py -v` (after `zig build install:linux`).
- [ ] Measure (for the PR body, not the code): bytes+ms saved per turn by deleting `appendSkillsListing` — the header line at `2026-09-11-agentic-loop-perf-memory.md:41` gives the pre-change number to compare against; report the post-change number from a session with N skills.
- [ ] `Commit:` `test(functional): skills table — import, regex search, tags, delete`

## Verification

- `zig build test --summary all` — green, including `text_query_test`, the 40+ `progressive_catalog` tests **unmodified** (Task 1's refactor gate), migration 086 tests, `skills_db` tests, and the static-contract test that `list_skills` appears nowhere in `src/`.
- `pnpm test:unit` (from `src/apps/desktop`) + `bun run build` — green.
- `pytest` for `skills_table_test.py` + `memories_skills_test.py` — green, port ≠ 8081, isolated HOME.
- **Refactor gate:** Task 1 changes no behaviour. Every pre-existing `progressive_catalog` / `tools_exec_progressive_tools` test passes with zero edits before Task 6 lands.
- **Source-of-truth gate:** with a `SKILL.MD` present on disk and a *different* content in its row, `search_skill` + `use_skill` + `GET /api/skills/:name` all return the row's content. No read path stats a file.
- **No-regression gate for existing agents:** before Migration 086 an agent's `agent_tools` holds `list_skills`; after, it holds `search_skill` and `list_skills` is absent, with the same row count (assert in the migration test).
- **NULL-bind gate:** a skill stored with empty `description`/`tags`/`source_path` round-trips as `""` and is searchable — the failure mode this plan is most likely to hit.
- **Context gate:** no `search_skill` result contains `<content>`; a 200-skill table still returns ≤ `limit` rows plus one hint.
- **Snapshot gate:** a successful `use_skill` adds exactly one `session_skills` row; a failed one adds zero; the `skill_save` extraction in `tools_exec_skills.zig:52-84` is byte-for-byte unchanged.
- Port 8081 was never touched; no `./nalar + curl` was used for verification.

## Out of Scope (explicit non-goals)

- FTS5 / BM25 / embedding ranking for skills (Decision 9).
- A `view_skill` tool (Decision 10) and a `view_skill`/`search_skill` progressive-tool-style equip dance — skills are not allowlisted away from the agent, so there is nothing to equip.
- `POST` / `PATCH /api/skills` routes and any create/edit UI.
- Renaming `use_skill`, `add_skill`, `edit_skill`, `remove_skill` (only `list_skills` → `search_skill` was asked for; the other four keep their names and change only their storage).
- Migrating or reshaping `session_skills`.
- Skill versioning / history / diffing.
- Per-workspace-item skill scoping — v1 keys local skills by canonicalized `cwd`.
- A `nalar skills sync` CLI to force disk→DB re-import (Decision 1's escape hatch; additive later).
- Removing the disk mirror entirely.
- Reaping mirrored `SKILL.MD` files whose row was deleted outside `remove_skill`.

## Open Questions for the reviewer

1. **The disk mirror (Decision 1).** Keep writing `SKILL.MD` so `.nalar/skills/` stays commit-able and portable to a fresh machine, or make the table the only copy (simpler, but a fresh machine has no skills until the agent re-creates them)? **The plan keeps the mirror**, because `.nalar/skills/` being git-tracked is an existing user workflow and import-on-missing-row preserves it exactly. If you want the table to be the *only* copy, say so — it removes Task 3's `mirrorToDisk` and the "hand-edits don't apply" caveat, at the cost of portability.
2. **`scope` semantics for local skills.** v1 = `cwd`-scoped (a skill added in repo A is invisible in repo B). Alternative: make every skill global and keep `cwd` as provenance only — simpler, but two repos can then collide on a name, and today's global/local split disappears. **The plan keeps the split.**
3. **Do `add_skill` / `edit_skill` / `remove_skill` keep their disk writes at all?** Decision 1 says yes (mirror). If you answer Q1 with "table only", these three become pure table writes and Task 3 shrinks.
4. **Should the removed prompt index be replaced by a *compact* name+description index** (gated on `search_skill`) if dogfood shows the agent failing to reach for the search tool? The plan ships search-only, with the rule text carrying the burden. The fallback is one function — mirroring the progressive-tools plan's Decision 8 pattern (ship minimal, keep the mitigation recorded).

## Risks

1. **The tool rename loses skill discovery for existing agents** if the data migration misses a table or violates a unique index. Mitigation: DELETE-then-UPDATE in the correct order, count assertions in the migration test, plus the Task 6 static contract that `list_skills` is gone from `src/`. Do not "simplify" the DELETE away.
2. **An empty string reaching a `NOT NULL` column** (the `""`→NULL bind). Mitigation: `COALESCE(?,'')` on every free-text write, one dedicated gate test (Task 2), and the functional test writing an empty-description skill. This is the highest-probability failure in the plan.
3. **Disk/DB divergence confuses users** ("I edited my SKILL.MD and nothing changed"). Mitigation: the importer's `INSERT OR IGNORE` makes the rule crisp — *first import wins, agent edits win thereafter* — and the `use_skill`/settings UI surfaces `source_path` + `updated_at` so the row's provenance is visible. Named explicitly in Open Question 1 so the reviewer can override.
4. **`cwd` canonicalization mismatch makes local skills invisible** — the same bug `tools_exec_skills.zig:21-24` documents. Mitigation: one `canonicalCwd` helper used by the importer, `search_skill`, `use_skill` and the delete route; a functional test that imports from a symlinked path and finds the row.
5. **Task 1's extraction silently changes `search_tool`'s behaviour.** Mitigation: move code verbatim, keep `matchQuery`'s signature and `QueryResult` shape, and require the full progressive test suite green with **no test edits** before Task 6.
6. **A model stays on `use_skill({path})`** (in a long transcript or a stale system prompt from another client). It gets a validation error naming `skill_name`, and the rewritten prompt teaches the new form — self-healing in one turn. Accepted; noted so the reviewer is not surprised by a one-turn regression in a resumed session.
7. **Mirror-write failure on a read-only FS** leaves disk stale while the table stays correct. Log-and-continue is deliberate: failing the tool call would make skills uneditable in a read-only workspace for no benefit.
8. **Tags parsing is new code.** `parseYamlFrontmatter` handles `name`/`description` only; tag parsing (`[a, b]`, `a, b`, quoting) can subtly disagree with what authors write. Mitigation: store the raw joined form, never re-serialize tags into the frontmatter on mirror-write unless unchanged, and test both bracket and bare forms plus an empty `tags:` line.
9. **`isSkillLoaded` gains its first caller** (`llm_history.zig:3676-3693`, currently dead). It is one indexed lookup per result row; if a broad query returns 40 rows that is 40 queries. Mitigation: if it shows up in profiling, fetch the session's loaded names once per call and check in memory — the same shape `search_tool` uses for `equipped_names` (`tools_exec_progressive_tools.zig:50-52`). Do it that way from the start if it is cheap.
10. **`migration.zig` grows past 5300 lines.** Not this plan's problem to solve, but the 086 block should follow the 085 layout so the file stays greppable.

## Plan saved checklist

- [x] Plan saved to `docs/superpowers/plans/2026-09-12-skills-table-and-search-skill.md`
- [x] Header includes Goal / Architecture / Tech Stack / Global Constraints
- [x] Bite-sized steps with `- [ ]` checkboxes and per-task commits
- [ ] User reviewed before execution
