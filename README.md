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

SQLite comes from the external `databases` package
([ruangsql](https://github.com/ginwa123/ruangsql), pinned by URL + hash
in `build.zig.zon`). On hosts with system SQLite (Homebrew `sqlite` on
macOS, vcpkg `sqlite3` on Windows) the package links it directly and no
extra step is required. Without system libs, populate the package's
vendored amalgamation first — the fetch script ships inside the package
(see `scripts/fetch-vendor-sqlite3.sh` in the ruangsql repo; it is
idempotent and verifies the SQLite 3.53.3 SHA3-256 checksum).

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
