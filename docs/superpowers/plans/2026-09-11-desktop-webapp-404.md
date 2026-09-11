# Desktop app opens a blank "404 Not Found" window on later launches

**Task:** `task_1789144501374_7` — "first time open desktop app work but, after
a while use and close and open again its 404"
**Branch:** `worktree/desktop-webapp-404`
**Date:** 2026-09-11

## Symptom

The desktop app works on first launch. After using it and closing the window,
reopening it shows a blank white page with a bare `404 Not Found` in the
top-left corner (screenshot in the task).

## Root cause

Three individually-reasonable decisions compose into the bug:

1. `desktop_app/main.zig` materialised the embedded webapp into a **per-pid
   temp dir** (`$XDG_RUNTIME_DIR/nalar-desktop-webapp-<pid>`) via
   `extraction.extract`.
2. It spawned `nalar --port 8081 --static-dir <that dir>` and never signalled
   that daemon on close (deliberate: the desktop is decoupled from the
   daemon's lifecycle — only `nalar service stop` ends it).
3. `main.zig` had a `defer` that called `extraction.cleanup`, i.e.
   **`rm -rf` on the dir the still-running daemon is serving**.

Reproduced live on this machine before the fix:

```
$ ps -eo pid,ppid,etime,cmd | grep nalar
3233139  1  02:36:25  /usr/local/bin/nalar --port 8081 \
                      --static-dir /run/user/1000/nalar-desktop-webapp-3232886
$ ls -ld /run/user/1000/nalar-desktop-webapp-3232886
ls: cannot access '...': No such file or directory      # deleted at window close

$ curl -i http://127.0.0.1:8081/
HTTP/1.1 404 Not Found
Not Found
$ curl -i http://127.0.0.1:8081/health
HTTP/1.1 200 OK                                          # ← why attach "succeeds"
```

Why the second launch 404s and the first does not:

- Launch 1 has no daemon to find, so it spawns one with a *live* static dir.
- On close, the dir is deleted; the daemon keeps running, orphaned (PPID 1).
- Launch 2 reads no/stale state.json, falls back to probing `127.0.0.1:8081`
  with `GET /health` → **200** → attaches with `we_spawned=false`.
- `/health` is an API route and says nothing about the static dir. The webview
  loads `/` → `static_files.resolve` → `openDirAbsolute(root_dir)` →
  `FileNotFound` → `.not_found` (`static_files.zig:230`) →
  `main.zig:1025` writes `404 Not Found`.

Aggravating factor: the temp base is `$XDG_RUNTIME_DIR`, which systemd wipes
on logout — so even an unclean exit (no cleanup defer) resurrects the 404 at
the next login.

## Fix

### A. Persistent, content-addressed webapp dir (`extraction.ensurePersistent`)

- `~/.local/share/nalar/desktop-webapp/<hash>` (Linux, via `$XDG_DATA_HOME`),
  `~/Library/Application Support/nalar/desktop-webapp/<hash>` (macOS),
  `%LOCALAPPDATA%\nalar\desktop-webapp\<hash>` (Windows fallback path).
- `<hash>` = Blake3 over the embedded asset set (path + mime + bytes) so an
  unchanged build reuses the same dir (no multi-MiB rewrite per launch, and
  crucially the path handed to an already-running daemon stays valid) while a
  changed build lands in a fresh dir (never mix old and new assets).
- Crash-safe publish: write to `<hash>.tmp-<pid>`, write
  `.nalar-webapp-complete` **last**, then rename into place. A concurrent
  publisher loses the rename and keeps the winner's byte-identical dir.
- **Never deleted.** `main.zig` now frees the path but never removes the dir.
- Windows keeps its `%LOCALAPPDATA%\nalar\html` installed-dir precedence.

### B. Attach only to a server that actually serves the app

- `subprocess.httpGet(port, path)` — one raw-socket `GET` returning
  `{status, body_looks_html}`; `probeHealth` and `probeWebapp` are thin
  wrappers over it (the old health-only `tryProbe*` are gone).
- `attach.isUsableWebappServer` requires **`/health` 2xx AND `/` 2xx with an
  HTML body** before any attach. A merely-healthy server is logged as ignored.
- If nothing usable is found, `autoSpawnAndWaitForHealth` spawns a desktop-owned
  daemon on `default_port` **only when it is free**, else on an ephemeral port
  (`port.isFree` / `port.findFree`). Spawning into an occupied port used to
  "succeed" against the squatter's `/health`, so this closes that hole too.
- After the spawn, the child is re-verified with `probeWebapp`; on failure it is
  terminated and `AutoSpawnFailed` is returned instead of opening a 404 window.
- **Never kills an existing daemon** (the dev server on 8081 is untouched).

### C. Drive-by: `nalar service start|restart` dropped `--static-dir`

`main.zig` never forwarded `s.static_dir` into `serviceStart` (so
`state.json.static_dir` was always `null`), and `parseServiceSubcommand`'s
`restart` branch rejected `--static-dir` with `UnknownSubcommand` even though
the usage text advertised it. Both fixed.

### D. Drive-by: `test:desktop-app` was unrunnable from a clean tree

`desktop_tests` compiles `desktop_exe.root_module`, whose `main.zig` imports the
gitignored `embedded/webapp_assets.zig` — but unlike `desktop_exe`, the test
compile had no edge to the codegen chain that produces it, so a fresh checkout
died with `unable to load 'webapp_assets.zig': FileNotFound`. Added the same
`if (!no_webapp_rebuild) desktop_tests.step.dependOn(&webapp_rebuild_codegen.step)`
edge `desktop_exe` already has.

## Tests

| Layer | File | What it locks in |
|---|---|---|
| Zig unit | `src/apps/desktop_app/extraction_test.zig` (+4) | dir is stable across calls, reused (sentinel survives), invalidated on asset change, republished after a torn write, zero-asset build still reusable |
| Zig unit | `src/apps/desktop_app/attach_test.zig` (rewritten, 6) | path-aware mock server; `/health` 200 + `/` 404 is **never** attached to; a working daemon in a state file is; the 404 daemon is skipped and a real spawn happens on a **different** port, verified servable, with the squatter left alive |
| Zig unit | `src/service/main_service_test.zig` (+2) | `start`/`restart` keep `--static-dir` |
| Python functional | `tests/functional/desktop_webapp_404_test.py` (3) | real binary: `--static-dir` serves; deleting it behind nalar's back ⇒ `GET /` 404 **while `/health` stays 200**; restoring it serves again; a persistent dir survives a restart; no-static-dir has the same 200/404 shape |

Zig's test runner fails a run when `std.log.err` fires, so the auto-spawn test
uses a working fake `nalar` (a small executable python script that binds the
`--port` it is given, serves 200 + HTML, and exits on its own after 5 s) rather
than deliberately failing the spawn — no stray error logs, no leaked process.

## Verification

- `zig build test:desktop-app -Dno-webapp-rebuild --summary all` → **46/46 pass, 0 error logs**
- `zig build test install:linux nalar-desktop -Dno-webapp-rebuild --summary all`
  → 17/17 steps, **3388/3396 pass (8 skip, 0 fail)**, both binaries link
- `pytest tests/functional/desktop_webapp_404_test.py` → **3/3 pass**
- Real-binary end-to-end (isolated `HOME`, port 18099 — never 8081):
  `--smoke-test` materialises `~/.local/share/nalar/desktop-webapp/<hash>/`
  with `index.html` + `assets/` + `.nalar-webapp-complete`;
  then with the real `nalarcore-linux-x86_64`:
  `GET /` → 200, `/index.html` → 200, `/health` → 200;
  after moving the dir away: `GET /` → **404 (Not Found)** and `/health` → 200
  (the reported bug, reproduced); after restoring it: `GET /` → 200.

## Scope / non-goals

- `--smoke-test` keeps its old pass/fail semantics on purpose: a hard 404 guard
  there re-breaks the Windows `-Dno-webapp-rebuild` empty-stub CI cell (see
  reverted commit `e164f98e`). The wire-level guard lives in the functional test.
- Not touched: `findInstalledWebapp`'s Windows precedence, the SPA fallback,
  and the choice to leave an unusable daemon running rather than stopping it.
