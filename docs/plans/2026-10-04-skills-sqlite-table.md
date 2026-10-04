# Skills move to one `skills` table, scoped per workspace

Status: in progress (Migration 101 + `skills_store.zig` landed, `zig build test` green).

Supersedes `docs/plans/2026-09-28-skills-sqlite-table.md`, which keyed the table
on `(is_global, cwd, name)`. That key is a direct encoding of the two
filesystem tiers, so it cannot survive their removal. This document keys on
`workspace_id` instead.

## The problem

A skill used to be a FILE. Its identity was a pathname, it lived in one of
two directories (`~/.config/pabrik/skills/` — "global" — or
`<cwd>/.pabrik/skills/` — "local"), and which one won was decided by walking
the filesystem. Three consequences:

- **Not workspace-scoped.** A skill could not belong to a workspace, so it
  could not be listed per workspace and could not be isolated per workspace.
- **Silent precedence.** `use_skill({ name })` preferred local over global.
  A model that got the wrong body got no signal that it happened.
- **Path-shaped contracts everywhere.** `search_skills` returned a `path`,
  `use_skill` took a `path`, and three prompt rules told the model the path
  "ends in `SKILL.MD`; pass it verbatim; never construct it from the name".

## The decision

One table. `workspace_id` on the row is the isolation boundary.

```sql
CREATE TABLE skills (
    id          TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    content     TEXT NOT NULL DEFAULT '',
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (workspace_id, name),
    FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
);
```

No `is_global`. No `cwd`. No `scope`. A skill wanted in two workspaces is
two rows — that is what "shared" means now, and it is one mechanism instead
of a flag and a table that can disagree.

### Why `skill_assets`

Two installed skills are BUNDLES, not single files:

| Skill | Files | What the body says |
|---|---|---|
| `pdf` | 11 | "run `scripts/convert_pdf_to_images.py`" |
| `skill-creator` | 17 | "run `scripts/run_eval.py`", "read `references/schemas.md`", "load `agents/grader.md`" |

A `content` column alone would leave the model pointing at files that do not
exist. So companions are rows too, stored at the same relative path the body
refers to:

```sql
CREATE TABLE skill_assets (
    id        TEXT PRIMARY KEY,
    skill_id  TEXT NOT NULL,
    rel_path  TEXT NOT NULL,
    content   TEXT NOT NULL DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (skill_id, rel_path),
    FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
);
```

`use_skill` materialises a bundle's assets into a temp directory and returns
that path, so the body's relative references resolve. A skill with no assets
returns `asset_dir: null` and there is no directory at all.

`asset_dir` is a materialisation, not a location of record: it is created
per load and may be reaped. The row is the truth.

### Why the HTTP routes move under the workspace

`GET /api/skills` has no source for a workspace id, and the store requires
one — an id the caller may not choose to omit. `/api/workspaces/:workspace_id/skills`
matches how `documents` already works (Migration 098) and puts the guard in
the URL, where it is visible.

## The contract every layer agrees on

This is the single source of truth for the wire shapes. If you are changing
one of these, change it here first.

### Agent tools

| Tool | Input | Output |
|---|---|---|
| `search_skills` | `{ query?, literal?, limit?, offset? }` | `{ query, pattern_mode, pattern_warning, count, total, offset, limit, skills: [{name, description}], truncated, next_offset, hint }` |
| `use_skill` | `{ name }` | `{ skill_name, content, loaded, asset_dir, asset_count, error?, available_skills? }` |
| `add_skill` | `{ name, description, content }` | `{ skill_name, name, created }` |
| `edit_skill` | `{ skill_name, description?, content? }` | `{ skill_name, name, updated, edited }` |
| `remove_skill` | `{ skill_name }` | `{ skill_name, removed }` |

Removed everywhere: `scope`, `cwd`, `is_global`, `path`, `create_with_dir`,
`session_id` (on `remove_skill`).

`search_skills` rows lose `scope` and `path`. The regex engine is unchanged
(`progressive_regex.zig`, a Pike VM over an RE2 subset) — this feature is
glue, not a new matcher.

### HTTP

| Route | Response |
|---|---|
| `GET /api/workspaces/:workspace_id/skills` | `{ "skills": [{ "name", "description" }] }` |
| `GET /api/workspaces/:workspace_id/skills/:skill_name` | `{ "skill": { "name", "description", "content", "asset_count" } \| null, "error_message": "" }` |
| `DELETE /api/workspaces/:workspace_id/skills/:skill_name` | `{ "success", "skill_name", "error_message": "" }` |

`is_global` is gone from the detail payload and `deleted_from` is gone from
the delete payload — both described a directory, and there is no directory.

### Route-order hazard

`matchRoute` walks routes in registration order and returns on the first hit.
The `:skill_name` routes must be registered AFTER any literal sibling under
the same prefix. There is no `/api/skills/evals` — that is why skill evals
live at the sibling prefix `/api/skill-evals/*`. Do not move them back.

## Workspace resolution at the tool layer

The model never supplies a workspace id. `ToolExecContext` carries `db` and
`session_id`; the tool resolves the scope itself:

```zig
const workspace_id = workspace_scope.resolveWorkspaceId(
    ctx.allocator, ctx.db, ctx.session_id,
) catch null;
```

`workspace_id` is deliberately absent from the tool schema so
`ignore_unknown_fields` parsing cannot smuggle a foreign id past the guard.
Copy `document.zig:348` (`resolveScope`) and its two distinct refusal
messages — "missing caller session" and "session is not linked to any
workspace" are different problems with different fixes.

## Migration of what is already on disk

39 skills are installed (22 global, 17 project-local). The importer reads
both directories and writes rows. It is **not** destructive: nothing is
deleted from disk, so a revert is a revert of this PR, not a restore.

Local skills go to the workspace whose `workspace_items.path` matches the
project; global skills go to every workspace that exists at import time, and
to a new workspace at provision time. A skill wanted in ten workspaces is
ten rows, and the importer is the one place that knows that.

## Traps

- **`""` binds as SQL NULL.** `SqliteBackend.exec` collapses a zero-length
  slice to NULL. Every write uses `COALESCE(NULLIF(?, ''), '')`, every read
  `COALESCE(col, '')`. A skill with an empty description is LEGAL — a model
  writes the body before the description — and must round-trip as `""`.
- **No `// NEW (plan: …)` comments.** The repo rule. Comments say *why*.
- **`zig build test` before you finish**, and expect the baseline of
  `4475/4485 tests passed (10 skipped)`. A failure in a file you do not own
  is another agent's, mid-flight — do not "fix" it.
- **Verify HTTP through `tests/functional/harness.py`**, which picks a free
  port in 8080-8199 and an isolated tmpdir `HOME`. Never `curl` a live
  server, and never port 8081.
- **`std.mem.trimRight` does not exist in Zig 0.16.** It is `std.mem.trimEnd`.
- **`std.Io.Dir.cwd().realPath()` always fails on Linux** — `AT_FDCWD` is
  -100, so it readlinks `/proc/self/fd/-100`. Use `helpers.getcwd(&buf)`.
- **`use_skill` must not resolve paths with `cwd().openFile`** on a path it
  did not create. The materialised `asset_dir` is absolute and known.
