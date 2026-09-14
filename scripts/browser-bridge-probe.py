#!/usr/bin/env python3
"""Live end-to-end check of the SPA→shell `webview_bind` bridge.

Why this exists: a binding whose *name* the vendored JS glue cannot expose
(`webview_bind` does `window[name] = …` verbatim — no namespace walking, so a
dotted name becomes a flat property and `window.nalarBrowser` stays undefined)
passed every unit test on both sides and a source grep. It was only visible in
the real engine, as a button that silently did nothing. This script is that
check, made repeatable.

What it does:

1. serves a probe page from a temp dir;
2. boots `nalar-desktop --nalar-url http://127.0.0.1:<port>/probe.html` — connect
   mode, i.e. the APP window, the only window that gets the bindings;
3. the probe page calls the three globals exactly as the SPA does and reports
   each reply back over HTTP;
4. asserts: the flat globals exist, `open` spawns a window (`{ok,alive:1}`),
   `status` reports it alive, `close` terminates it, and a later `status`
   reports it gone.

Needs a display (GTK/WebKit), so it is NOT a CI gate — run it by hand after
touching the bridge, and on each new platform:

    python3 scripts/browser-bridge-probe.py

Exit codes: 0 pass, 1 fail, 2 no binary, 3 skipped (no display).
Ports: 18080..18100 only. NEVER 8081 (the always-running dev backend), and
never the 8080..8199 dev window.
"""

from __future__ import annotations

import http.server
import os
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parents[1]
PORT_RANGE = range(18080, 18101)

PROBE_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>bridge probe</title></head>
<body style="font:13px sans-serif;color:#c5c9c5;background:#1d1c19">
<p>bridge probe running…</p>
<script>
;(async function () {
  var report = function (m) { return fetch('/report?data=' + encodeURIComponent(m)).catch(function () {}) }
  var flat = typeof window.nalarBrowserOpen === 'function' &&
             typeof window.nalarBrowserStatus === 'function' &&
             typeof window.nalarBrowserClose === 'function'
  report('flat_bindings=' + flat + ' object_shape=' + typeof window.nalarBrowser)
  if (!flat) { report('DONE no-bridge'); return }
  try {
    report('open=' + JSON.stringify(await window.nalarBrowserOpen('tab_probe', '__TARGET__')))
    await new Promise(function (r) { setTimeout(r, 900) })
    report('status=' + JSON.stringify(await window.nalarBrowserStatus('tab_probe')))
    report('close=' + JSON.stringify(await window.nalarBrowserClose('tab_probe')))
    await new Promise(function (r) { setTimeout(r, 600) })
    report('status_after_close=' + JSON.stringify(await window.nalarBrowserStatus('tab_probe')))
  } catch (e) { report('ERR ' + e) }
  report('DONE')
})()
</script></body></html>
"""

BLANK_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>probe target</title></head>
<body style="font:13px sans-serif;color:#c5c9c5;background:#141412">
<p>probe target page</p></body></html>
"""

EXPECTED = (
    "flat_bindings=true",
    'open={"ok":true,"alive":1}',
    'status={"alive":1}',
    'close={"ok":true}',
    'status_after_close={"alive":0}',
    "DONE",
)


def desktop_binary() -> Path | None:
    override = os.environ.get("NALAR_DESKTOP_BIN")
    candidate = Path(override) if override else REPO_ROOT / "zig-out/bin/nalar-desktop"
    return candidate if candidate.is_file() else None


def has_display() -> bool:
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def make_handler(serve_dir: Path, reports: list[str], done: threading.Event):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(serve_dir), **kwargs)

        def do_GET(self):  # noqa: N802
            if self.path.startswith("/report?"):
                data = parse_qs(urlparse(self.path).query).get("data", [""])[0]
                reports.append(data)
                print(f"[probe] {data}", flush=True)
                if data == "DONE":
                    done.set()
                body = b"ok"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            return super().do_GET()

        def log_message(self, *args):
            pass

    return Handler


def main() -> int:
    binary = desktop_binary()
    if binary is None:
        print("SKIP: nalar-desktop not built (zig build nalar-desktop)")
        return 2
    if not has_display():
        print("SKIP: no DISPLAY / WAYLAND_DISPLAY — the engine cannot open a window")
        return 3

    reports: list[str] = []
    done = threading.Event()

    with tempfile.TemporaryDirectory(prefix="nalar-bridge-probe-") as tmp:
        serve_dir = Path(tmp)
        (serve_dir / "blank.html").write_text(BLANK_HTML, encoding="utf-8")

        server = None
        port = None
        for candidate in PORT_RANGE:
            try:
                server = socketserver.TCPServer(
                    ("127.0.0.1", candidate), make_handler(serve_dir, reports, done)
                )
                port = candidate
                break
            except OSError:
                continue
        if server is None or port is None:
            print(f"FAIL: no free port in {PORT_RANGE}")
            return 1

        (serve_dir / "probe.html").write_text(
            PROBE_HTML.replace("__TARGET__", f"http://127.0.0.1:{port}/blank.html"),
            encoding="utf-8",
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()

        home = Path(tempfile.mkdtemp(prefix="nalar-bridge-probe-home-"))
        app = subprocess.Popen(
            [
                str(binary),
                "--nalar-url",
                f"http://127.0.0.1:{port}/probe.html",
                "--window-size",
                "380x220",
                "--title",
                "bridge probe",
            ],
            cwd=str(REPO_ROOT),
            env={**os.environ, "HOME": str(home)},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        print(f"[run] {binary.name} pid={app.pid} on 127.0.0.1:{port}")

        finished = done.wait(timeout=40)
        time.sleep(0.4)
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
        # Any window the probe spawned is closed through the bridge; sweep the
        # rest so a failure does not leave processes behind.
        for pid in _children(app.pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        server.shutdown()

    print("\n=== reports ===")
    for line in reports:
        print(" ", line)
    missing = [item for item in EXPECTED if not any(item in r for r in reports)]
    if not finished or missing or any(r.startswith("ERR ") for r in reports):
        print(f"\nFAIL: timed_out={not finished} missing={missing}")
        return 1
    print(
        "\nPASS: the live webview reached all three bindings; the window opened, "
        "reported alive, closed and reported gone."
    )
    return 0


def _children(pid: int) -> list[int]:
    try:
        out = subprocess.run(
            ["pgrep", "-P", str(pid)], capture_output=True, text=True, check=False
        ).stdout
        return [int(line) for line in out.split()]
    except Exception:
        return []


if __name__ == "__main__":
    sys.exit(main())
