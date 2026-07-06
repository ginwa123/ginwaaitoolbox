# design-fs-rewrite — file-based design page elements

> **Branch:** `feature/design-mode` · **Worktree:** `.worktrees/design-mode`
> **Status:** Plan locked (v5). Chunk 1 ready to implement.
> **Replaces:** inline `html` TEXT column on `design_pages` (pre-rewrite) with file-on-disk storage + a new `design_page_elements` table for positioned HTML snippets.

---

## Why this rewrite

The original `design_pages` table stored the page's HTML inline as a `TEXT` column. That worked, but it had two problems the user reported:

1. **Not editable in the user's editor.** The HTML is locked in the DB; you can't `vim .nalar/design/Login.html` to tweak the markup.
2. **Doesn't scale to multi-element designs.** A single "page" can contain many design elements (the user's screenshot shows 3 phone mockups + blue arrows on one canvas). The pre-rewrite model was 1 page = 1 html blob, so the LLM had to inline multiple `<div>`s in one HTML — no way to address a single element with a discrete CRUD API.

The rewrite moves storage to the file system, adds a new `design_page_elements` table for discrete positioned elements, and keeps the page as a metadata-only container. The DB tracks positions; the files are the source of truth for the HTML.

## Final data model (v5, locked)

```sql
-- Page = a container. No html, no file. Just position + dimensions.
CREATE TABLE design_pages (
  id TEXT PRIMARY KEY,
  workspace_item_id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',                       -- "Login", "Hi Chef", "Wireframe"
  width INTEGER NOT NULL DEFAULT 1440,                -- canvas width
  height INTEGER NOT NULL DEFAULT 1024,               -- canvas height
  x INTEGER NOT NULL DEFAULT 0,                       -- page's offset on the parent design canvas
  y INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL DEFAULT 0,                -- tab order
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);

-- Element = a positioned HTML snippet. The HTML is at <file_path>.
CREATE TABLE design_page_elements (
  id TEXT PRIMARY KEY,
  page_id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',                       -- "Hero card", "Footer", "Phone mockup"
  file_path TEXT NOT NULL DEFAULT '',                 -- e.g. '.nalar/design/Login/hero.html'
  x INTEGER NOT NULL DEFAULT 0,                        -- position on the page
  y INTEGER NOT NULL DEFAULT 0,
  width INTEGER NOT NULL DEFAULT 375,
  height INTEGER NOT NULL DEFAULT 667,
  z_index INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL DEFAULT 0,                -- iteration order
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE
);
```

**No `html` column on either table.** All html is at `file_path` (relative to `workspace_item.path`):
- Page file: `<workspace_item.path>/<page.file_path>` → e.g. `/home/ginwa/agentic_coding_zig/design/.nalar/design/Login.html`
- Element file: `<workspace_item.path>/<element.file_path>` → e.g. `/home/ginwa/agentic_coding_zig/design/.nalar/design/Login/hero.html`

The element file lives in a subdirectory matching the page name so a page with many elements is a tidy folder the user can browse. **This means pages have no file at all** — they're pure DB metadata + a folder.

## Key design decisions (locked)

| Question | Decision | Rationale |
|---|---|---|
| Where does page html live? | Nowhere — page is a metadata-only container | Plan v5. Matches Figma (a Figma page is just a container of frames). |
| Where does element html live? | On disk at `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html` | User can edit directly. Symmetric with the memory-file pattern (`.nalar/memories/<name>.md`). |
| Page x/y on the parent canvas | DB column on `design_pages` | Lets multiple pages sit side-by-side on the design item's canvas. |
| Element x/y on the page | DB column on `design_page_elements` | Each element is a Figma-style positioned frame. |
| Default page width/height | 1440×1024 | Desktop frame size, matches the user's "wireframe" use case. |
| Default element width/height | 375×667 | iPhone-ish, matches the user's mockup screenshots. |
| Filename sanitization | Lowercase, `/`→`_`, `\\`→`_`, leading `.` stripped, whitespace→`-`, reject empty | Prevents path traversal + keeps URLs clean. |
| Pan-zoom library | `panzoom` (npm) | Battle-tested, ~7kB, MIT. Don't reinvent. |
| LLM can edit files directly? | Yes — use `bash`/`write_file` tools | The DB is just position metadata; the file is the source of truth. |
| Drag-to-move in UI? | Yes, with a drag handle on the element header | Called `moveDesignElement` (low-latency x/y only). |
| Resize handles in UI? | Yes, corner resize | Called `resizeDesignElement`. |
| Page background? | First element called "Background" at z_index=-1 sets the page background | Self-contained; no page-level CSS column needed. |

## File system layout (one design item)

```
/home/ginwa/agentic_coding_zig/design/      ← workspace_item.path
├── (user's project files)
└── .nalar/
    └── design/
        ├── Login/                         ← page_name (sanitized) subdir
        │   ├── background.html            ← element #1, z_index=-1
        │   ├── hero-card.html             ← element #2, z_index=1
        │   ├── phone.html                 ← element #3, z_index=2
        │   ├── profile.html               ← element #4, z_index=3
        │   └── arrows.svg.html            ← element #5, z_index=0 (between background and cards)
        └── Hi Chef/                       ← another page
            ├── background.html
            └── ...

# DB rows (only metadata, no html):
design_pages:
  id=page_login, name="Login", width=1440, height=1024, x=0, y=0, position=0
  id=page_hichef, name="Hi Chef", width=1440, height=1024, x=1600, y=0, position=1

design_page_elements:
  id=el_1, page_id=page_login, name="Background", file_path=".nalar/design/Login/background.html", x=0, y=0, w=1440, h=1024, z_index=-1
  id=el_2, page_id=page_login, name="Hero card",   file_path=".nalar/design/Login/hero-card.html",  x=120, y=80, w=375, h=250, z_index=1
  ...
```

## Migration plan (no-migration as the user asked)

`Migration055AddDesignPages` → `Migration055AddDesignPagesAndElements`:

- **Fresh DB** (table doesn't exist): `CREATE TABLE design_pages (...)` with the new schema (no html, no file_path, has width/height/x/y) + `CREATE TABLE design_page_elements (...)`.
- **Existing DB** (upgrade path): `ALTER TABLE design_pages DROP COLUMN html;`, `DROP COLUMN file_path;`, `ADD COLUMN width INTEGER NOT NULL DEFAULT 1440;`, same for `height`/`x`/`y`. Then `CREATE TABLE IF NOT EXISTS design_page_elements (...)`.

**Per the user's "no need migrate" requirement:** existing users will have their inline html dropped. They get a clean slate. This is destructive but matches the user's explicit guidance.

## Implementation chunks (4 total)

### Chunk 1: Storage + model layer ✅ (in progress)
- `migration.zig`: rewrite Migration055
- `design_model.zig`: rewrite page CRUD (no html, no file), add element CRUD with file IO
- Add `sanitizeFilename` helper
- Add `getWorkspaceItemById` helper (or reuse existing)
- Update `design_model_test.zig` (use `std.testing.tmpDir()` for workspace_item.path)

### Chunk 2: HTTP handlers
- Update 5 `design_pages_*.zig` routes (remove html from bodies)
- **NEW** 5 `design_page_elements_*.zig` routes (list, create, get, update, delete)
- `moveDesignElement` route for incremental position updates
- `resizeDesignElement` route
- Test files for both

### Chunk 3: LLM tools
- Adjust `set_design_page_tool` (remove `html` param, add optional width/height/x/y)
- **NEW** `set_design_element_tool` (creates a positioned element)
- **NEW** `move_design_element_tool` (updates x/y only)
- **NEW** `list_design_elements_tool`
- **NEW** `delete_design_element_tool`
- Update `BuildDesignCanvasPrompt` to mention the new tool surface

### Chunk 4: Frontend
- Install `panzoom` npm
- `api/index.ts` — 6 new API functions
- `DesignView.vue`: render elements as positioned divs (not iframes) inside a single page canvas. Pan-zoom wrapper. Drag handlers.
- Tests

## LLM workflow (after all chunks)

```
# 1. Create the page (container, no html)
set_design_page(item_id="item_designnn", name="Login", width=1440, height=1024)
  → returns page_id, creates .nalar/design/Login/ subdir

# 2. Add the page background
set_design_element(page_id, name="Background", x=0, y=0, w=1440, h=1024, z_index=-1,
                    html="<div style='background:#D5E89A; width:100%; height:100%'></div>")
  → returns element_id, writes .nalar/design/Login/background.html

# 3. Add the hero card
set_design_element(page_id, name="Hero card", x=120, y=80, w=375, h=250, z_index=1,
                    html="<div class='hero'>Hi Chef</div>")
  → writes .nalar/design/Login/hero-card.html

# 4. Add the phone mockup
set_design_element(page_id, name="Phone mockup", x=600, y=200, w=375, h=667, z_index=2,
                    html="<div class='phone'>...</div>")
  → writes .nalar/design/Login/phone.html

# 5. Move the hero card (e.g. user dragged it)
move_design_element(element_id=hero_id, x=150, y=90)
  → updates x/y in DB, file untouched

# 6. List all elements on the page (for the next LLM call)
list_design_elements(page_id)
  → returns [{id, name, file_path, x, y, w, h, z_index}, ...]
```

The LLM can ALSO edit the files directly with `write_file` / `read_file` tools. The DB just tracks positions; the files are the source of truth for the html.

## User workflow (after all chunks)

1. Open the design item in nalar
2. Click `+ Add Page`, type "Login" → creates the `.nalar/design/Login/` subdir
3. Click "+ Add Element" on the canvas → mini-form (name, x, y, w, h, html) → element appears
4. Drag elements around → `moveDesignElement` called optimistically
5. Edit element html in any editor (e.g. `vim .nalar/design/Login/hero-card.html`) → save → click "Refresh" in nalar
6. Pan/zoom the canvas with mouse drag/wheel

## Open questions (resolved)

All 7 questions from v4 were resolved:
1. Page width/height: 1440×1024 ✓
2. Element width/height: 375×667 ✓
3. Drag-to-move: yes, with a drag handle ✓
4. Resize handles: yes, corner resize ✓
5. Filename: lowercase, sanitize, `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html` ✓
6. Page background: first element at z_index=-1 ✓
7. Multiple pages (tabs): keep the v1 tab strip ✓

## Verification (per chunk)

1. `zig build test --summary all` (≥ baseline 1006 + new tests, 0 regressions)
2. `zig build install:linux:system` (compiles cleanly; cp-fails-on-/usr/local/bin/nalar is expected)
3. `bun run build` (vue-tsc strict) — Chunks 3+ only
4. `bunx vitest run DesignView` (≥ baseline) — Chunk 4 only
5. Committed

## Key project memories to read before implementing

- `~/.config/nalar/memories/nalar-sql-alias-tables.md` — every SELECT aliases tables
- `~/.config/nalar/memories/nalar-bulk-callsite-update-misses-single-line-tail.md` — bulk edits need to handle comment-tail callsites
- `~/.config/nalar/memories/zig-migration-tests-three-pitfalls.md` — `db.exec` returns PrepareFailed (not QueryFailed) for missing tables; `row.deinit(allocator)` owns row.values
- `~/.config/nalar/memories/nalar-sqlite-backend-empty-slice-binds-as-null.md` — empty `[]const u8` binds as NULL; use 4-arg conditional SQL with CASE branches
- `~/.config/nalar/memories/zig-cross-platform-blockers-and-fixes.md` — never use `std.os.linux.*` (Mac CI); use `std.c.*` or `std.Io.*`
- `~/.config/nalar/memories/zig-0.16-stdfs-cwd-removed.md` — `std.fs.cwd()` is gone; use `std.Io.Dir.cwd()`
- `~/.config/nalar/memories/zig-0.16-file-append-must-use-writePositionalAll.md` — append requires `writePositionalAll`, not `writeStreamingAll`
- `~/.config/nalar/memories/custom-http-server-per-request-arena.md` — HTTP handlers use per-request arena; no manual `defer free` needed (but model functions DON'T use the arena — they return owned slices)
- `~/.config/nalar/memories/zig-0.16-syscall-helpers.md` — `std.Io.Threaded` non-blocking socket gotchas

## Why I rejected file_path on design_pages (final rationale)

I initially proposed keeping `file_path` on `design_pages` for "page shell HTML". The user correctly pointed out: if elements are file-based, pages should be too — or not at all. The plan v5 says pages have NO file (they're pure containers, like Figma pages). This:

- ✅ Eliminates the asymmetry ("why are pages on disk but elements inline?")
- ✅ Matches the user's mental model ("1 page can have many HTML")
- ✅ Simplifies the model (no page-level CSS to worry about)
- ✅ Lets the LLM manage elements as discrete units (the user's primary use case)
- ✅ Makes the LLM workflow natural: `set_design_page` creates a folder, then `set_design_element` files into it
- ✅ Page background is just another element ("Background" at z_index=-1) — self-contained

The downside (no page-level CSS) is minor: the LLM can use a "Background" element if it needs page-level state, or edit the file directly if it needs something exotic.

## Sign-off

User approved v5 on 2026-07-06 with "your recommendation is good". Implementation starts with Chunk 1.
