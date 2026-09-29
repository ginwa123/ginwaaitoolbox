# present_files ↔ /api/files/download sandbox parity (TDD)

Kanban: `windows error, path i htink` (task_1790663658876_0)

## Symptom

On Windows the `present_files` card renders, but every byte fetch fails:

```
GET /api/files/download?session_id=task_1790651028442_2
    &path=C%3A\Users\gilang.trisety\Downloads\IRON-11463 ...html
→ 403 {"error":"Path escapes the session working directory"}
```

The card shows "Preview failed to load (HTTP 403) — open in a new tab to view",
and "Open in new tab" opens the same JSON error.

## Root cause (verified, not a path-parsing bug)

The URL decodes fine: `C%3A` → `C:`, and `std.fs.path.isAbsoluteWindows` accepts
`C:\Users\...` (`.drive_absolute`), so the handler gets past both the
`isAbsolute` and the `..` guards — which is why the failure is the *containment*
403 and not a 400/404.

`src/http_handlers/files_download.zig` only serves paths that canonicalize
inside the session's working directory (`git_worktree_cwd` ?? `cwd`):

```zig
if (!isInsideRoot(root_canon, canon)) → 403 "Path escapes the session working directory"
```

`src/modules/agent/tools/present_files.zig` has **no such check** — it only
requires the path to be absolute and stat-able. So the agent can (and did)
present `C:\Users\<user>\Downloads\report.html`, the tool returned
`{"status":"presented",...}`, the card rendered, and every fetch 403'd.

**The two sides of one contract disagree.** The tool must never emit a card
whose bytes the endpoint refuses to serve — that is the class of bug, and it is
OS-independent (the user hit it on Windows, but the same `Downloads` file on
Linux 403s identically).

Not the cause (checked, so nobody re-checks them):
- `path` percent-encoding / `+` vs `%20` — covered by an existing wire test.
- `\\?\` verbatim prefix asymmetry — both root and target go through
  `realPathFileAbsoluteAlloc`, so the prefix is present on both sides.
- Drive-letter / backslash parsing — `isAbsoluteWindows` handles it.

## Fix

One shared sandbox module, two callers, one rule.

1. **New `src/modules/agent/tools/file_sandbox.zig`** — the single source of
   truth for "may this file be shown to the browser":
   - `PathStyle { posix, windows }` + `nativeStyle()`. Style is an explicit
     parameter (not `builtin.os.tag` inside the function) so the Windows branch
     is **unit-testable from Linux CI** — a `builtin.os.tag` guard would make
     the Windows half dead code that is never analysed.
   - `isInsideRoot(root, resolved, style)` — strips the `\\?\` (and
     `\\?\UNC\`) verbatim prefix, compares case-insensitively on Windows,
     accepts `/` and `\` as the boundary, and keeps the trailing-separator
     check so `/tmp/abc` never prefix-matches `/tmp/abcd/…`.
   - `isAbsoluteFor(path, style)`, `hasParentSegment(path)`.
   - `resolveInsideRoot(io, allocator, root, path, style)` — canonicalizes
     both sides and returns the canonical target or a typed error.
   - `resolveSessionRoot(allocator, db, session_id)` — moved here from the
     handler, so the tool resolves the *same* root the endpoint will.
2. **`files_download.zig`** delegates to the shared module (its own
   `isInsideRoot`/`resolveSessionRoot` copies are deleted) and keeps only the
   HTTP status mapping.
3. **`present_files.zig`** takes a `sandbox_root: ?[]const u8` and rejects any
   file that does not canonicalize inside it, with an **actionable** message
   that names both paths and tells the model to copy the file into the working
   directory first. `null` keeps the legacy un-sandboxed behavior for callers
   that have no session (TUI/routines).
4. **`tools_exec_present_files.zig`** resolves the root through
   `file_sandbox.resolveSessionRoot(ctx.db, ctx.session_id)` → parity by
   construction; fails closed when the session row has no working directory.
5. Tool `description` + `system_prompt` state the rule, so the model does not
   have to learn it from a failed call.

## Tests (written before the implementation — RED first)

- `file_sandbox.zig` (~20): posix + windows style for `isInsideRoot`,
  verbatim/UNC prefix, drive-letter case, sibling-prefix rejection,
  `hasParentSegment` with both separators, `isAbsoluteFor` per style
  (including drive-relative `C:x` and rooted `\x`), and `resolveInsideRoot`
  against real temp dirs (inside / outside / missing / relative / symlink-out).
- `present_files.zig` (~20): the Downloads case (absolute, exists, OUTSIDE the
  root → `status:null` + a message naming the root), nested-inside accepted,
  root-equals-dir accepted, `..` rejected even when it lands back inside,
  symlink-out rejected (skipped on Windows), all-or-nothing across a mixed
  batch, check ordering (empty/count/absolute before the sandbox), the
  un-sandboxed `null` root still behaving as before, plus the existing
  envelope/mime/label/cap coverage.
- Contract: `files_download.zig` imports the shared module and defines no
  private `isInsideRoot` (static source check, same style as the existing
  `TOOL_PATH` greps); `MAX_FILE_BYTES` stays in sync.
- Wire (`tests/functional/agent_present_files_test.py`): a real sibling dir
  whose name shares the root's prefix → 403 (the fake-string unit test cannot
  prove the real-path branch), an out-of-root file in a real dir → 403 with the
  message, an in-root nested file → 200.

## Out of scope (called out, not done)

- Widening the endpoint to serve any OS-readable path. It would "fix" the
  click, but the containment is the thing that stops a confused model (or a
  cross-origin `<script src=…>`) from turning the browser into an arbitrary
  file reader. Needs a human decision, not a side effect of this bug.
- `PresentFileRef.caption` is in the tool schema but emitted nowhere and
  rendered nowhere (no `caption` in `PresentFiles.vue`). Dead field, separate
  cleanup.
- The card shows a bare "HTTP 403" instead of the endpoint's reason text.
