# Skills in SQLite — the `skills` table becomes the source of truth

> **Status:** plan only. Nothing in this document is implemented.
> **Supersedes:** `docs/superpowers/plans/2026-09-12-skills-table-and-search-skill.md`
> (written 2026-09-12, added in `84121848`, **never executed** — it is absent from
> `HEAD`'s tree. Recover it with
> `git show 84121848:docs/superpowers/plans/2026-09-12-skills-table-and-search-skill.md`).
> That doc bundled a `list_skills` → `search_skill` rename with this table move. **This
> plan keeps the table move and drops the rename** — a tool rename needs a data
> migration across `agent_tools` / `agent_kanban_tools` and is a separate piece of work.
> Everything it learned about the schema, the `cwd` canonicalisation trap, and the
> empty-slice→NULL bind is carried forward here.

---

## 1. Goal, in one paragraph

Today a skill **is a file**: `<skills-root>/<name>/SKILL.MD`, where the root is
`$XDG_CONFIG_HOME/nalar/skills` (else `$HOME/.config/nalar/skills`) for *global* and
`<cwd>/.nalar/skills` for *local*. The **filesystem path is the handle the LLM passes
around**, and the *skill list* is produced by walking directories and parsing YAML
frontmatter off every file. This plan moves the source of truth into a new SQLite
table `skills` (Migration 094). After it lands, `GET /api/skills` is a `SELECT`, the
`list_skills` tool is a `SELECT`, `use_skill` takes a **`skill_name`** instead of a
`path`, and the filesystem survives only as (a) a one-time importer at boot and
(b) a best-effort mirror on write, so a repo-committed `.nalar/skills/` still works
on a fresh machine.

## 2. What changes for the user (and what does not)

| Today | After |
|---|---|
| Global skills = files under `~/.config/nalar/skills/` | Global skills = rows with `is_global = 1` |
| Listing walks a directory tree, opens+stats every file, reads every file a **second** time to parse frontmatter | Listing is one indexed `SELECT` |
| `use_skill({path: "/home/u/.config/nalar/skills/foo/SKILL.MD"})` — the model must copy an absolute path verbatim; the tool prompt spends 4 lines warning it not to construct one | `use_skill({skill_name: "foo"})` |
| `add_skill`/`edit_skill` write a file; a second process could silently clobber it | Writes a row; the file mirror is best-effort |
| `skill.path` is a real filesystem path the UI renders | `path` becomes **optional provenance** (`source_path`), may be `""` |
| Skill name collisions across global/local are resolved by directory search order | Resolved explicitly by the `is_global` + `cwd` columns |
| Frontmatter `tags:` is parsed by nothing, though the prompt tells the agent to consult skills by tag | A real `tags` column, parsed from the frontmatter and shown in `list_skills` |

**Explicit non-goals** for this plan (each is a deliberate "no"):

- **No `search_skill` rename.** `list_skills` keeps its name and its output envelope.
  Renaming requires a cross-table data migration; out of scope.
- **No FTS5 / BM25 index.** `list_skills` stays a full list. If a search tool is
  wanted later it is additive.
- **`session_skills` is untouched.** Its `content` snapshot is the compaction drift
  detector; only `use_skill`'s *internals* change, not its output envelope.

## 3. Verified current state

All line numbers verified against `HEAD` = `212624ab` in this worktree.

### 3.1 No `skills` table exists

```
$ rg -n "FROM skills|INTO skills|CREATE TABLE.*skills" --glob '*.zig' src
src/migrations/migration.zig:96:  CREATE TABLE IF NOT EXISTS session_skills (...)
```

Only `session_skills` (Migration 008) exists. Highest migration is **93**
(`Migration093AddOwnerColumns`). Next free version is **94**. Numbering is not gapless
(010 and 047 are unused) and file order ≠ numeric order — that is fine, because
`MigrationManager.runMigrations` (`migration.zig:1595-1612`) only tests
`migration.version > currentVersion`.

### 3.2 The filesystem layer

`src/modules/agent/tools/skills.zig` (615 lines) is the whole storage layer:

| Symbol | Line | What |
|---|---|---|
| `LOCAL_SKILLS_DIR = ".nalar/skills"` | 59 | local root, relative to cwd |
| `SKILL_FILE_NAME = "SKILL.MD"` | 62 | the on-disk file name (uppercase `.MD`) |
| `MAX_SKILLS_SIZE = 100 * 1024` | 7 | the listing path's read cap |
| `parseYamlFrontmatter` | 87-145 | returns `{name, description}` — **`tags:` is never read** |
| `get_global_skills_path_from_env` | 488-503 | `$XDG_CONFIG_HOME/nalar/skills` else `$HOME/.config/nalar/skills` |
| `get_local_skills_path_for_dir` | 520-522 | `<dir>/.nalar/skills` |
| `list_skill_files_in_dir` | 527-570 | `openDir` + `iterate` + per-entry `openFile` + `stat`, skips `size == 0` |
| `list_skills_from_dir_path` | 575-614 | second pass: `readFileAlloc` per file + `parseYamlFrontmatter` |

**Every listing is a double disk pass.** This is the perf the table removes.

### 3.3 The five agent tools

`src/modules/agent/tools/skill_tools.zig` (2115 lines) holds all five, registered in
`src/agentic_loop/tools_equipped.zig:201-207`:

| Tool | Registry line | Input | Effect today |
|---|---|---|---|
| `list_skills` | 202 | `cwd` (optional) | dir scan → `{global_skills, local_skills, cwd}` |
| `use_skill` | 203 (`.auto_save_skill = true`) | **`path`** (required), `is_global` (required, no-op) | `openFile` + `readFileAlloc(Limit.limited(maxInt(usize)))` — **unbounded**, no 100 KB cap |
| `remove_skill` | 204 | `skill_name`, `session_id` | `deleteTree` on the folder |
| `add_skill` | 206 (`.auto_save_skill = true`) | `name`, `description`, `content` | builds frontmatter, `createFileAbsolute` (truncating) |
| `edit_skill` | 207 | `skill_name`, + optional `description`/`content` | read-modify-write the file |

Two pre-existing defects surfaced by this research, both worth fixing while the file
is open:

- **`auto_save_skill` is a dead flag.** `rg -n auto_save_skill` returns 4 hits: the
  declaration (`tools_equipped.zig:149`), two `= true` rows, and a comment. **Zero
  reads.** The real mechanism is `ToolExecResult.skill_save`, set only by
  `execUseSkill` (`tools_exec_skills.zig:52-70`) and consumed only by
  `handle_tool.zig:808-813`. So **`add_skill` and `edit_skill` do not write to
  `session_skills` today**, despite carrying the flag. The comment at
  `tools_exec_skills.zig:139-146` claims the dispatcher re-parses the wrapped JSON;
  it does not, and `_ = SkillSaveInfo;` is a compile-only reference.
- **`use_skill` has no size cap** while the listing path caps at 100 KB
  (`skill_tools.zig:263` vs `skills.zig:7`). A DB-backed row inherits this unless
  the cap is added.

### 3.4 The three HTTP routes — already exist, filesystem-backed

`src/main.zig:601-603`:

```zig
try authed.get("/api/skills",      ai_mod.http_handlers.skillsListHandler);
try authed.get("/api/skills/:name", ai_mod.http_handlers.skillDetailHandler);
try authed.delete("/api/skills",   ai_mod.http_handlers.skillDeleteHandler);
```

All three already exist and all three read the filesystem. **A new table-backed
implementation must REPLACE them, not be added alongside** — `matchRoute` tries the
exact path first and returns on first hit, so a second `GET /api/skills` registration
is unreachable dead code.

Wire shapes they produce today:

- `skills_list.zig` → `SkillsListData { global_skills, local_skills, cwd }`
  (`skill_tools.zig:33-38`) — **the same struct is both the REST body and the
  `list_skills` tool's `data` payload**, so `path` leaks into the LLM's context today.
- `skill_detail.zig:15-19` → `SkillDetail { name, description, content, path, is_global }`.
- `skill_delete.zig:7-12` → `{ success, skill_name, deleted_from, error_message }`.

`GET /api/skills/:name` and `DELETE /api/skills` each **open the directory, read every
candidate `SKILL.MD` (100 KB cap each), parse frontmatter, and match by name** —
`skill_detail.zig:75-124`, `skill_delete.zig:136-166`.

### 3.5 The DB handle is already reachable from the tool layer

`src/agentic_loop/tools.zig:89-92`:

```zig
pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
```

**This is the single most important fact for feasibility: the agent tools already
carry a live DB handle.** No plumbing, no signature change, no new context field.
HTTP handlers get theirs from `nalarcore.getSingleton().db` (`root.zig:24-26`,
`root.zig:88`); `Db` *is* `SqliteBackend` under the default build
(`root.zig:741-744`).

### 3.6 The prompt no longer injects a skill index

Commit `838caba8` ("Remove unused prompt sections from buildMessages: … skills
listing …") deleted `appendSkillsListing`. Today
`prompts_build_messages_for_agent_prompt.zig:1396` is literally `_ = usedSkills;`.
The two tests at `src/modules/agent/prompts_test.zig:92` and `:148` therefore pass
**vacuously** — they assert a string that is never produced.

**Consequence for this plan:** there is no injected index to re-point at the table.
Discovery remains "`list_skills` → `use_skill`". The gate mechanism to re-use if a
section is ever wanted again is `PromptSection.requires_tool` +
`hasTool(tools, name)` (`:1163-1174`, `:1214-1221`, `:1405-1409`).

### 3.7 Dead code in the skill area

| Symbol | Where | Status |
|---|---|---|
| `makeSkillsEquippedContext` | `prompts_make_skills_equiped_context.zig`, re-exported `prompts.zig:6` | 0 call sites |
| `skills_system_prompt` | `prompts/memory.zig:322` | declaration only |
| `isSkillLoaded` | `llm_history.zig:4212` | declaration only |
| `parseSkillFromResult` | `handle_tool.zig:424-439` | XML parser for a pre-JSON envelope, 0 callers |
| `RightSidebar.vue` + `RightSideBarSkillList.vue` | frontend | never rendered by any component |
| `sidebar.ts:112-148` `skillsGlobalExpanded`/`skillsLocalExpanded` | frontend | only consumer is the dead `RightSideBarSkillList` |
| `src/models/session_skill.zig` | backend | **committed syntactically broken** — the `pub const SessionSkill = struct {` line is missing, so lines 21-28 are struct fields at file scope. Only reachable from the orphan `src/models/models_test.zig:26`, which no build target references — so it never compiles today. A landmine, not a build blocker. |

## 4. Target design

### 4.1 Schema — Migration 094

```sql
CREATE TABLE IF NOT EXISTS skills (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  tags        TEXT NOT NULL DEFAULT '',         -- '||'-joined, mirrors agent_memories.tags
  content     TEXT NOT NULL DEFAULT '',
  is_global   INTEGER NOT NULL DEFAULT 0,       -- 1 = global root, 0 = per-cwd; no FK, see below
  cwd         TEXT NOT NULL DEFAULT '',         -- canonical abspath when is_global=0; '' when is_global=1
  source_path TEXT NOT NULL DEFAULT '',         -- provenance only; NEVER an LLM-facing handle
  created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_skills_global_name
  ON skills(name) WHERE is_global = 1;
CREATE UNIQUE INDEX IF NOT EXISTS uq_skills_local_cwd_name
  ON skills(cwd, name) WHERE is_global = 0;
CREATE INDEX IF NOT EXISTS idx_skills_global ON skills(is_global, cwd);
```

Rules copied from the repo's own conventions:

- One statement per `db.exec` (`sqlite3_prepare_v2` compiles only the first).
- `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` for idempotency.
- Timestamps set in SQL (`datetime('now')`), never bound from Zig.
- No foreign keys. `PRAGMA foreign_keys` is deliberately off project-wide
  (Migration 093's comment, `migration.zig:4958-4961`); a declared FK would be
  documentation only.
- `NOT NULL DEFAULT ''` is fine **because every write site wraps free-text params in
  `COALESCE(?, '')`** (see §4.5). A `DEFAULT` does not save you when the column is
  explicitly bound to `NULL`.

### 4.2 `is_global`, everywhere — one concept, no translation layer

**Decision (locked 2026-09-28):** the wire and the tool inputs speak `is_global: bool`,
and so does the column. There is deliberately **no `scope` TEXT enum** — one concept
from the SQL to the JSON to the TypeScript, so there is no derivation function to get
wrong and no second vocabulary for a reader to hold.

A boolean is sufficient here because the row is fully addressed by
`(is_global, cwd, name)`:

| `is_global` | `cwd` | Meaning |
|---|---|---|
| `1` | `''` (invariant) | Global root — `$XDG_CONFIG_HOME/nalar/skills` or `$HOME/.config/nalar/skills` |
| `0` | canonical abspath | Local to exactly that workspace |

`use_skill`'s local-first resolution still says *which* row it loaded: it returns the
`SkillRow`, and the row carries the `is_global` value it was found with. The UI's two
sections are `is_global === 1` and `is_global === 0`. Two partial unique indexes (one
per branch) give the same name in both scopes for free.

**The `cwd=''` invariant is enforced in code, not by the schema** — `PRAGMA
foreign_keys` is off project-wide (Migration 093's comment, `migration.zig:4958-4961`),
so a CHECK constraint would be the only guard and this codebase does not use them for
this. `upsertSkill` overwrites `cwd` with `''` whenever `is_global = true`; a unit
test asserts it.

### 4.3 `tags` — parse the frontmatter the prompt already assumes

**Decision (locked 2026-09-28):** add the column. It has a real consumer even without
`search_skill`: the agent's system prompt already instructs it to consult skills by
tag, `parseYamlFrontmatter` returns only `{name, description}` today, and
`list_skills` output goes straight into the LLM's context. Without the column, the
documented-but-unimplemented capability stays documented and unimplemented forever.

- `parseYamlFrontmatter` (`skills.zig:87-145`) gains `tags`, accepting **both**
  frontmatter forms: `tags: [workflow, api, agent]` and a bare
  `tags: workflow, api, agent`. Store `'||'`-joined, mirroring
  `agent_memories.tags` — the same convention already in this repo.
- `ParsedFrontmatter` becomes `{name, description, tags}`. Every existing caller that
  does `defer freeParsedFrontmatter(allocator, fm)` still compiles; the one caller
  that frees `.name`/`.description` by hand (`skill_tools.zig:266-280`) must free
  `.tags` too. **This is the most likely place to leak** — `std.testing.allocator`
  will catch it.
- `add_skill` gains an optional `tags: []const u8` (comma-separated on input,
  normalised to `'||'` on write). `edit_skill` gains optional `tags`.
- `SkillInfo` / `Skill` / `SkillDetail` gain `tags`. The Zig JSON shape emits the
  joined string; the frontend splits on `'||'` into a `string[]` for display.
- The mirror writer (`buildSkillContent` / `buildEditSkillContent`,
  `skill_tools.zig:~530` / `~700`) must emit a `tags:` frontmatter line, or the disk
  mirror silently drops the tags on the next import. This is the one part of tags
  that is genuinely easy to forget.

### 4.4 Where the SQL lives

New file **`src/agentic_loop/skills_db.zig`**, next to `agent_memories.zig` — the
established home for a table's SQL. Public surface (thin CRUD, no JSON, no HTTP):

```zig
pub const SkillRow = struct {
    id, name, description, tags, content, cwd, source_path: []const u8,
    is_global: bool,
};

// `is_global: null` means "resolve local-first, then global" — the use_skill rule.
pub fn listSkills(alloc, db, is_global: ?bool, cwd: ?[]const u8) anyerror![]SkillRow
pub fn getSkill(alloc, db, name, is_global: ?bool, cwd) anyerror!?SkillRow
pub fn upsertSkill(alloc, db, input: UpsertSkillInput) anyerror![]u8  // returns id
pub fn updateSkill(alloc, db, input: UpdateSkillInput) anyerror!SkillRow
pub fn deleteSkill(alloc, db, name, is_global: bool, cwd) anyerror!bool
pub fn importFromDisk(alloc, io, db, environment, cwd) anyerror!void   // INSERT OR IGNORE, both roots
pub fn freeSkillRows(alloc, rows) void
```

`is_global` is an `INTEGER` in SQL, so every bind is stringified
(`std.fmt.allocPrint(allocator, "{d}", .{@intFromBool(x)})`) and every read is
`std.mem.eql(u8, row.values[i], "1")` — the codebase has no integer binding in
`argv`. This is the `design_model.zig:179-187` idiom, not a new convention.

`upsertSkill` follows `design_model.zig:126` `setDesignPage`: look up by the natural
key first; UPDATE if present, INSERT otherwise, return the id either way. That makes
`add_skill` idempotent on re-run without an `INSERT OR REPLACE`, which would clobber
`created_at`.

### 4.5 The three traps this plan must not walk into

**(a) Empty slice → SQL NULL.** `SqliteBackend.exec` binds `arg.len == 0` as
`sqlite3_bind_null`. `NOT NULL` then fails at runtime, not compile time. Every write
wraps: `content = COALESCE(?, '')`, `description = COALESCE(?, '')`,
`source_path = COALESCE(?, '')`. Precedents: `agent_knowledge_create.zig:134-145`,
`design_model.zig:179-187`, Migration 079's `content` column (which broke exactly
this way). **Own test:** round-trip `description = ""` and `source_path = ""` and
assert `""` back.

Worse, the asymmetry nobody writes down: `query` / `queryRow` do **not** have the
empty→NULL guard (`Sqlite.zig:586-591`, `:226-231`). So `""` is `NULL` in a
SELECT's `WHERE` args but `''` in an INSERT's `VALUES`. A `WHERE name = ?` with
`name == ""` will not match. Guard the empty-name path explicitly.

**(b) Route order.** `matchRoute` walks `self.routes.items` in **registration order**
and returns on first hit; `matchPathWithParams` requires exact segment-count
equality. Today `/api/skills` (2 segs) precedes `/api/skills/:name` (3 segs), which is
correct. **Any literal sub-route added under `/api/skills/` must be registered above
`main.zig:602`** or it is captured as `name="…"` by the `:name` route. In-repo
precedent for the correct order: `…/knowledge/reorder` before
`…/knowledge/:knowledge_id` (`main.zig:721-722`).

**(c) cwd canonicalisation.** If the importer and the lookup use different
`realpath` results for the same workspace, local skills become invisible — the exact
failure `tools_exec_skills.zig:21-24` warns about. One `canonicalCwd(io, path)`
helper, used by the importer, `use_skill`, `add_skill`/`edit_skill`/`remove_skill`,
and the HTTP query-param path.

### 4.6 Import & export — the mirror stays

- **Import at boot / first list.** `importFromDisk` walks the global root and
  `ctx.cwd`'s local root and `INSERT OR IGNORE`s each skill. It **never overwrites**
  an existing row, so agent edits are not reverted at the next start.
- **Export on write.** `add_skill` / `edit_skill` write the row **and** mirror to
  `<root>/<name>/SKILL.MD`; mirror failure is logged and ignored (log-and-continue,
  never fail the tool call). `remove_skill` deletes the row and best-effort
  `deleteTree`s the folder.
- **Consequence, stated honestly:** a skill committed to `.nalar/skills/` in a repo
  still appears on a fresh machine (no row → imported). But hand-editing `SKILL.MD`
  after the row exists does **not** change what the agent sees. Re-import is
  deliberate: `remove_skill`, then let the importer re-add it. *Rejected
  alternative:* "disk wins on every boot" makes agent edits vanish on restart.

The importer needs a hook. Preferred: call it once from the same place the DB is
opened and migrations run (`main.zig:220-226`), after `runMigrations()`. Fallback:
lazily on the first `list_skills` per process, guarded by a `bool`.

### 4.7 Tool contract changes

| Tool | Before | After |
|---|---|---|
| `list_skills` | `{cwd?}` → dir scan | `{cwd?}` → `listSkills(db, null, cwd)`; same `{global_skills, local_skills, cwd}` envelope, each entry now also carries `tags` |
| `use_skill` | `{path, is_global}` | **`{skill_name, is_global?}`** — `path` **deleted**; `is_global` becomes optional and defaults to local-first resolution |
| `add_skill` | `{name, description, content, is_global}` | `{name, description, content, is_global, tags?}`; writes a row (+ mirror) |
| `edit_skill` | `{skill_name, description?, content?, is_global}` | `{skill_name, description?, content?, tags?, is_global}`; row write, then mirror |
| `remove_skill` | `{skill_name, session_id, is_global}` | unchanged input; deletes the row, best-effort `deleteTree` |

**Decision (locked 2026-09-28): no compatibility shim for `path`.** Keeping it would
reintroduce a second source of truth, which is the entire thing this plan removes. An
in-flight model calling `use_skill({path})` gets a validation error that names
`skill_name` and self-heals in one turn. `UseSkillOutput`'s envelope
(`{skill_name, content, loaded, error, available_skills}`) is **unchanged**, so
`tools_exec_skills.zig:52-70` → `handle_tool.zig:808-813` → `session_skills` stays
byte-identical.

`use_skill` also gains the 100 KB cap the listing path already has (Decision 8 of the
old plan): an oversized row returns `loaded: false` with the byte count rather than
flooding the context.

### 4.8 HTTP contract changes

The three handlers keep their routes, methods, and top-level envelopes. **Decision
(locked 2026-09-28): the wire speaks `is_global: boolean`, not a `scope` string** —
`SkillDetail extends Skill` in `api/index.ts:2933-2936` keeps compiling untouched.
The DB column is `is_global` too, so there is no translation layer (§4.2).

Field-level changes:

- `GET /api/skills` → `{"global_skills":[{name,description,tags,path?}], "local_skills":[...], "cwd":?}`.
  `path` is populated from `source_path` and **may be `""`**; the TS type already has
  it optional.
- `GET /api/skills/:name` → `{skill:{name,description,tags,content,path,is_global}, error_message}`.
  `is_global` is read straight off the row. `path` comes from `source_path` and may be `""`.
- `DELETE /api/skills?name=…&is_global=…&cwd=…` → **signature unchanged**, which is
  exactly why decision 2 is load-bearing: the frontend's existing `is_global` query
  param keeps working with zero frontend change on this route. **One required
  behaviour change remains:** today the handler scans folders and matches by frontmatter
  name, and *none* of its two frontend callers pass `cwd`
  (`SkillDetail.vue:77-79`; `SkillsSettings.vue:64-68` and `AppLayout.vue:2867-2871`
  both render `<SkillDetail>` without `:cwd`). With a table keyed on
  `(is_global, cwd, name)`, a local delete with no `cwd` is **unresolvable**. Plan:
  keep returning `400 "cwd query parameter is required for local skill deletion"`
  when `is_global=false` and `cwd` is absent, and make `SkillDetail.vue` pass
  through the `cwd` it already receives as a prop (it has one, unused) — plus have
  `getSkills` callers pass the active session cwd. **This is a required frontend
  edit, not optional.**

`skill_delete.zig` also loses its 404-vs-500 asymmetry source: today "folder not
found" → 404 and `deleteTree` failure → 500. With a row store, "row not found" → 404
and the mirror `deleteTree` failure is logged, never surfaced.

### 4.9 Frontend changes

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts:2926-2985` | `Skill` gains `tags?: string`; `path` documented as "may be empty (provenance, not a filesystem handle)"; `SkillDetail` is **unchanged** (already has `is_global: boolean`); `deleteSkill` gains an optional `cwd` |
| `.../components/shell/SkillDetail.vue:77-79` | pass `cwd` through on delete; `:145-152` — the "Path:" block is `v-if`-guarded, so it degrades; relabel to "Source:" or keep |
| `.../components/tool_outputs/SkillList.vue:127-128`, `ListSkills.vue:134-135` | display-only `path`; already `v-if`-guarded; render `tags` as small chips under the description |
| `.../tool_outputs/_shared/toolOutputParser.ts:514-556` | `ParsedListSkills` / `SkillBlock` mark `path` nullable, add `tags` |
| `AddSkill/EditSkill/RemoveSkill.vue:64,68` | their `Path:` line comes from the **tool payload**, so it changes in lockstep with §4.7 |
| `.../components/shell/RightSidebar.vue`, `RightSideBarSkillList.vue`, `stores/sidebar.ts:112-148` | **delete** — unmounted dead code (see §3.7) |

**No OpenAPI/codegen artifact exists** — the api client is hand-written; there is no
`.yaml`/`.json` spec to regenerate.

**No `file://` / "open in editor" affordance for skills exists** (`rg` confirms zero
hits). `ToolCardHeader.vue` has one, but all three skill cards pass
`:show-open-in-editor="false"` and no `cwd` — keep that hardcoded, because
`props.primary` is a skill **name**, not a path, and re-enabling would pass
`filePath: 'my-skill'`.

## 5. Task breakdown

Ordered so every task is independently testable and reviewable.

### W0 — Landmine clearance (small, do first)

1. Fix `src/models/session_skill.zig` (re-add the missing `pub const SessionSkill = struct {`) or delete it. Rationale: W4 adds `src/models/skill.zig`; if anyone ever wires `models_test.zig` into a build target, both files break at once and the diagnosis is confusing.
2. Delete the dead `auto_save_skill` flag and its stale comment at `tools_exec_skills.zig:139-146`, and delete `parseSkillFromResult` (`handle_tool.zig:424-439`). Rationale: this plan rewrites the exec wrappers; leaving a lie in a file being edited invites a wrong "fix" later.
   - *Optional, separate:* make `add_skill`/`edit_skill` actually return `.skill_save` so the `session_skills` snapshot is not stale after an edit. This is a real bug but is **not** caused by the table move — flag it, don't silently absorb it.

### W1 — Migration 094 + model

- `Migration094CreateSkills` in `src/migrations/migration.zig` (struct anywhere in the file; register in `allMigrations` after the 093 entry at `:2006`). `main.zig` needs **no** change — every call site goes through `registerAllMigrations`.
- `test "Migration094 is registered in allMigrations"` — copy the guard shape at `migration.zig:6042-6048`.
- `src/models/skill.zig` — copy `src/models/agent_knowledge.zig` (72 lines: `EntityId`, fields, `InitArgs`, `init`, `deinit`, `clone`).

**Test:** in-memory `SqliteBackend.init(io, ":memory:")` + `Migration094…up(&db, alloc)`; assert the table exists, the partial unique indexes reject a duplicate global name and a duplicate `(cwd,name)`, and that the same name is legal in both `is_global` branches.

### W2 — `skills_db.zig` (the repository)

Full CRUD + `importFromDisk` per §4.4, with every free-text write wrapped in
`COALESCE(?, '')`. Reads: `db.query` → `defer rows.deinit()` → `defer row.deinit(alloc)`
→ `allocator.dupe` for anything that outlives the row. `is_global` is stringified
on bind and compared on read (§4.4).

**Also in W2:** extend `parseYamlFrontmatter` (`skills.zig:87-145`) to parse `tags`
per §4.3, and free the new field everywhere it is freed by hand. The importer reads
tags off disk, so the column is populated from day one rather than only by the tools.

**Tests (in-file, in-memory DB):**
1. Round-trip create → read → update → delete.
2. **`""` bind test** — write `description = ""`, `tags = ""`, `source_path = ""`; read back `""` (not NULL, not an error).
3. Empty-`name` guard returns a typed error instead of a NULL-comparison miss.
4. Local-first resolution when `is_global == null` and both a global and a local row exist; global-only when only the global row exists.
5. `importFromDisk` is `INSERT OR IGNORE`: seed a row, run the importer, assert the row is unchanged; then run with a new file, assert a row was added **with its frontmatter tags imported**.
6. `canonicalCwd` — two different spellings of the same path (trailing slash, `/tmp/../tmp/x`) address the same row.
7. **Tags round-trip both frontmatter forms** — `tags: [a, b]` and `tags: a, b` both normalise to `a||b`; a skill with no `tags:` line yields `""`, not a crash and not a phantom `[]`.
8. `is_global = true` forces `cwd = ''` on write even if the caller supplied one.

### W3 — Swap the five tools

- `skill_tools.zig`: `listAllSkills` reads the table (keep the `SkillsListData`
  envelope and the `listAllSkills` / `freeSkillsListData` / `toJson` names — the HTTP
  layer and the tests depend on them). `use_skill` takes `skill_name` + optional
  `is_global`, resolves via `skills_db.getSkill`, applies the 100 KB cap. `add_skill` /
  `edit_skill` / `remove_skill` write rows first, mirror to disk second — and
  `buildSkillContent` / `buildEditSkillContent` must emit the `tags:` frontmatter line
  so the mirror does not silently drop them.
- `tools_exec_skills.zig`: thread `ctx.db` into each call. `execUseSkill`'s
  `skill_save` return is unchanged.
- `tools_equipped.zig`: no registry change (same five names, same order).

**Tests:** every existing `skill_tools.zig` test that builds a `SKILL.MD` on disk must
be re-pointed at a seeded DB row — that is ~15 tests, and the diff is the honest
measure of the behaviour change. Add: `use_skill` with a `path` argument returns the
`skill_name`-naming validation error; oversized row → `loaded: false` + byte count;
`add_skill` with `tags: "a, b"` persists `a||b` **and** the mirrored `SKILL.MD`
contains a `tags:` line (the mirror round-trip is its own test — it is the one thing
that fails silently).

### W4 — Swap the three HTTP handlers

`skills_list.zig`, `skill_detail.zig`, `skill_delete.zig` each get a
`useCase(allocator, db, input)` in the `agent_knowledge_*` shape: closed error set,
`try nalarcore.getSingleton()` → `di.db` **in the handler only**, two exhaustive
`switch`es (status + message) so adding an error variant fails to compile.
Delete `findSkillByName` and `findSkillFolderByName` — their O(N)-scan bodies are
replaced by an indexed lookup.

**Tests:** in-memory unit tests per useCase, plus the functional tests below.

### W5 — Frontend

Per §4.9. Also **delete** the two dead sidebar components and the dead
`skillsGlobalExpanded`/`skillsLocalExpanded` store block — the skill viewer overlay
is currently reachable only by hand-editing `?view=skill&skill=<name>`, so there is no
live surface to preserve.

**Tests:** update `toolOutputParser.spec.ts:219-240, 356-371` (they assert `path`
round-trips) and `UseSkill.inprogress.spec.ts` (fixtures hard-code `SKILL.MD` paths in
the `parameters` blob). Add a spec for the delete-with-`cwd` query string, which is
currently **untested** — all three skills HTTP functions have zero frontend coverage.

### W6 — Functional tests (the real wire)

`tests/functional/skills_sqlite_test.py` on the `harness` fixture
(`port=None` → a random 20000-32000 port; **never 8081**). Cover:

1. `GET /api/skills` after `add_skill` → the row appears under `global_skills` with
   `path` populated from `source_path`.
2. `DELETE /api/skills?name=X&is_global=false` with **no** `cwd` → 400 with the
   documented message (the case the current frontend triggers).
3. `DELETE /api/skills?name=X&is_global=false&cwd=<abs>` → 200; second DELETE → 404.
4. `GET /api/skills/<literal>` — a new literal sub-route (if W4 adds one) must not be
   shadowed by `:name`.
5. An `add_skill` with an empty `description` persists as `""` and does not 500 —
   the empty-slice→NULL trap over the real wire, not a unit test. (`tags` is the
   *most* likely empty string, since most skills carry no tags line — cover both.)
6. `add_skill` with `tags: "a, b"` → `GET /api/skills` shows `a||b`; delete the row,
   confirm the importer re-adds it **with its tags** from the mirrored `SKILL.MD`.
   This is the end-to-end proof that the mirror writer emits a `tags:` line.

**Why the functional harness and not `nohup … --port 8080` + curl:** the three failure
modes above (route shadowing, empty-slice NULL collapsing mid-useCase, strict
validators treating `""` as a value) are invisible to unit tests. `harness.py` picks
a free port in 8080..8199 or a random 20000..32000, **excluding 8081** via
`RESERVED_PORTS`, and points `HOME` at an isolated tmpdir gated by `is_safe_tmp()`.

### Verification gates

```
zig build test --summary all
cd src/apps/desktop && pnpm test:unit
cd src/apps/desktop && bun run build          # delete stray .js next to .ts
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/skills_sqlite_test.py -v
```

Plus a cross-platform compile check for every touched Zig file. No
`// NEW (plan: …)` comments; comments explain *why*. Then open a PR for review.

## 6. Rollout / reversibility

The importer is `INSERT OR IGNORE`, so **a fresh DB is populated from disk on first
start** and a user with existing files loses nothing. A user who wants disk gone can
delete `~/.config/nalar/skills/<name>/` after confirming the row exists. The mirror
means `git status` in a repo that tracks `.nalar/skills/` keeps showing changes — that
is the intended trade (the old plan rejected "table-only, no mirror" for exactly this
reason: it silently breaks the git-tracked skill workflow).

## 7. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | `""` binds as NULL → `NOT NULL` violation at runtime | `COALESCE(?, '')` at every write; dedicated unit + functional test (§4.5(a)) |
| R2 | cwd canonicalisation drift makes local skills invisible | one `canonicalCwd` helper; test with 3 path spellings |
| R3 | A literal sub-route registered after `:name` is shadowed | register literals first; functional test |
| R4 | `path` disappears from the UI/tool payload | every render site is `v-if`-guarded; decide "Path:" vs "Source:" explicitly in W5 |
| R5 | `use_skill({path})` from an in-flight model | validation error names `skill_name`; self-heals in one turn |
| R6 | Frontend delete passes no `cwd` → local deletes break | 400 + explicit `cwd` plumbing in W5; functional test |
| R7 | `list_skills` output is both the REST body and the LLM payload, so field changes alter prompt bytes | change the envelope only in W3, where the tool contract already changes; note it in the PR |
| R8 | The `session_skills` snapshot path silently breaks if `UseSkillOutput` changes | envelope is explicitly frozen; `skill_save` return is untouched |
| R9 | Two duplicate `SkillInfo` types (`session_skills.zig:4` and `llm_history.zig:4249`) bridged by a copy loop at `on_event_sent.zig:305-317` | out of scope, but do not make it worse — if you touch either, touch both |
| R10 | Deleting the dead sidebar components could surprise a user who deep-links `?view=skill` | the overlay is already unreachable by navigation; note it in the PR description |

## 8. Decision log — all four resolved 2026-09-28

| # | Question | **Decided** | Consequence for this document |
|---|---|---|---|
| 1 | Does the filesystem mirror stay? | **Keep it** | §4.6 as written. The importer is `INSERT OR IGNORE` at boot; writes mirror to `<root>/<name>/SKILL.MD` best-effort. The trade-off is real and stated in §6: a repo that tracks `.nalar/skills/` keeps seeing changes, and hand-editing a `SKILL.MD` after the row exists no longer changes what the agent sees. |
| 2 | `is_global` on the wire, or `scope`? | **`is_global`** | The `scope` TEXT enum is **gone** (§4.2). The column is `is_global INTEGER`, the tool inputs are `is_global: bool`, the wire is `is_global: boolean`, and `SkillDetail` in `api/index.ts:2933-2936` compiles **untouched**. The `DELETE /api/skills?...&is_global=…` query string also needs no change. The only cost is that an integer bind has to be stringified — an existing repo idiom (§4.4). |
| 3 | Add a `tags` column now? | **Yes** | `tags TEXT NOT NULL DEFAULT ''` in the schema (§4.1), `'||'`-joined like `agent_memories.tags` (§4.3). `parseYamlFrontmatter` learns to parse both frontmatter forms; `add_skill`/`edit_skill` gain a `tags` input; the mirror writer gains a `tags:` line. The consumer is the LLM — the prompt already tells the agent to consult skills by tag, and `list_skills` output is the tool payload. |
| 4 | Compat shim for `use_skill({path})`? | **No** | `path` is deleted with no fallback (§4.7). An in-flight model gets a validation error naming `skill_name` and self-heals in one turn. A fallback would re-create the dual source of truth this plan exists to remove. |

**Net effect of decision 2 on blast radius:** the wire contract is *narrower* than
first drafted — no `Skill`/`SkillDetail` type change at all, only additive `tags?`
and the `deleteSkill(..., { cwd })` plumbing. The `path` field stays on the wire,
sourced from `source_path`; the frontend already treats it as optional and `v-if`-
guards every render site, so an empty value degrades silently rather than breaking.

**Residual risk after these decisions** — none of the three traps in §4.5 are
affected: empty-slice→NULL still applies (and now also to `tags`, which is the most
likely field to be written empty, since most skills have no tags line); route order
is unchanged; cwd canonicalisation is unchanged. The new surface introduced by
decision 3 is the hand-free at `skill_tools.zig:266-280`, which `std.testing.allocator`
will catch, and the mirror's `tags:` line, which fails silently — hence the dedicated
mirror round-trip test in W3.
