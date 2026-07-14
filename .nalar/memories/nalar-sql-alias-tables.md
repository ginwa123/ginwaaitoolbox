# nalar — SQL Convention: Always Alias Tables in SELECTs

Per code-review feedback on PR #10
("feat: drag-and-drop reorder for workspace items"), the project
convention is to **always alias every table in every SELECT** — including
single-table queries that don't technically need an alias. Reviewer quote:

> "always use alias table when selecting data from db, make this as lesson"

## The convention (in this codebase)

1. **Every table in a SELECT gets a short single-letter alias.**
   The alias is the first letter of the table name (or two letters for
   multi-word names like `workspace_items` → `wi`).

   | Table                | Alias |
   |----------------------|-------|
   | `llm_history`        | `h`   |
   | `sessions`           | `s`   |
   | `workspace_item_tasks` | `t` |
   | `routines`           | `r`   |
   | `workspace_items`    | `wi`  |
   | `workspaces`         | `w` (use as needed) |

2. **No `AS` keyword.** SQLite supports both `FROM table alias` and
   `FROM table AS alias`; this codebase uses the former, matching
   the existing style in `llm_history.zig`.

   ```zig
   // Correct (this codebase's style)
   const sql = "SELECT wi.id FROM workspace_items wi WHERE wi.workspace_id = ?";

   // NOT this codebase's style (works in SQLite, but inconsistent)
   const sql = "SELECT wi.id FROM workspace_items AS wi WHERE wi.workspace_id = ?";
   ```

3. **All column references are qualified with the alias** (no bare
   `id`, always `wi.id`). This is the strongest enforcement of the
   convention: if someone copy-pastes a single-table query into a
   JOIN context, the `wi.id` reference forces them to think about
   which table the column comes from.

   ```zig
   // Correct
   const sql = "SELECT wi.id, wi.workspace_id, wi.position FROM workspace_items wi ORDER BY wi.position DESC";

   // Wrong — bare column names even though the table is aliased
   const sql = "SELECT id, workspace_id, position FROM workspace_items wi ORDER BY position DESC";
   ```

## Why this convention

1. **Forces intent in JOIN contexts.** A single-table query with an
   alias reads the same as the same query in a JOIN — the developer
   who copy-pastes it into a JOIN doesn't have to retrofit aliases.
2. **Catches bugs where someone adds a JOIN and forgets to qualify
   columns.** With bare `id` references, an added JOIN that brings
   in another `id` column creates an ambiguous reference; SQLite
   picks one and the bug is silent.
3. **Consistent with the existing JOIN queries** in `llm_history.zig`
   (which already use `h`, `s`, `t`, `r`).

## What about INSERTs / UPDATEs / DELETEs / migrations?

- **INSERT**: typically no alias needed (no FROM clause). The
  `workspace_items_create.zig` INSERT into `workspace_items` is fine
  without one.
- **UPDATE / DELETE**: this convention is about SELECTs. The
  `UPDATE workspace_items SET position = ? WHERE id = ? AND workspace_id = ?`
  in `workspace_items_reorder.zig` is fine as-is. (You *can* alias
  the UPDATE target with `UPDATE workspace_items AS wi ...` but it's
  not required by the reviewer feedback.)
- **Migrations**: the CREATE TABLE / ALTER TABLE / CREATE INDEX
  statements in `migration.zig` are DDL, not SELECTs — aliasing
  doesn't apply. The backfill UPDATEs with correlated subqueries
  (e.g. Migration 045) are also fine as-is.

## Static test pattern in this codebase

When a static regression test checks for the presence of an
SQL pattern (e.g. `workspace_items_reorder_test.zig` checks for
position-DESC ordering), write the check permissively to tolerate
the alias form:

```zig
// Wrong: too strict, breaks when the column is aliased
if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) { ... }

// Right: works with both "ORDER BY position DESC" and
// "ORDER BY wi.position DESC"
if (std.mem.indexOf(u8, source, "position DESC") == null) { ... }
```

## When this bites

- Adding any new SELECT in `llm_history.zig` (or other DB-touching
  files). The reviewer will reject it if it doesn't alias.
- Refactoring single-table queries to JOINs. If the original had
  bare columns, the JOIN introduces ambiguity.
- Updating the static regression tests. The "ORDER BY" check needs
  to drop the literal `position` prefix to allow alias-qualified
  column names.
