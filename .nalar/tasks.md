# Task ledger: Self-contained `databases` Zig package + platform-aware `zig build`

| # | Step | Status |
|---|---|---|
| 1 | Move existing database code into `src/modules/databases/src/` (git mv) | ✅ in progress |
| 2 | Replace placeholder `src/root.zig` with public API | ✅ in progress |
| 3 | Rewrite `src/modules/databases/build.zig` (boilerplate → package) | ⏳ |
| 4 | (No-op) `build.zig.zon::paths` already correct | ⏳ |
| 5 | Update root `build.zig.zon` to add `databases` dependency | ⏳ |
| 6 | Update root `build.zig` to consume package via `b.dependency()` | ⏳ |
| 7 | Strip redundant sqlite3 wiring from `linkPlatformDeps` (Linux block becomes thin) | ⏳ |
| 8 | Make `build_all_step` host-aware (`builtin.host.result.os.tag` switch) | ⏳ |
| 9 | Update `build_banner` to show host-specific binary name | ⏳ |
| 10 | Update `src/root.zig` + `src/modules/cronjob/Cronjob.zig` imports | ⏳ |
| 11 | Verify: `zig build test`, `zig build`, cross-compile smoke | ⏳ |
