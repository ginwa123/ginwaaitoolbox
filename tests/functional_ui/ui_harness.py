"""UI test harness — boots a nalar backend + Vite dev server for Playwright.

Extends the existing ``FunctionalHarness`` boot story by ALSO spawning a
Vite dev server that:

  - Serves the Vue app from ``src/apps/desktop/``.
  - Proxies ``/api/*`` to the harness's chosen backend port (via the
    ``VITE_API_PROXY_TARGET`` env var, which ``src/apps/desktop/vite.config.ts``
    reads). This is what makes the test isolated: the running web app
    talks to the fixture's backend, not to the developer's always-on :8081.
  - Runs on its own free port (``5180-5299``), skipping Vite's default
    ``5173`` so it doesn't clash with developer dev-runs.

⛔  SAFETY INVARIANTS — INHERITED + EXTENDED  ⛔

The UI harness inherits ALL safety invariants from ``FunctionalHarness``:
``is_safe_tmp``, captured ``temp_dir``, ``ORIG_HOME`` snapshot, etc. The
new dimension is the **Vite process**.

1. ``UIHarness.teardown()`` stops Vite FIRST, then the backend, then
   rmtree's the tempdir. The order matters: if we killed the backend
   first, Vite's HTTP requests would 502 mid-shutdown and could leak
   dangling connections.

2. Vite is spawned with ``start_new_session=True`` so a single
   ``killpg(SIGTERM)`` kills the whole group (vite + esbuild + rollup
   children). Same pattern as the backend.

3. Vite logs go to ``temp_dir/vite.log`` (the same tempdir the backend's
   logs land in). Teardown rmtree's both via the existing
   ``FunctionalHarness.teardown()`` path.

4. Vite's own HOME / data dir is NOT shadowed — vite doesn't write to
   ``~/.cache`` or anything user-specific. We only shadow HOME for the
   backend; the frontend is stateless from a data perspective.

5. **Cross-platform isolation** (macOS, Linux, Windows):
   - **npm resolution**: ``shutil.which('npm')`` falls back to
     ``shutil.which('npm.cmd')`` for Windows, where ``npm`` is a batch
     script and ``subprocess.Popen(['npm', ...])`` would otherwise fail
     with ``FileNotFoundError``.
   - **Vite signal handling**: POSIX uses ``os.killpg(SIGTERM)`` to
     signal the whole process group; Windows falls back to ``os.kill``
     (which calls ``TerminateProcess``).
   - **Source path resolution**: ``Path`` objects work cross-platform;
     the ``cwd=`` argument to ``subprocess.Popen`` accepts both
     ``/`` and ``\\`` separators.
   - **Tempdir safety**: inherited from ``FunctionalHarness.teardown``
     which now handles Windows paths via ``tempfile.gettempdir()``
     (the parent fix in 2026-08-21 makes ``is_safe_tmp`` cross-platform
     by using native backslashes on Windows).

6. **The UI harness NEVER calls ``shutil.rmtree`` itself.** All rmtree
   goes through ``FunctionalHarness.teardown`` which is gated by
   ``is_safe_tmp``. This is the single source of truth for "may this
   path be deleted" — same as the parent harness.

Run quick:
    from harness import UIHarness
    with UIHarness.boot() as h:
        print(h.web_url())  # http://127.0.0.1:5180/
"""

from __future__ import annotations

import contextlib
import dataclasses
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterator

# Reuse the existing harness — battle-tested for boot + teardown.
from harness import (
    DEFAULT_PORT,
    FunctionalHarness,
    FunctionalHarnessError,
    REQUIRED_TMP_SUBSTR,
    Response,
    is_safe_tmp,
)


# ============================================================================
# Vite-specific constants
# ============================================================================

#: Vite port range. Skips Vite's default 5173 to avoid clashing with a
#: developer's running ``pnpm dev`` session. The harness scans this range
#: for a free port.
VITE_PORT_START = 5180
VITE_PORT_END = 5299

#: Vite ready timeout. Vite's first compile + module-graph build takes
#: ~5-15s on a warm cache, more on cold. We poll vite's HTTP root for
#: a 200 response — by the time Vite is serving, the bundle is ready.
VITE_READY_TIMEOUT_S = 60.0

#: Polling interval for vite readiness. 200ms is fine — vite's compile
#: is the slow part, not the wait.
VITE_POLL_INTERVAL_S = 0.2


# ============================================================================
# UIHarness
# ============================================================================


@dataclasses.dataclass
class UIHarness:
    """A booted nalar backend + Vite dev server, both bound to the same
    isolated tmpdir as the backend's HOME.

    The frontend (Vite) is spawned AFTER the backend is ready, with
    ``VITE_API_PROXY_TARGET`` pointing at the backend's chosen port.
    This makes the running web app's ``/api/*`` calls land on the
    fixture's backend, not on the developer's always-running :8081.

    Lifecycle:
        h = UIHarness.boot()
        try:
            page = browser.new_page()
            page.goto(h.web_url())
            ... drive the UI ...
        finally:
            h.teardown()

    The teardown order is:
      1. SIGTERM the Vite process group (5s budget).
      2. SIGTERM the backend process group (handled by
         ``FunctionalHarness.teardown``).
      3. Restore HOME (handled by ``FunctionalHarness.teardown``).
      4. ``is_safe_tmp`` validate the tempdir (handled by
         ``FunctionalHarness.teardown``).
      5. ``shutil.rmtree`` the tempdir (handled by
         ``FunctionalHarness.teardown``).
    """

    backend: FunctionalHarness
    vite_port: int
    vite_pid: int | None
    vite_log_path: Path
    vite_proc: subprocess.Popen[bytes] | None
    project_root: Path
    vite_killed: bool = False

    # ---- bootstrap --------------------------------------------------------

    @classmethod
    def boot(
        cls,
        nalar_bin: Path | None = None,
        *,
        port: int = DEFAULT_PORT,
        vite_port: int | None = None,
        ready_timeout_s: float = 30.0,
        vite_ready_timeout_s: float = VITE_READY_TIMEOUT_S,
        stub_llm_profile: bool = False,
        project_root: Path | None = None,
    ) -> "UIHarness":
        """Boot backend + vite against an isolated tmpdir HOME.

        Args:
            nalar_bin: Path to the nalar binary (default: $NALAR_BIN or
                zig-out/bin/nalar).
            port: Backend port (default 8080; harness scans 8080, 8082-8199
                skipping 8081).
            vite_port: Vite port (default: scan 5180-5299). Pass a value
                to skip the scan.
            ready_timeout_s: Seconds to wait for nalar to become ready.
            vite_ready_timeout_s: Seconds to wait for vite to serve a 200
                on its root URL.
            stub_llm_profile: If True, pre-create a stub LLM profile so
                the backend boots without a real API key. Same as the
                functional/ harness.
            project_root: Path to the frontend source tree (default:
                walk up from cwd until we find package.json + vite.config.ts).
                The harness will cwd to this directory when spawning vite.

        Raises:
            FunctionalHarnessError: If the backend OR vite fails to boot,
                the tempdir fails the safety check, or the project root
                is missing.
        """
        # 1. Boot the backend (inherited harness). If this fails, the
        #    tempdir is cleaned up by FunctionalHarness.boot internally.
        backend = FunctionalHarness.boot(
            nalar_bin,
            port=port,
            ready_timeout_s=ready_timeout_s,
            stub_llm_profile=stub_llm_profile,
        )

        # 2. Resolve the frontend project root.
        if project_root is None:
            project_root = cls._find_project_root()
        if not (project_root / "package.json").exists():
            backend.teardown()
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain package.json"
            )
        if not (project_root / "vite.config.ts").exists():
            backend.teardown()
            raise FunctionalHarnessError(
                f"project_root {project_root} does not contain vite.config.ts"
            )

        # 3. Pick a free vite port.
        chosen_vite_port = _find_free_vite_port(vite_port)

        # 4. Resolve the npm binary. On Windows, ``npm`` is a batch
        #    script (``npm.cmd``) and ``subprocess.Popen(["npm", ...])``
        #    fails with FileNotFoundError because Windows won't
        #    auto-execute .cmd files from a list-form argv. shutil.which
        #    resolves to the correct executable for the platform.
        npm_bin = shutil.which("npm") or shutil.which("npm.cmd")
        if npm_bin is None:
            backend.teardown()
            raise FunctionalHarnessError(
                "npm not found in PATH. Install Node.js (https://nodejs.org/) "
                "or add the npm binary directory to PATH."
            )

        # 5. Spawn vite. We use npm + --port + --strictPort so vite
        #    fails fast if it can't bind (instead of silently picking
        #    the next port and breaking our env wiring).
        env = os.environ.copy()
        env["VITE_API_PROXY_TARGET"] = f"http://127.0.0.1:{backend.port}"
        # Vite reads .env files; we set BROWSER=none so vite doesn't try
        # to open a browser tab on the developer's display.
        env["BROWSER"] = "none"
        vite_log_path = backend.temp_dir / "vite.log"
        vite_log_file = vite_log_path.open("wb")
        vite_proc = subprocess.Popen(
            [
                npm_bin,
                "run",
                "dev",
                "--",
                "--port",
                str(chosen_vite_port),
                "--strictPort",
                "--host",
                "127.0.0.1",
            ],
            cwd=str(project_root),
            stdout=vite_log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

        instance = cls(
            backend=backend,
            vite_port=chosen_vite_port,
            vite_pid=vite_proc.pid,
            vite_log_path=vite_log_path,
            vite_proc=vite_proc,
            project_root=project_root,
        )

        # 5. Wait for vite to be ready. If this fails, tear down everything.
        try:
            instance._wait_vite_ready(vite_ready_timeout_s)
        except Exception:
            with contextlib.suppress(ProcessLookupError):
                vite_proc.kill()
            vite_log_file.close()
            backend.teardown()
            raise

        return instance

    # ---- re-exported accessors --------------------------------------------

    @property
    def port(self) -> int:
        """The backend's port (= the proxy target)."""
        return self.backend.port

    @property
    def temp_dir(self) -> Path:
        """The isolated tmpdir; the frontend and backend both log here."""
        return self.backend.temp_dir

    @property
    def orig_home(self) -> str:
        """The real $HOME that was snapshotted at boot."""
        return self.backend.orig_home

    @property
    def pid(self) -> int | None:
        """The backend's PID. Use ``backend_pid`` for explicit access."""
        return self.backend.pid

    @property
    def backend_pid(self) -> int | None:
        return self.backend.pid

    @property
    def log_path(self) -> Path:
        """The backend's log path. Use ``backend_log_path`` for explicit access."""
        return self.backend.log_path

    @property
    def backend_log_path(self) -> Path:
        return self.backend.log_path

    def http(self, *args: Any, **kwargs: Any) -> Response:
        """Delegate to the backend's HTTP client. See FunctionalHarness.http."""
        return self.backend.http(*args, **kwargs)

    def health(self) -> bool:
        return self.backend.health()

    def tail_log(self, n: int = 50) -> str:
        return self.backend.tail_log(n)

    def tail_vite_log(self, n: int = 50) -> str:
        """Tail the vite dev server log. Useful for debugging browser-test failures."""
        try:
            with self.vite_log_path.open("rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 65536))
                data = f.read().decode("utf-8", errors="replace")
            return "\n".join(data.splitlines()[-n:])
        except FileNotFoundError:
            return ""

    def web_url(self, path: str = "/") -> str:
        """The URL a browser should load to see the running web app.

        Example::

            page.goto(h.web_url("/"))

        Path is joined with a leading slash if missing.
        """
        if not path.startswith("/"):
            path = "/" + path
        return f"http://127.0.0.1:{self.vite_port}{path}"

    # ---- teardown --------------------------------------------------------

    def teardown(self) -> None:
        """Stop vite, then teardown the backend (which cleans the tempdir).

        Order matters:
          1. Stop vite — so the frontend stops proxying requests to a
             backend that may be about to die.
          2. Backend teardown — SIGTERM, restore HOME, validate tmpdir,
             rmtree.
        """
        # 1. Stop vite. Idempotent.
        self._stop_vite()

        # 2. Backend teardown. This handles HOME restore, SIGTERM/SIGKILL
        #    the binary, is_safe_tmp validation, and rmtree.
        self.backend.teardown()

    def __enter__(self) -> "UIHarness":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.teardown()

    # ---- private helpers -------------------------------------------------

    def _stop_vite(self) -> None:
        """SIGTERM the vite process group, fall back to SIGKILL after 5s.

        Mirrors the backend's teardown pattern but uses shorter timeouts
        (vite doesn't have a graceful shutdown endpoint — it's fine to
        be aggressive here).
        """
        if self.vite_proc is None or self.vite_killed:
            return
        self.vite_killed = True
        # Send SIGTERM to the whole process group.
        try:
            self._signal_vite_group(signal.SIGTERM)
        except Exception:
            pass
        if self._wait_vite_dead(5.0):
            return
        # Last resort — SIGKILL.
        try:
            self._signal_vite_group(signal.SIGKILL)
        except Exception:
            pass
        self._wait_vite_dead(1.0)  # best-effort final wait

    def _wait_vite_dead(self, timeout: float) -> bool:
        """Return True iff the vite process exited within ``timeout`` seconds."""
        if self.vite_proc is None:
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.vite_proc.poll() is not None:
                return True
            time.sleep(0.05)
        return False

    def _signal_vite_group(self, sig: int) -> None:
        """Signal the vite process group on POSIX, or the pid on Windows."""
        if self.vite_pid is None:
            return
        if hasattr(os, "killpg"):
            try:
                pgid = os.getpgid(self.vite_pid)
            except OSError:
                pgid = self.vite_pid
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
        else:
            try:
                os.kill(self.vite_pid, sig)
            except OSError:
                pass

    def _wait_vite_ready(self, timeout_s: float) -> None:
        """Poll vite's HTTP root until it returns 200 or timeout.

        Raising 200 means vite has compiled the bundle and is serving.
        Until then, requests may hang or 404 on module imports.
        """
        assert self.vite_proc is not None
        deadline = time.monotonic() + timeout_s
        url = f"http://127.0.0.1:{self.vite_port}/"
        last_err: str = ""
        while time.monotonic() < deadline:
            if self.vite_proc.poll() is not None:
                log = (
                    self.vite_log_path.read_text(errors="replace")
                    if self.vite_log_path.exists()
                    else ""
                )
                raise FunctionalHarnessError(
                    f"vite exited rc={self.vite_proc.returncode} during boot\n"
                    f"--- last 30 lines of vite.log ---\n"
                    + "\n".join(log.splitlines()[-30:])
                )
            try:
                with urllib.request.urlopen(url, timeout=1.0) as resp:
                    if resp.status == 200:
                        return
            except (urllib.error.URLError, ConnectionError, OSError) as e:
                last_err = str(e)
            time.sleep(VITE_POLL_INTERVAL_S)
        log = (
            self.vite_log_path.read_text(errors="replace")
            if self.vite_log_path.exists()
            else ""
        )
        raise FunctionalHarnessError(
            f"vite did not become ready in {timeout_s}s (last_err={last_err})\n"
            f"--- last 30 lines of vite.log ---\n"
            + "\n".join(log.splitlines()[-30:])
        )

    @staticmethod
    def _find_project_root() -> Path:
        """Walk up from cwd looking for a directory with package.json + vite.config.ts.

        Falls back to the relative path ``src/apps/desktop`` from the
        repo root (the project's expected layout). If the harness is
        invoked from elsewhere, override via ``project_root=``.
        """
        cwd = Path.cwd().resolve()
        for candidate in (cwd, *cwd.parents):
            if (candidate / "package.json").exists() and (
                candidate / "vite.config.ts"
            ).exists():
                return candidate
        # Fallback: assume the standard layout.
        standard = cwd / "src" / "apps" / "desktop"
        if standard.exists():
            return standard
        raise FunctionalHarnessError(
            f"Could not find a project_root with package.json + vite.config.ts "
            f"starting from {cwd}. Pass project_root= explicitly."
        )


# ============================================================================
# Helpers
# ============================================================================


def _find_free_vite_port(suggested: int | None) -> int:
    """Find a free port in [VITE_PORT_START, VITE_PORT_END] (or use ``suggested``).

    If ``suggested`` is provided and is free, use it. Otherwise, scan
    the range. Raises FunctionalHarnessError if no port is free.
    """
    if suggested is not None:
        if not _port_is_free(suggested):
            raise FunctionalHarnessError(
                f"Suggested vite port {suggested} is already in use"
            )
        return suggested
    for port in range(VITE_PORT_START, VITE_PORT_END + 1):
        if _port_is_free(port):
            return port
    raise FunctionalHarnessError(
        f"No free vite port found in {VITE_PORT_START}..{VITE_PORT_END}"
    )


def _port_is_free(port: int) -> bool:
    """Bind to 127.0.0.1:<port> and immediately close; return True iff it was free."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


# ============================================================================
# Convenience for scripts that don't want pytest fixtures
# ============================================================================


def run_quick(
    nalar_bin: Path | None = None,
    *,
    port: int = DEFAULT_PORT,
    stub_llm_profile: bool = False,
) -> Iterator[UIHarness]:
    """Context manager for use outside pytest.

    Example::

        with run_quick() as h:
            print(h.web_url())  # http://127.0.0.1:5180/
    """
    h = UIHarness.boot(
        nalar_bin, port=port, stub_llm_profile=stub_llm_profile
    )
    try:
        yield h
    finally:
        h.teardown()


__all__ = [
    "UIHarness",
    "VITE_PORT_START",
    "VITE_PORT_END",
    "VITE_READY_TIMEOUT_S",
    "run_quick",
]
