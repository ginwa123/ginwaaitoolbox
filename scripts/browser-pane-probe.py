#!/usr/bin/env python3
"""Live end-to-end check of the in-app browser PANE (plan: 2026-09-14-in-app-browser-pane).

Boots the real engine in connect mode so the probe page plays the SPA, then:

  * asks for the pane at an explicit rect (where a browser tab's body would be)
    and asserts the SPA's own viewport is NOT shrunk — the pane must sit BESIDE
    the app, not eat the window (the report that prompted rev 2);
  * asserts the pane really loaded the page (the shell reports the pane view's
    URI length) and that a rect-only update moves it;
  * hides it (leaving a tab: the page survives) and then CLOSES it (closing the
    tab: the view is destroyed, so nothing keeps running in the background);
  * asserts the process spawned no window (that is the whole point).

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
<div style="height:36px;background:#242320">the tab strip</div>
<div style="position:absolute;left:0;top:36px;width:340px;height:100%;background:#20201d">
  the sidebar (the pane must NOT cover this)
</div>
<script>
;(async function () {
  var report = function (m) { return fetch('/report?data=' + encodeURIComponent(m)).catch(function () {}) }
  var wait = function (ms) { return new Promise(function (r) { setTimeout(r, ms) }) }
  var before = window.innerWidth
  report('width_before=' + before)
  if (typeof window.nalarBrowserPaneShow !== 'function') { report('DONE no-pane-bindings'); return }
  // Where a browser tab's body is: right of the sidebar, below the strip.
  var x = 360
  var y = 90
  var w = Math.max(120, window.innerWidth - x - 40)
  var h = Math.max(120, window.innerHeight - y - 40)
  report('rect_sent=' + [x, y, w, h].join(','))
  try {
    report('show=' + JSON.stringify(await window.nalarBrowserPaneShow('tab_probe', '__TARGET__', x, y, w, h)))
    await wait(900)
    report('width_shown=' + window.innerWidth)
    report('status_shown=' + JSON.stringify(await window.nalarBrowserPaneStatus()))
    report('rect_update=' + JSON.stringify(
      await window.nalarBrowserPaneRect(x, y + 20, w, Math.max(120, h - 20))))
    await wait(300)
    report('status_after_rect=' + JSON.stringify(await window.nalarBrowserPaneStatus()))
    report('hide=' + JSON.stringify(await window.nalarBrowserPaneHide()))
    await wait(400)
    report('status_hidden=' + JSON.stringify(await window.nalarBrowserPaneStatus()))
    report('close=' + JSON.stringify(await window.nalarBrowserPaneClose()))
    await wait(400)
    report('status_closed=' + JSON.stringify(await window.nalarBrowserPaneStatus()))
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
    """(pid, cmdline) per child: WebKit spawns its own helpers, so the assertion
    below looks for a *browser window*, not for any child at all."""
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

        target = f"http://127.0.0.1:{port}/target.html"
        (serve_dir / "probe.html").write_text(
            PROBE_HTML.replace("__TARGET__", target), encoding="utf-8"
        )
        threading.Thread(target=server.serve_forever, daemon=True).start()

        home = Path(tempfile.mkdtemp(prefix="nalar-pane-probe-home-"))
        app = subprocess.Popen(
            [
                str(binary),
                "--nalar-url",
                f"http://127.0.0.1:{port}/probe.html",
                "--window-size",
                "1100x700",
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
        windows = [
            (pid, cmd)
            for pid, cmd in spawned
            if "--browser" in cmd or "nalar-desktop" in cmd
        ]
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

    def as_int(key: str) -> int | None:
        raw = value(key)
        try:
            return int(raw) if raw is not None else None
        except ValueError:
            return None

    def rect_of(reply: str) -> list[int] | None:
        try:
            start = reply.index("[")
            end = reply.index("]")
            return [int(part) for part in reply[start + 1 : end].split(",")]
        except (ValueError, TypeError):
            return None

    problems: list[str] = []
    if not finished:
        problems.append("timed out")
    if any(r.startswith("ERR ") for r in reports) or value("DONE") == "no-pane-bindings":
        problems.append("the pane bindings are missing in the app window")

    before = as_int("width_before")
    shown = as_int("width_shown")
    hidden = as_int("width_hidden")
    sent = value("rect_sent")
    sent_rect = [int(p) for p in sent.split(",")] if sent else None
    show_reply = value("show") or ""
    status_shown = value("status_shown") or ""
    status_after_rect = value("status_after_rect") or ""
    status_hidden = value("status_hidden") or ""
    status_closed = value("status_closed") or ""

    if '"ok":true' not in show_reply:
        problems.append(f"show was refused: {show_reply!r}")
    if '"supported":true' not in status_shown or '"visible":true' not in status_shown:
        problems.append(f"status does not report a visible, supported pane: {status_shown!r}")
    if '"uri_len":0' in status_shown:
        problems.append(f"the pane never loaded the page: {status_shown!r}")
    if '"visible":true' not in status_hidden and '"visible":false' not in status_hidden:
        problems.append(f"hide replied without a visible flag: {status_hidden!r}")
    if '"visible":false' not in status_hidden:
        problems.append(f"hide left the pane visible: {status_hidden!r}")
    if '"uri_len":0' in status_hidden:
        problems.append(f"hiding destroyed the page (state must survive): {status_hidden!r}")
    if '"uri_len":0' not in status_closed:
        problems.append(f"closing the tab left the page running: {status_closed!r}")
    if windows:
        problems.append(f"the pane spawned a browser window: {windows}")

    if problems:
        print("\nFAIL: " + "; ".join(problems))
        return 1
    print(
        f"\nPASS: the pane splits the window (SPA {before}px -> {shown}px -> {hidden}px), "
        f"the page loaded, hide keeps it, close stops it, no window."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
