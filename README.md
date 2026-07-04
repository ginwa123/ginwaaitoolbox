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

## Running nalar as a service

`nalar` can run as a background process that persists across UI launches.
This means opening `nalar-desktop`, switching to a browser, or popping
another `nalar-desktop` window — all hit the same nalar instance.

### Quick start

```bash
# Start the service (writes ~/.local/state/nalar/state.json)
nalar service start

# Check it's up
nalar service status
# → status: running (pid 12345, http://127.0.0.1:8081/)

# Stop the service
nalar service stop
```

### nalar-desktop and the service

`nalar-desktop` is now a pure GUI shell — it does NOT manage the
service's lifetime. On launch, it probes `state.json` for a running
nalar; if none is found, the desktop surfaces an actionable error:

```
error: nalar is not running.
Run `nalar service start` in a terminal first, then re-open the desktop.
```

Closing the desktop window does NOT stop the service. Only
`nalar service stop` does.

### Smoke tests

```bash
./scripts/service-lifecycle-smoke.sh   # service start/status/stop cycle
./scripts/desktop-autospawn-smoke.sh   # desktop lifecycle wires to service
```

### Implementation notes

- **state_file**: `~/.local/state/nalar/state.json` (atomic writes via `<path>.tmp` + `rename(2)`).
- **daemonization**: POSIX double-fork + `setsid` (Linux daemon(7) idiom). Stdio redirected to `~/.local/share/nalar/service.log`.
- **signal handler**: SIGTERM with `SA_RESTART`. The handler invokes a callback passed by `serviceStart`; v1 uses a no-op (the server run-loop is a follow-up).
