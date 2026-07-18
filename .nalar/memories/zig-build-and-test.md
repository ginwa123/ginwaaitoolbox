# Zig — build, test, and lazy-analysis patterns

This file consolidates Zig build/test gotchas and the lazy-analysis pitfall. For Zig 0.16 stdlib changes, see `zig-0.16-stdlib-changes.md`. For SQLite-specific test patterns, see `zig-sqlite-patterns.md`.

---

## `zig build` catches lazy-analysis errors `zig build test` misses

`zig build test` and `zig build install:linux:system` (or any `addExecutable` step) compile **separate module graphs** rooted at different files. The test target's graph is rooted at the test runner and may not reach production code paths via lazy analysis. The install target's graph is rooted at `main.zig` and DOES reach them.

**Symptom:** You fix a handler bug, `zig build test` is green (1008/1011), commit, push, and CI / user reports a cryptic type error. The error was always there; the test target's lazy analysis never reached the offending line.

**The fix pattern — always run all three:**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin                                  # MANDATORY
timeout 360 zig build                                # fresh build step
```

The fourth one catches what the first two miss. Per the project memory `verification-before-completion`, claim success only after all four pass.

**Why the four are not equivalent:**

| Check | Module graph | Reaches private helpers? | Catches `addExecutable`-only errors? |
|---|---|---|---|
| `zig build test` | Rooted at test runner | Lazy — only public API used by tests | **No** |
| `zig build install:linux:system` | Rooted at `main.zig` → `nalarcore` | Yes, BUT cp-to-`/usr/local/bin/nalar` fails harmlessly with permission, **masking** the build result | Partial |
| `zig build` (no `rm`) | Rooted at `main.zig` → `nalarcore` + nalar-desktop | Yes, BUT output is cached — stale `zig-out/bin/nalar` from prior partial build reported as "success" | Partially |
| `rm -rf zig-out/bin && zig build` | Fresh rebuild from scratch | Yes, AND every step re-runs | **Yes** |

**Cache caveat:** When a prior `zig build` left partial state (e.g., successful `compile exe nalarcore` but failed `install nalar` step — exactly what happens with lazy-analysis bugs), subsequent `zig build` runs may see the `nalar` binary as "up to date" and skip the compile. **The fix is always `rm -rf zig-out/bin`** before the verification run.

**When this bites:**
- Any new HTTP handler (test file imports only public parse helper; apply block invisible to test target).
- Any new private helper called from a tested function with `catch` arms that change the inferred error set (see `zig-language-quirks.md`).
- Any new code path guarded by `if (cond) { production_code() }` that the test target never exercises.
- Any new `std.json.parseFromSliceLeaky` + apply block — parser test is decoupled from apply test.
- Any cross-platform code change where the test target runs on a single platform and the `addExecutable` target crosses to a different one.

**Related manifests of the same root cause:**
- `zig-0.16-t-to-t-param-becomes-const.md` (T → !T const constraint)
- `zig-0.16-spawn-cwd-is-not-nullable.md` (spawn in private helper)
- `zig-migration-tests-three-pitfalls.md` (lazy analysis + SQL migrations)
- `zig-catch-narrows-error-set-before-switch.md` (error set hidden until lib_tests references it)

---

## `failed command:` in zig build output is misleading, not a failure

Zig's build runner prints `failed command: <path>` after a step's stderr output in verbose error style (default for `zig build test`), even when the step succeeded. The label is misleading — it's a debug aid, not a failure indicator.

**Symptom:**

```
[default] (warn): Config file not found at explicit path /home/.../nope.json
[default] (warn): Failed to parse JSON config: SyntaxError
failed command: ./.zig-cache/o/abc123/test --cache-dir=./.zig-cache ...

Build Summary: 5/5 steps succeeded; 1273/1276 tests passed (3 skipped)
test success
+- run test 1273 pass, 3 skip (1276 total)
```

The red "failed command:" above the green summary confuses developers into thinking something failed. It did NOT.

**Why:** In `build_runner.zig`, `printErrorMessages` prints `failed command:` when `verboseContext()` is true (the default) AND `result_failed_command` is set. The variable is set **unconditionally before every spawn** in `Run.zig:1541` — it's used as "show the command that produced this stderr", not as a failure flag.

**Fix — accept the noise or switch style:**

**Option A** — accept the noise. The build summary line is ground truth:
- `Build Summary: 5/5 steps succeeded` = all OK
- Look at `N passed; M skipped` — `total - pass - skip = fail count`

**Option B** — switch to minimal error style:

```bash
export ZIG_BUILD_ERROR_STYLE=minimal
zig build test --summary all
```

Output (no "failed command:" line, only the summary):

```
Build Summary: 5/5 steps succeeded; 1273/1276 tests passed (3 skipped)
test success
+- run test 1273 pass, 3 skip (1276 total)
```

Set this in `~/.bashrc` / `~/.zshrc` for clean CI/dev logs.

**If `failed command:` appears AND the summary shows `(N failed)` or `test failure`** → there IS a real failure.

---

## `testing.TmpDir.sub_path` is a fixed-size array, NOT a slice (Zig 0.16)

In Zig 0.16, `testing.TmpDir.sub_path` is `[sub_path_len]u8` (a fixed-size array holding just the random base64-encoded basename like `"AbCdEfGh1234"`), NOT `[]u8` (a slice to the full path).

**Symptom:** A test does `&tmpdir.sub_path` for a function expecting `[]const u8`. Compiles fine (coercion), but at runtime the basename is passed instead of the real path:

```zig
var tmpdir = testing.tmpDir(.{});
defer tmpdir.cleanup();
try tmpdir.dir.writeFile(io, .{ .sub_path = "marker.txt", .data = "..." });
var result = try search.executeSearch(allocator, io, "/tmp", .{
    .pattern = "--help",
    .path = &tmpdir.sub_path,    // ← BUG: only "AbCdEfGh1234", not real path
});
```

`&tmpdir.sub_path` coerces to `[]const u8` (compiles), but at runtime ripgrep receives `"AbCdEfGh1234"` — a relative basename. Combined with hardcoded `"/tmp"` as cwd, ripgrep looks in `/tmp/AbCdEfGh1234/` which doesn't exist (real tmpdir is `<project>/.zig-cache/tmp/AbCdEfGh1234/`). Result: `error.PathError`.

**The tmpdir is created in `Io.Dir.cwd()` (NOT `/tmp`):**

```zig
// /usr/local/lib/zig/std/testing.zig:641-647
const cwd = Io.Dir.cwd();
var cache_dir = cwd.createDirPathOpen(io, ".zig-cache", .{}) catch ...;
defer cache_dir.close(io);
const parent_dir = cache_dir.createDirPathOpen(io, "tmp", .{}) catch ...;
const dir = parent_dir.createDirPathOpen(io, &sub_path, .{...}) catch ...;
```

So full path is `<test_cwd>/.zig-cache/tmp/<random_sub_path>/`.

**Fix — use `tmpdir.dir.realPath(io, &buf)`:**

```zig
var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
const path_len = try tmpdir.dir.realPath(io, &path_buf);
const tmpdir_path: []const u8 = path_buf[0..path_len];

var result = try search.executeSearch(allocator, io, tmpdir_path, .{
    .pattern = "--help",
    .path = ".",
});
```

`max_path_bytes` is `4096`. `realPath` writes the resolved path and returns the byte count.

**Alternative — use parent dir + basename:**

```zig
var parent_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
const parent_len = try tmpdir.parent_dir.realPath(io, &parent_buf);
const parent_path: []const u8 = parent_buf[0..parent_len];

var result = try search.executeSearch(allocator, io, parent_path, .{
    .pattern = "--help",
    .path = &tmpdir.sub_path,   // basename now resolves correctly
});
```

**When this bites:** any new test that does `testing.tmpDir` + passes a path to a function; porting tests from older Zig (0.13/0.14/0.15); behavioral tests using real executables (rg, sqlite3, etc.).

---

## Migration tests: three pitfalls

**Pitfall 1 — Single-line `\\` raw string has no terminating `;`:**

```zig
// ❌ Parse error: expected ';' after statement
const expected_cols =
    \\SELECT name FROM pragma_table_info('notifications') ORDER BY cid;
```

The `\\…` raw string ends at the newline, and the SQL's `;` is INSIDE the string, so the const declaration has no terminator.

**Fix — put `;` on its own line:**

```zig
const expected_cols =
    \\SELECT name FROM pragma_table_info('notifications') ORDER BY cid
;
```

**Pitfall 2 — `row.values[i]` is freed by `row.deinit`; storing raw slice headers = use-after-free:**

`SqliteBackend.next()` allocates `row.values[i]` from the passed allocator. `row.deinit(allocator)` frees them. Storing the slice header and using it after `deinit` is use-after-free.

**Symptom:** Segfault in `findDiff` inside `std.testing.expectEqualStrings`, far from the misuse site.

**Fix — dupe before the row.deinit fires:**

```zig
var owned: [N][]u8 = .{ &.{}, ... };
defer for (owned) |s| if (s.len > 0) alloc.free(s);
while (try q.next()) |row| {
    defer row.deinit(alloc);
    owned[idx] = try alloc.dupe(u8, row.values[0]);
    idx += 1;
}
```

**Pitfall 3 — `db.exec` returns `error.PrepareFailed`, NOT `error.QueryFailed`, for missing tables:**

```zig
// ❌ Wrong — spec-style guess
const rc = db.exec(alloc, "SELECT 1 FROM notifications LIMIT 1", &.{});
try testing.expectError(error.QueryFailed, rc);

// ✅ Correct
const rc = db.exec(alloc, "SELECT 1 FROM notifications LIMIT 1", &.{});
try testing.expectError(error.PrepareFailed, rc);
```

`db.exec` calls `sqlite3_prepare_v2` first; if the table doesn't exist, prepare fails. `QueryFailed` would only fire if prepare succeeded but step (execute) failed.

**When these bite:** any new `migration_xxx_test.zig` file in `src/ai_workflow/tui/`; any test that walks a `db.query()` cursor and stores column values for later assertion; any test that exercises `db.exec()` against a missing table or index.

**Verify by running the test binary directly (not just `zig build test`):**

```bash
TEST_BIN=$(ls -t .zig-cache/o/*/test | head -n 1)
timeout 60 "$TEST_BIN" 2>&1 | rg -i MigrationXXX
```

---

## `testing.expectError` takes a value, NOT a type

```zig
expectError(error.MandatoryTimeoutMissing, result)  // ✅ works
expectError(bash.MandatoryTimeoutMissing, result)   // ❌ compile error
```

Even when `bash.MandatoryTimeoutMissing` is declared as `error{MandatoryTimeoutMissing}` (a type), pass the literal `error.X` value.

**When this bites:** writing tests for functions whose error sets are inferred unions; `expectError` with declared error sets.

---

## Related / cross-references

- `zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib changes
- `zig-language-quirks.md` — language-level gotchas
- `zig-sqlite-patterns.md` — SQLite patterns
- `zig-cross-platform.md` — cross-platform porting