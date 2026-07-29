# Vue 3 — `?? null` does NOT coalesce empty string to null

## Symptom

UI component receives a list of objects from the backend that should
all be "top-level" (no parent). The header counts them correctly, but
the body renders 0 rows. No errors, no warnings.

## Root cause

Backend SQL uses `COALESCE(col, '')` for a nullable column → wire format
is `""` (empty string), not `null`/`undefined`. The frontend tree
builder does `const pid = e.parent_id ?? null` — which leaves `""` as
`""` (empty string is NOT nullish), so the rows go into a separate
`""` bucket that the final `byParent.get(null) ?? []` returns as empty.

`??` only coerces `null` and `undefined`. Use `||` for "any falsy" or
explicit `e.parent_id === '' ? null : e.parent_id`.

## Concrete instance (2026-07-29)

`LayersPanel.vue:86` in `src/apps/desktop/src/components/design/`:
the layer-tree builder bucketed top-level elements by their parent_id.
Backend returned `""` for top-level rows (via `COALESCE(parent_id, '')`
in `src/ai_workflow/tui/design_model.zig:1207`). `e.parent_id ?? null`
kept the `""` intact, so the `byParent.get(null)` final lookup
returned `[]` → header said "Layers (2)" but rendered 0 rows.

## Fix

```ts
// Before (bug):
const pid = e.parent_id ?? null

// After (treats '' as nullish, matches SQL COALESCE semantics):
const pid = e.parent_id || null
```

## Why this is invisible to TypeScript / vue-tsc

`e.parent_id` is typed `string | null | undefined` (per
`src/apps/desktop/src/api/index.ts:229`). `?? null` is a perfectly
valid expression on that type — the type checker has no way to know
the runtime value will be `""`. The runtime mismatch (SQL's empty-
string-for-NULL convention vs JS's nullish) is what bites.

## Regression test pattern

Always cover BOTH wire shapes that the backend can return for a
nullable column. The existing tests only covered `null` (the TS-
declared type), missing the `""` (the SQL `COALESCE(col, '')`
wire form):

```ts
it('renders top-level rows when parent_id is the empty string (the wire form of SQL NULL from the backend)', () => {
  const elements = [
    makeElement({ id: 'elem_backdrop', parent_id: '' }),
    makeElement({ id: 'elem_card', parent_id: '' }),
  ]
  wrapper = mountPanel({ elements })
  const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
  expect(rows).toHaveLength(2)
})
```

## Detection recipe

```bash
# Find all uses of ?? on fields that come from the backend
rg -n '\?\? null' src/apps/desktop/src/

# Cross-reference with the SQL COALESCE patterns in design_model.zig
rg -n 'COALESCE\(' src/ai_workflow/tui/design_model.zig
# Every COALESCE(X, '') needs a frontend counterpart that treats "" as null.
```

## When this bites

Anywhere a frontend component buckets records by a "parent FK" field
that comes from a backend with the empty-string-for-NULL convention:

- design layers (this instance)
- comment threads (`parent_comment_id`)
- file system trees (`parent_dir_id`)
- reply chains

When in doubt, prefer explicit normalization at the API boundary so
the frontend never sees mixed `""` / `null` / `undefined`:

```ts
const parentId = e.parent_id === '' || e.parent_id == null
  ? null
  : e.parent_id
```

Or fix the backend to serialize NULL as `null` (matching the TS type),
not as `""`. The frontend `?? null` would then Just Work.

## Related

- `zig-sqlite-patterns.md` — explains the empty-slice-as-NULL convention
- `nalar-backend-architecture.md` — explains parseFromSliceLeaky / wire shapes
- Live data confirming this bug:
  `GET /api/workspaces/ws_.../items/item_.../design/pages/page_...`
  returned 2 elements with `"parent_id": ""` (NOT null).