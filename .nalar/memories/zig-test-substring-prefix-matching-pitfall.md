# nalar — Test substring matching: `id: ` pitfall with `_id:` disambiguation labels

When writing tests that grep for the ABSENCE of an ambiguous label
(`id: `, `id:`), the naive substring match (`indexOf(u8, s, "id: `X")`)
FAILS when the disambiguated label is `_id:` because `_id:` is a
substring-superset of `id:` — i.e. `indexOf(u8, "task_id: `foo`", "id: `foo`")`
returns the position of `id:` *inside* `task_id:`.

## Symptom

A regression test asserts:
```zig
try testing.expect(std.mem.indexOf(u8, md, "id: `task_") == null);
```
But the rendered markdown contains `task_id: \`task_a1\``. The
substring `"id: \`task_"` IS present (it appears inside `task_id: \`task_a1\``),
so the assertion fails even though the bare label was correctly removed.

## Why

`std.mem.indexOf` is a literal-byte substring search — it does NOT
understand word boundaries, prefixes, or the difference between
`id: ` and `_id:`. The longer disambiguated label is a strict
superset of the original short label at the byte level.

## Fix

Anchor the search with the actual markdown rendering prefix. In
the nalar Workspace Context, both item lines (`- **Name** (`) and
task lines (`  - task: \`name\` (`) begin with a `(`, so the
ambiguous label would only ever appear as `(id: \`` or ` (id: \``.
Search for those:

```zig
try testing.expect(std.mem.indexOf(u8, md, " (id: `") == null);
try testing.expect(std.mem.indexOf(u8, md, "(id: `") == null);
```

The two needles can't appear in either `item_id: ` or `task_id: `,
so the test correctly distinguishes "old label removed" from
"new label present".

## When this bites

- Any test that asserts "the old label X is gone" by searching for
  the bare label, when the new label is `prefix_X` and prefix
  contains X as a suffix (e.g., `_id` contains `id`).
- Any test using `indexOf`/`contains` for substring detection on
  compound identifiers without anchoring to a boundary character.
- The real example was the 2026-06-26 kanban-list-fix plan: the
  new label is `item_id:`/`task_id:` (replacing bare `id:`). The
  test that searched for `"id: \`task_"` matched the substring
  inside `task_id: \`task_a1\`` and failed.