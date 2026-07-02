# ginwaaitoolbox

[![CI](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml)

## Building

### Linux (native)

```bash
sudo apt-get install -y build-essential libssl-dev libsqlite3-dev pkg-config
zig build test          # run all unit tests
zig build install:linux:system   # produce zig-out/bin/nalar
```

Linux uses the system `libsqlite3` via `linkSystemLibrary("sqlite3")`, so
no extra fetch step is required.

### Windows / macOS (native or cross-compile from Linux)

`build.zig` compiles SQLite from the `vendor/sqlite3/` amalgamation on
non-Linux targets. That directory is **gitignored** (`.gitignore: /vendor/`)
to keep the repo small; fetch it on demand before the first `zig build`:

```bash
./scripts/fetch-vendor-sqlite3.sh
zig build test
```

The script downloads SQLite 3.53.3 (the version `build.zig` was last
verified against) from `https://sqlite.org/`, verifies its SHA3-256
checksum, and extracts the three files (`sqlite3.c`, `sqlite3.h`,
`sqlite3ext.h`) into `vendor/sqlite3/`. It is idempotent — re-runs skip
if all three files are present. CI on Windows/macOS matrix cells runs
the same step automatically (see `.github/workflows/ci.yml`).

## See also

- [docs/ci.md](docs/ci.md) — CI pipeline layout, troubleshooting, common failures
