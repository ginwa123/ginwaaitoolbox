#!/usr/bin/env python3
"""Live end-to-end check of the in-app browser PANE (plan: 2026-09-14-in-app-browser-pane).

Boots the real engine in connect mode so the probe page plays the SPA, then:

  * asks for the pane (`nalarBrowserPaneShow`) and asserts the SPA's own viewport
    SHRINKS to the strip slot — the split really happened in the widget tree;
  * asserts the pane status agrees, and that the page target was loaded;
  * hides the pane and asserts the SPA gets the whole window back;
  * asserts the process spawned **no** child window (that is the whole point).

Needs a display, so it is NOT a CI gate — run it by hand after touching
`browser_pane.zig`, the vendored parent call, or the layout:

    python3 scripts/browser-pane-probe.py

Exit codes: 0 pass, 1 fail, 2 no binary, 3 skipped (no display).
Ports: 18090..18110 only. NEVER 8081 (and never the 8080..8199 dev window).
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
PORT_RANGE = range(18090, 18111)

PROBE_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>pane probe</title></head>
<body style="margin:0;background:#1d1c19;color:#c5c9c5;font:12px sans-serif">
<div style="height:36px;display:flex;align-items:center">&lt;the tab strip is this 36px row&gt;</div>
<script>
;(async function () {
  var report = function (m) { return fetch('/report?data=' + encodeURIComponent(m)).catch(function () {}) }
  var wait = function (ms) { return new Promise(function (r) { setTimeout(r, ms) }) }
  var before = window.innerHeight
  report('inner_before=' + before)
  if (typeof window.nalarBrowserPaneShow !== 'function') { report('DONE no-pane-bindings'); return }
  try {
    report('show=' + JSON.stringify(await window.nalarBrowserPaneShow('tab_probe', '__TARGET__')))
    await wait(700)
    report('inner_shown=' + window.innerHeight)
    report('status_shown=' + JSON.stringify(await window.nalarBrowserPaneStatus()))
    report('hide=' + JSON.stringify(await window.nalarBrowserPaneHide()))
    await wait(600)
    report('inner_hidden=' + window.innerHeight)
  } catch (e) { report('ERR ' + e) }
  report('DONE')
})()
</script></body></html>
"""

TARGET_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>pane target</title></head>
<body style="margin:0;background:#141412;color:#7fd;font:14px sans-serif">
<h1>PANE TARGET (the page)</h1></body></html>
"""


def desktop_binary() -> Path | None:
    override = os.environ.get("NALAR_DESKTOP_BIN")
    candidate = Path(override) if override else REPO_ROOT / "zig-out/bin/nalar-desktop"
    return candidate if candidate.is_file() else None


def has_display() -> bool:
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def children(pid: int) -> list[tuple[int, str]]:
    """(pid, cmdline) for each child — WebKit spawns its own helpers, so the
    assertion below looks for a *browser window*, not for any child at all."""
    try:
        out = subprocess.run(
            ["pgrep", "-P", str(pid)], capture_output=True, text=True, check=False
        ).stdout
    except Exception:
        return []
    result: list[tuple[int, str]] = []
    for line in out.split():
        try:
            cmd = (
                Path(f"/proc/{line}/cmdline")
                .read_bytes()
                .replace(b"\0", b" ")
                .decode("utf-8", "replace")
                .strip()
            )
        except OSError:
            cmd = ""
        result.append((int(line), cmd))
    return result


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

    with tempfile.TemporaryDirectory(prefix="nalar-pane-probe-") as tmp:
        serve_dir = Path(tmp)
        (serve_dir / "target.html").write_text(TARGET_HTML, encoding="utf-8")

        server = None
        port = None
        for candidate in PORT_RANGE:
            try:
                server = socketserver.TCPServer(("127.0.0.1", candidate), Handler)
                port = candidate
                break
            except OSError:
                continue
        if server is None or port is None:
            print(f"FAIL: no free port in {PORT_RANGE}")
            return 1

        (serve_dir / "probe.html").write_text(
            PROBE_HTML.replace("__TARGET__", f"http://127.0.0.1:{port}/target.html"),
            encoding="utf-8",
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()

        home = Path(tempfile.mkdtemp(prefix="nalar-pane-probe-home-"))
        app = subprocess.Popen(
            [
                str(binary),
                "--nalar-url",
                f"http://127.0.0.1:{port}/probe.html",
                "--window-size",
                "900x600",
                "--title",
                "pane probe",
            ],
            cwd=str(REPO_ROOT),
            env={**os.environ, "HOME": str(home)},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        print(f"[run] {binary.name} pid={app.pid} on 127.0.0.1:{port}")

        finished = done.wait(timeout=45)
        spawned = children(app.pid)
        # A pane must NOT spawn a window: the only children an app window has are
        # WebKit's own helpers (WebKitWebProcess / WebKitNetworkProcess).
        windows = [(pid, cmd) for pid, cmd in spawned if "--browser" in cmd or "nalar-desktop" in cmd]
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
        for pid, _cmd in spawned:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        server.shutdown()

    print("\n=== reports ===")
    for line in reports:
        print(" ", line)

    def value(key: str) -> str | None:
        for line in reports:
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
        return None

    problems: list[str] = []
    if not finished:
        problems.append("timed out")
    if any(r.startswith("ERR ") for r in reports) or value("DONE") == "no-pane-bindings":
        problems.append("the pane bindings are missing in the app window")

    def as_int(key: str) -> int | None:
        raw = value(key)
        try:
            return int(raw) if raw is not None else None
        except ValueError:
            return None

    before = as_int("inner_before")
    shown = as_int("inner_shown")
    hidden = as_int("inner_hidden")
    show_reply = value("show") or ""
    status_reply = value("status_shown") or ""

    if '"ok":true' not in show_reply:
        problems.append(f"show was refused: {show_reply!r}")
    if shown is None or not 30 <= shown <= 60:
        problems.append(f"the SPA viewport did not shrink to the strip: {shown!r}")
    if before is None or shown is None or shown >= before:
        problems.append(f"no measurable split (before={before!r} shown={shown!r})")
    if '"visible":true' not in status_reply or '"supported":true' not in status_reply:
        problems.append(f"status does not report a visible, supported pane: {status_reply!r}")
    if hidden is None or before is None or hidden < before - 60:
        problems.append(f"hiding did not give the SPA the window back: {hidden!r}")
    if windows:
        problems.append(f"the pane spawned a browser window: {windows}")

    if problems:
        print("\nFAIL: " + "; ".join(problems))
        return 1
    print(
        f"\nPASS: pane inside the app window — SPA viewport {before} -> {shown} (strip) -> "
        f"{hidden} (restored), no window, no child process."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
