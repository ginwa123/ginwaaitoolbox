# nalar — `getDbPath.zig` used `createDirAbsolute` (no mkdir-p)

## Symptom

Booting `nalar` against a fresh, empty `$HOME` (a brand-new
install with `~/.config/nalar/` not yet existing) crashes with:

```
error: Failed to create config directory: /<home>/.config/nalar
error: FileNotFound
```

The smoke test (`scripts/ci-smoke-test.sh`) intentionally isolates
`$HOME` to an empty tempdir to exercise the fresh-install path, so
this bug was visible in CI from the first run after the smoke
test was added.

## Why

`src/helpers/db_path.zig` (pre-fix) called
`Io.Dir.createDirAbsolute(io, config_dir, .default_dir)` which in
Zig 0.16 maps to `posix.mkdirat(AT_FDCWD, absolute_path, mode)`.
That syscall only creates the **final** path component. With
`/$HOME/.config/nalar` and `/$HOME/.config` missing, the syscall
returns `ENOENT` and Zig surfaces it as `error.FileNotFound`.

Contrast with `Config.zig:writeDefaultConfig` (line 1154 in the
main codebase), which correctly uses
`std.Io.Dir.cwd().createDirPath(io, parent)` — the os-tagged
mkdir-p alias that walks components and creates each missing one
(returns Ok when the leaf already exists). `getDbPath.zig` and
`writeDefaultConfig` were using two different conventions for the
"create this nested dir" operation on the same `$HOME/.config/nalar`.

## Fix (commit `02764e0a` on `feature/criteria-smoke-test`)

Use the same `openDirAbsolute + createDirPath` pattern as
`writeDefaultConfig`:

```zig
var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch ...;
defer home_dir.close(io);
home_dir.createDirPath(io, ".config/nalar") catch ...;
```

Verified: smoke test passes against an empty tempdir `HOME`,
920/923 unit tests green (no regressions).

## How to avoid reintroducing

- **Prefer `Dir.createDirPath` over `Dir.createDirAbsolute` whenever
  the path might have missing parents**. Even when "obviously the
  parent exists", creating a fresh `$HOME` is a normal case
  (fresh install, fresh CI runner, isolated test sandbox).
- `createDirAbsolute` is only correct for OS-controlled paths where
  you've verified the parents exist (`/tmp/logs/`,
  `$XDG_RUNTIME_DIR/<pid>/`, etc.). For user-controlled paths, use
  mkdir-p.
- Add a CI fixture that boots `nalar` against an empty `$HOME`
  (the smoke test does this) before any HTTP/listener migration
  change ships.

## Related memories

- `nalar-fresh-db-migration-cascade.md` — same CI smoke test also
  surfaced 4 pre-existing migration bugs; this is the 5th.
- `nalar-macos-setsockopt-reuseaddr-bug.md` — macOS panic surfaced
  once Linux-side bugs were fixed.
- `nalar-website-init-schema-bug.md` — the same `createDir` on a
  nonexistent parent also fails for `nalar_website`'s initSchema.
