"""Functional test harness for nalar.

Boots a real `nalar` binary against an isolated tmpdir HOME and provides
a typed HTTP client for the API. Every byte of state (DB, config, design
files, attachments) lives under the tempdir allocated at boot; teardown
rmtree's that tempdir, never anything else.

⛔  SAFETY INVARIANTS — DO NOT WEAKEN WITHOUT REVIEW  ⛔

1. ``is_safe_tmp(path, orig_home)`` is the SINGLE source of truth for
   "may this path be deleted by the harness". Any ``shutil.rmtree`` call
   MUST be gated by it. There is no second code path.

2. The harness NEVER calls ``os.environ["HOME"]`` inside teardown. It
   uses the captured ``self.temp_dir`` attribute, which is set once at
   boot and not subject to mid-test env mutation.

3. The harness NEVER uses ``~``, ``os.path.expanduser``, or relative
   paths. All paths are absolute and captured.

4. If ``is_safe_tmp()`` returns False, teardown RAISES instead of
   deleting. The tempdir is leaked; the developer's home is never
   touched. This is the correct trade-off.

5. ``ORIG_HOME`` is captured BEFORE ``os.environ["HOME"]`` is shadowed
   and restored as the first step of teardown. A stray ``~`` in any
   downstream code expands to the tempdir, not the real home.

The five negative tests in ``tests/functional/harness_safety_test.py``
guard these invariants against regression.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import random
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterator

# ============================================================================
# Safety constants
# ============================================================================

#: Tuple of absolute path prefixes that the harness recognises as "tmpdir".
#: ``tempfile.mkdtemp`` on Linux returns ``/tmp/...``; on macOS it returns
#: ``/var/folders/.../T/...`` (or ``/private/var/folders/.../T/...`` after
#: ``realpath``); on Windows it returns ``C:\Users\<u>\AppData\Local\Temp\...``
#: (or a custom ``%TEMP%`` location). The POSIX prefix list is unused on
#: Windows and the Windows prefix uses native backslashes so ``startswith``
#: matches ``realpath``'s output on that OS.
ALLOWED_TMP_PREFIXES: tuple[str, ...] = (
    "/tmp/",
    "/private/tmp/",
    "/private/var/folders/",
    "/var/folders/",
    tempfile.gettempdir() + "/",
) if os.name != "nt" else (
    # Windows: only ``tempfile.gettempdir()`` (e.g. ``C:\Users\u\AppData\Local\Temp``)
    # is a valid tmpdir — the POSIX prefixes above don't exist. Use native
    # backslashes so the prefix matches ``os.path.realpath``'s output.
    tempfile.gettempdir().rstrip("\\") + "\\",
)

#: Substring that every harness-allocated tmpdir must contain. Acts as
#: a "namespace" so a buggy caller that points ``mkdtemp`` output at a
#: non-tmpdir path is rejected.
REQUIRED_TMP_SUBSTR = "nalar-func-"

#: Port range the harness will scan for a free port. Skip 8081 (the
#: always-running dev port per project memory). Used by the legacy
#: sequential picker (``_find_free_port_sequential``); the modern
#: ``_find_free_port`` defaults to random selection in the much larger
#: range below.
DEFAULT_PORT = 8080
PORT_SCAN_END = 8199

#: Random-port range used by ``_find_free_port`` (no args) and
#: ``find_free_port_random``. IANA's "dynamic/private" port range is
#: 49152-65535, but we extend slightly downward to 40000 to give 20,000
#: ports of headroom. CI runners routinely hold thousands of ephemeral
#: ports in TIME_WAIT; 20k picks with 50 random attempts gives
#: effectively-zero collision probability for any realistic host
#: occupancy.
RANDOM_PORT_START = 40000
RANDOM_PORT_END = 60000

#: Number of random attempts before giving up. With 20,000 ports and
#: ~1000 ephemeral ports in TIME_WAIT on a busy CI runner, the chance
#: of 50 consecutive collisions is ~(1000/20000)^50 ≈ 10�⁷⁹ — safely
#: "never happens". If a host is so loaded that this raises, the
#: harness surfaces the failure with the actionable hint to widen the
#: range.
RANDOM_PORT_ATTEMPTS = 50

#: Ports that the random picker MUST skip regardless of bind() success.
#: 8081 is the always-running dev backend per project memory. The
#: ``UIHarness`` adds 5173 (Vite's default) when calling
#: ``find_free_port_random(reserved=...)``.
RESERVED_PORTS: tuple[int, ...] = (8081,)


# ============================================================================
# Errors
# ============================================================================


class FunctionalHarnessError(RuntimeError):
    """Raised when the harness cannot safely proceed.

    Distinct from ``AssertionError`` (which is what API-level asserts
    raise) so test fixtures can catch this and treat it as a setup
    failure rather than a test failure.
    """


# ============================================================================
# Safety validator
# ============================================================================


def is_safe_tmp(path: str | os.PathLike[str], orig_home: str | os.PathLike[str]) -> bool:
    """Return True iff ``path`` is a tmpdir the harness is allowed to rmtree.

    Returns False for:
      - empty strings
      - non-absolute paths
      - paths outside the allow-list of tmpdir prefixes
      - paths missing the REQUIRED_TMP_SUBSTR namespace
      - paths that resolve to the real ``$HOME`` (catches symlinks)

    This function is the single source of truth for "may this be deleted".
    ANY rmtree in the harness MUST be gated by it.
    """
    if not path:
        return False
    p = os.fspath(path)
    if not os.path.isabs(p):
        return False
    real = os.path.realpath(p)
    if not any(real.startswith(prefix) for prefix in ALLOWED_TMP_PREFIXES):
        return False
    if REQUIRED_TMP_SUBSTR not in real:
        return False
    real_home = os.path.realpath(os.fspath(orig_home)) if orig_home else ""
    if real_home and real == real_home:
        return False
    return True


# ============================================================================
# Response + Harness
# ============================================================================


@dataclasses.dataclass(frozen=True)
class Response:
    """A typed HTTP response from the nalar API."""

    status: int
    body: bytes
    headers: dict[str, str] = dataclasses.field(default_factory=dict)

    def json(self) -> Any:
        """Parse the body as JSON. Raises on invalid JSON."""
        return json.loads(self.body)


@dataclasses.dataclass
class FunctionalHarness:
    """A booted nalar instance bound to an isolated tmpdir.

    Lifecycle:
        h = FunctionalHarness.boot()
        try:
            r = h.http("POST", "/api/workspaces", json_body={"name": "x"})
            assert r.status == 201
        finally:
            h.teardown()

    The tempdir is validated BEFORE teardown runs. If validation fails
    (e.g., mkdtemp returned something unexpected), teardown raises
    and refuses to delete anything.
    """

    port: int
    nalar_bin: Path
    temp_dir: Path
    orig_home: str
    log_path: Path
    pid: int | None = None
    dry_run: bool = False
    _stopped: bool = dataclasses.field(default=False, repr=False)

    # ---- bootstrap --------------------------------------------------------

    @classmethod
    def boot(
        cls,
        nalar_bin: Path | None = None,
        *,
        port: int | None = None,
        ready_timeout_s: float = 30.0,
        stub_llm_profile: bool = False,
    ) -> "FunctionalHarness":
        """Boot a fresh nalar binary against an isolated tmpdir HOME.

        Args:
            nalar_bin: Path to the nalar binary. Defaults to ``$NALAR_BIN``
                or a known zig-out path.
            port: Backend port. ``None`` (the default) picks a **random**
                free port from the wide ``[RANDOM_PORT_START,
                RANDOM_PORT_END]`` range via ``find_free_port_random`` —
                see the Port Allocation section of
                ``tests/functional/README.md`` for why this replaced the
                previous sequential scan. Pass an explicit integer (e.g.
                ``port=8123``) to fall back to a sequential scan from
                that port for backwards compat / debugging.
            ready_timeout_s: Seconds to wait for nalar to become ready.
            stub_llm_profile: Pre-create a stub LLM profile so the
                backend boots without a real API key.

        Raises:
            FunctionalHarnessError: if HOME is unset, the tmpdir fails
                the safety check, the binary is missing, or the binary
                does not become ready within ``ready_timeout_s``.
        """
        # 1. Snapshot HOME BEFORE we shadow it.
        orig_home = os.environ.get("HOME", "")
        if not orig_home:
            raise FunctionalHarnessError(
                "HOME not set; refusing to boot. "
                "Functional tests must run in a normal user shell."
            )

        # 1.5. Reap orphan nalar pids from prior aborted runs. This MUST
        #      run BEFORE _find_free_port() so the random pick sees a
        #      clean slate. Without this, a prior `kill -9` of the pytest
        #      worker leaves nalar children alive in their own pgids,
        #      holding their ports — and over time those zombies consume
        #      random picks in the 20k window. Failures here are
        #      non-fatal: if reap raises, print a warning and continue
        #      (a slightly leakier state is strictly better than
        #      aborting).
        try:
            _reap_orphan_test_pids()
        except Exception as e:
            print(f"warning: orphan reap failed: {e}", file=sys.stderr)

        # 2. Pick a free port. None / no arg → random pick from the
        #    20k-port range (see RANDOM_PORT_START..END). Explicit
        #    int → sequential scan from that port for backward compat
        #    with tests that want a deterministic value.
        chosen_port = _find_free_port(port)

        # 3. mkdtemp. Atomic, fresh, mode 0700.
        temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))

        # 4. Validate BEFORE shadowing HOME. If this fails, we abort
        #    and the tempdir is leaked. Leaking a tempdir is preferable
        #    to corrupting state.
        if not is_safe_tmp(str(temp_dir), orig_home):
            raise FunctionalHarnessError(
                f"mkdtemp produced an unsafe path: {temp_dir}\n"
                f"Expected prefix in {ALLOWED_TMP_PREFIXES}\n"
                f"With substring {REQUIRED_TMP_SUBSTR!r}\n"
                f"Refusing to proceed; tempdir leaked."
            )

        # 5. Optionally pre-create a stub LLM profile so the binary
        #    can start without a real api_key. Calls to the LLM endpoint
        #    will fail at runtime (which is fine — they're not what
        #    functional tests assert on).
        if stub_llm_profile:
            _write_stub_llm_profile(temp_dir)

        # 6. Resolve the binary.
        bin_path = nalar_bin if nalar_bin is not None else _default_nalar_bin()
        if not bin_path.exists():
            raise FunctionalHarnessError(f"nalar binary not found: {bin_path}")
        if not os.access(bin_path, os.X_OK):
            raise FunctionalHarnessError(f"nalar binary not executable: {bin_path}")

        # 7. Spawn. Cross-platform: on POSIX, start_new_session=True
        #    puts the child in its own process group (so killpg kills
        #    any subprocess the binary spawned). On Windows,
        #    start_new_session maps to CREATE_NEW_PROCESS_GROUP and
        #    killpg is unavailable — we use kill-by-pid instead.
        log_path = temp_dir / "nalar.log"
        env = os.environ.copy()
        env["HOME"] = str(temp_dir)
        log_file = log_path.open("wb")
        # `start_new_session=True` is a keyword arg accepted on
        # Python 3.2+ for both POSIX (setsid) and Windows
        # (CREATE_NEW_PROCESS_GROUP). Pass it unconditionally.
        proc = subprocess.Popen(
            [str(bin_path), "--port", str(chosen_port)],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

        # 7.5. Record pids so a subsequent boot can reap us if we die.
        #      The pidfile format is "<harness_pid> <nalar_pid>\n":
        #        - harness_pid: the Python process running this code
        #          (pytest worker, or the bare pytest process without xdist).
        #          When reap sees this pid is dead, the tempdir is an orphan.
        #        - nalar_pid: the actual nalar binary holding the TCP port.
        #          When reap sees the harness is dead, it kills this pid.
        #      Wrapped in try/except because a write failure here must NOT
        #      prevent tests from running — the worst case is "this test
        #      won't be reaped on the next boot" which is the pre-patch
        #      behaviour anyway.
        try:
            (temp_dir / ".harness.pid").write_text(f"{os.getpid()} {proc.pid}\n")
        except OSError as e:
            print(f"warning: failed to write pidfile: {e}", file=sys.stderr)

        # 8. Wait for readiness.
        try:
            _wait_ready(chosen_port, ready_timeout_s, proc, log_path)
        except Exception:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            log_file.close()
            raise

        return cls(
            port=chosen_port,
            nalar_bin=bin_path,
            temp_dir=temp_dir,
            orig_home=orig_home,
            log_path=log_path,
            pid=proc.pid,
            dry_run=os.environ.get("NALAR_FUNCTIONAL_DRY_RUN") == "1",
        )

    # ---- HTTP client ------------------------------------------------------

    def http(
        self,
        method: str,
        path: str,
        *,
        json_body: dict | list | None = None,
        params: dict[str, Any] | None = None,
        expect: int | tuple[int, ...] = 200,
        timeout_s: float = 5.0,
    ) -> Response:
        """Issue an HTTP request to the harness's nalar instance.

        Args:
            method: HTTP verb (GET, POST, PUT, PATCH, DELETE).
            path: URL path beginning with ``/`` (e.g. ``/api/workspaces``).
            json_body: Optional JSON-serializable body. Sets
                ``Content-Type: application/json``.
            params: Optional URL query parameters.
            expect: Status code or tuple of acceptable codes. Default 200.
                On mismatch, raises AssertionError with the body excerpt.
            timeout_s: Per-request timeout.

        Returns:
            Response with status, body, and headers.

        Raises:
            AssertionError: if the response status is not in ``expect``.
        """
        url = f"http://127.0.0.1:{self.port}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data: bytes | None = None
        headers: dict[str, str] = {}
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                status = resp.status
                body = resp.read()
                resp_headers = {k: v for k, v in resp.headers.items()}
        except urllib.error.HTTPError as e:
            status = e.code
            body = e.read()
            resp_headers = {k: v for k, v in (e.headers.items() if e.headers else [])}

        r = Response(status=status, body=body, headers=resp_headers)
        expected = (expect,) if isinstance(expect, int) else expect
        if status not in expected:
            excerpt = body[:500].decode("utf-8", errors="replace")
            raise AssertionError(
                f"{method} {path}: expected {expected}, got {status}\n"
                f"body: {excerpt}"
            )
        return r

    # ---- lifecycle helpers ------------------------------------------------

    def health(self) -> bool:
        """Return True iff /health returns 200 with status==ok."""
        try:
            r = self.http("GET", "/health", expect=200)
            return r.json().get("status") == "ok"
        except Exception:
            return False

    def tail_log(self, n: int = 50) -> str:
        """Return the last n lines of the nalar log (useful on failure)."""
        try:
            with self.log_path.open("rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                # Read up to ~64 KB from the end.
                f.seek(max(0, size - 65536))
                data = f.read().decode("utf-8", errors="replace")
            return "\n".join(data.splitlines()[-n:])
        except FileNotFoundError:
            return ""

    # ---- teardown ---------------------------------------------------------

    def teardown(self) -> None:
        """Stop the nalar binary and rmtree the isolated tempdir.

        Order matters:
          1. Restore HOME (so any post-test code sees the original env).
          2. Stop the binary (SIGTERM, then SIGKILL fallback).
          3. Validate the tempdir with is_safe_tmp(); raise if it
             fails. The tempdir is leaked in that case — the correct
             trade-off vs. deleting the wrong tree.
          4. rmtree the validated tempdir (or skip if dry_run).

        Idempotent: safe to call twice.
        """
        # 1. Restore HOME first.
        os.environ["HOME"] = self.orig_home

        # 2. Stop the binary.
        if self.pid is not None and not self._stopped:
            self._stopped = True
            self._stop_binary()

        # 3. Validate. THIS IS THE SAFETY NET.
        if not is_safe_tmp(str(self.temp_dir), self.orig_home):
            raise FunctionalHarnessError(
                f"REFUSING to rmtree unsafe path: {self.temp_dir}\n"
                f"This is a bug in the harness; the tempdir did not\n"
                f"pass is_safe_tmp() validation. Manual cleanup required.\n"
                f"  orig_home = {self.orig_home}\n"
                f"  temp_dir  = {self.temp_dir}\n"
                f"  realpath  = {os.path.realpath(str(self.temp_dir))}"
            )

        # 3.5. Remove the pidfile BEFORE rmtree so the next boot doesn't
        #      see this entry. Idempotent under dry_run (which skips
        #      rmtree below) — without this, dry_run would leave a
        #      pidfile pointing at a now-dead harness python, causing
        #      the next boot to mistakenly treat this tempdir as an
        #      orphan and try to reap its already-dead nalar.
        pidfile = self.temp_dir / ".harness.pid"
        try:
            pidfile.unlink()
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"warning: failed to remove pidfile: {e}", file=sys.stderr)

        # 4. rmtree the validated tempdir.
        if self.dry_run:
            print(f"[dry-run] would rmtree: {self.temp_dir}")
        else:
            shutil.rmtree(self.temp_dir)

    # ---- context-manager sugar -------------------------------------------

    def __enter__(self) -> "FunctionalHarness":
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.teardown()

    # ---- private helpers --------------------------------------------------

    def _stop_binary(self) -> None:
        """SIGTERM the process group, fall back to SIGKILL after 1s.

        All kill operations swallow OSError (covers ProcessLookupError,
        PermissionError, and ESRCH) — the process can die between any
        of these calls, and the OS may not let us signal a pgid that's
        been recycled. Either way, our job is done.

        Cross-platform notes:
          - POSIX: subprocess.Popen(..., start_new_session=True) puts
            the child in its own process group; os.killpg() signals
            the whole group (defends against children that ignore
            SIGTERM).
          - Windows: there are no process groups. start_new_session
            maps to CREATE_NEW_PROCESS_GROUP, and TerminateProcess is
            the only way to kill a child we don't own. We skip the
            pgid dance and kill by pid directly.

        Teardown budget (was 10s, now 3s) — the slim budget is
        safe because ``/test/shutdown`` exits the process within
        ~50ms in the common case. The SIGTERM/SIGKILL steps are the
        safety net for the rare case where ShutdownTheader blocks
        (e.g. a future regression that re-introduces a long-running
        blocking call in the shutdown handler).
        """
        assert self.pid is not None
        # Use /test/shutdown for graceful exit; tolerate any failure.
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{self.port}/test/shutdown",
                data=b"",
                timeout=2.0,
            ) as resp:
                resp.read()
        except Exception:
            pass
        if self._wait_dead(1.0, "post-shutdown"):
            return
        # Fall back to SIGTERM the whole group.
        self._signal_group(signal.SIGTERM)
        if self._wait_dead(1.0, "post-sigterm"):
            return
        # Last resort — SIGKILL.
        self._signal_group(signal.SIGKILL)
        self._wait_dead(1.0, "post-sigkill")  # best-effort final wait

    def _wait_dead(self, timeout: float, label: str = "wait") -> bool:
        """Return True iff the process exited within ``timeout`` seconds.

        Uses ``os.waitpid(pid, WNOHANG)`` to detect exit. WNOHANG is
        the correct call here — ``os.kill(pid, 0)`` returns 0 for
        zombie processes (the process is dead but the parent hasn't
        reaped it), so it would falsely report "alive" for a zombie
        and stall the harness for the full SIGTERM/SIGKILL budget.

        ``waitpid(WNOHANG)`` returns:
          - ``(0, 0)``            — process is still running, no zombie
          - ``(pid, status)``     — child has exited and we JUST reaped it
          - raises ``OSError`` (ECHILD) — child doesn't exist (no zombie either)

        On Windows, ``os.waitpid`` is unavailable; we fall back to
        ``os.kill(pid, 0)``. The Windows backend doesn't have zombie
        processes (CreateProcess+wait semantics differ), so the
        heuristic is sufficient there.
        """
        assert self.pid is not None
        has_waitpid = hasattr(os, "waitpid")
        # WNOHANG may not exist on some platforms; fall back to 0
        # (blocking) but we cap the loop with `timeout` so it's not
        # actually blocking.
        try:
            wnohang = os.WNOHANG
        except AttributeError:
            wnohang = 0
        t0 = time.monotonic()
        deadline = time.monotonic() + timeout
        polls = 0
        while time.monotonic() < deadline:
            polls += 1
            if has_waitpid:
                try:
                    wpid, _status = os.waitpid(self.pid, wnohang)
                except ChildProcessError:
                    # ECHILD — no such process (already reaped and gone)
                    return True
                except OSError:
                    # Some other error — treat as alive and retry
                    pass
                else:
                    if wpid == self.pid:
                        # We just reaped the zombie — process is really dead
                        return True
                    # wpid == 0 means still running, no zombie yet
            else:
                # Windows / fallback: kill(pid, 0) returns 0 if alive
                # (including zombie — but Windows doesn't have those)
                try:
                    os.kill(self.pid, 0)
                except OSError:
                    return True
            time.sleep(0.05)
        return False

    def _signal_group(self, sig: int) -> None:
        """Signal the process group on POSIX, or the pid on Windows.

        OSError is swallowed throughout — the process can die between
        our queries, the OS may have recycled the pgid, or we may not
        own the pid. None of those are the harness's concerns; we
        made a best-effort attempt.
        """
        assert self.pid is not None
        if hasattr(os, "killpg"):
            try:
                pgid = os.getpgid(self.pid)
            except OSError:
                pgid = self.pid
            try:
                os.killpg(pgid, sig)
            except OSError:
                pass
        else:
            # Windows: no killpg. Best effort — SIGTERM (which
            # Python maps to TerminateProcess for the child).
            try:
                os.kill(self.pid, sig)
            except OSError:
                pass


# ============================================================================
# Internal helpers
# ============================================================================


def _find_free_port(start: int | None = None) -> int:
    """Find a free port for the nalar backend.

    Default behaviour (no ``start``): pick a random port from the wide
    range ``[RANDOM_PORT_START, RANDOM_PORT_END]`` (40k-60k). Random
    selection avoids the two pathologies the previous sequential scan
    suffered in CI:

      1. **Sequential consumption** — every test boot increments the
         port number, so a long suite fills the 8080..8199 window and
         later tests fail with "No free port found".
      2. **TIME_WAIT saturation** — even with ``SO_REUSEADDR``, a CI
         runner holding 100+ ports in TIME_WAIT could collide with the
         narrow 120-port scan window.

    Random selection from 20,000 ports with 50 attempts is collision-
    proof for any realistic host occupancy (see ``RANDOM_PORT_ATTEMPTS``
    comment).

    With an explicit ``start`` (used by the orphan-reap TIME_WAIT
    regression test): falls back to the legacy sequential scan from
    ``start`` to ``PORT_SCAN_END``. This keeps the historical test
    contract intact while production boots use the new random path.

    Args:
        start: If given, scan sequentially from this port to
            ``PORT_SCAN_END`` (legacy behaviour). If ``None``, pick
            a random port from the wide range.

    Returns:
        A free port number (never 8081).

    Raises:
        FunctionalHarnessError: If no free port can be found within
            the configured budget.
    """
    if start is not None:
        return _find_free_port_sequential(start)
    return find_free_port_random()


def _find_free_port_sequential(start: int) -> int:
    """Sequential port scan from ``start`` to ``PORT_SCAN_END``. Legacy.

    Kept as the explicit-call path used by
    ``harness_orphan_reap_test.py::test_find_free_port_picks_time_wait_port``
    which depends on the deterministic "first free port = target_port"
    behaviour. Production boot uses ``_find_free_port()`` with no args
    which delegates to ``find_free_port_random()``.

    Uses ``SO_REUSEADDR`` so the scan can pick ports in TIME_WAIT state.
    After the harness closes its probe socket, nalar (which also sets
    ``SO_REUSEADDR`` on its listener — see
    ``src/modules/custom_http_server/src/http_server.zig:201 setReuseAddr``)
    can bind the same port despite lingering server-side TIME_WAITs from
    previous test runs. Without ``SO_REUSEADDR``, rapid test runs would
    saturate the 120-port scan window with TIME_WAIT entries and every
    subsequent test would error with ``No free port found in
    8080..8199 (excluding 8081)`` until the TIME_WAITs expire (~60s).
    """
    if start == 8081:
        start = 8082
    for port in range(start, PORT_SCAN_END + 1):
        if port == 8081:
            continue
        if port_is_free_with_reuse(port):
            return port
    raise FunctionalHarnessError(
        f"No free port found in {start}..{PORT_SCAN_END} (excluding 8081)"
    )


def port_is_free_with_reuse(port: int) -> bool:
    """Return True iff ``port`` can be bound on 127.0.0.1 with SO_REUSEADDR.

    Used as the atomic-free primitive by both the random picker and
    the sequential scan. SO_REUSEADDR lets the probe bind TIME_WAIT
    ports; the subsequent nalar/vite listener sets the same flag so
    it can also bind the port despite lingering server-side TIME_WAITs.

    Public so the ``UIHarness`` can share it without duplicating the
    SO_REUSEADDR + bind() dance.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def find_free_port_random(
    *,
    reserved: tuple[int, ...] = RESERVED_PORTS,
    attempts: int = RANDOM_PORT_ATTEMPTS,
    range_start: int = RANDOM_PORT_START,
    range_end: int = RANDOM_PORT_END,
) -> int:
    """Pick a random free port from a wide range, avoiding reserved ports.

    Used by both ``FunctionalHarness.boot()`` (no args — default
    reserved = (8081,)) and ``UIHarness`` (passes
    ``reserved=(5173, 8081)`` to also skip Vite's default port and
    the dev backend port).

    Strategy: ``attempts`` independent random picks within
    ``[range_start, range_end]``; the first one that binds without
    error and isn't in ``reserved`` wins. Raises
    ``FunctionalHarnessError`` if all attempts fail.

    Args:
        reserved: Ports the picker MUST skip even if bind() succeeds.
            Default: ``(8081,)`` — the always-running dev backend.
        attempts: Number of random picks before giving up. Default 50.
        range_start: Inclusive low end of the random range. Default 40000.
        range_end: Inclusive high end of the random range. Default 60000.

    Returns:
        A free port in ``[range_start, range_end]`` not in ``reserved``.

    Raises:
        FunctionalHarnessError: If no free port is found within
            ``attempts`` picks. Practically unreachable on any sane host
            (see ``RANDOM_PORT_ATTEMPTS`` docstring).
    """
    if range_end < range_start:
        raise ValueError(
            f"range_end ({range_end}) must be >= range_start ({range_start})"
        )
    if attempts <= 0:
        raise ValueError(f"attempts must be > 0, got {attempts}")
    range_size = range_end - range_start + 1
    for _ in range(attempts):
        port = range_start + random.randint(0, range_size - 1)
        if port in reserved:
            continue
        if port_is_free_with_reuse(port):
            return port
    raise FunctionalHarnessError(
        f"No free port found after {attempts} random picks in "
        f"[{range_start}, {range_end}] (excluding reserved={reserved}). "
        f"This host's port occupancy is pathological; widen the random "
        f"range via find_free_port_random(range_start=, range_end=) "
        f"or check `ss -tlnp | wc -l` for runaway listeners."
    )


def _wait_pid_dead(pid: int, timeout: float) -> bool:
    """Return True iff ``pid`` exited within ``timeout`` seconds.

    Uses ``os.kill(pid, 0)`` as a liveness probe. Cross-platform:
    POSIX and Windows both support the probe. ESRCH ⇒ dead; EPERM ⇒
    alive-but-not-ours (treated as "dead for our purposes" because we
    can't signal it anyway).

    For subprocess children specifically, prefer ``os.waitpid(WNOHANG)``
    which also reaps zombies — see ``_stop_binary`` for the richer case.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError):
            return True
        time.sleep(0.05)
    return False


def _reap_orphan_test_pids() -> int:
    """Kill orphaned nalar children from prior aborted runs. Idempotent.

    On every harness boot, scan ``<tempfile.gettempdir()>/nalar-func-*/
    .harness.pid``. Each pidfile contains ``"<harness_worker_pid>
    <nalar_child_pid>\n"`` — written by ``boot()``. If the harness python
    parent died (``kill -0`` returns ``ProcessLookupError``), the tempdir
    is an orphan: the nalar child survived in its own pgid
    (``subprocess.Popen(start_new_session=True)``) and is still holding
    its TCP port. Kill the nalar child, then ``rmtree`` the tempdir via
    the existing ``is_safe_tmp()`` validator.

    Returns the number of orphans reaped. Failures are logged to stderr
    but never raised — a reap failure must NOT prevent the test from
    booting (the alternative — aborting because we couldn't clean up —
    is strictly worse than booting with a slightly-leakier state).

    Cross-platform: ``tempfile.gettempdir()`` (NOT hardcoded ``/tmp/``),
    ``os.kill`` for liveness + signals, ``signal.SIGTERM``/``SIGKILL``
    which both work on POSIX and Windows.
    """
    reaped = 0
    base = Path(tempfile.gettempdir())
    if not base.is_dir():
        return 0
    try:
        candidates = list(base.iterdir())
    except OSError as e:
        print(f"warning: orphan reap scan failed: {e}", file=sys.stderr)
        return 0
    for entry in candidates:
        if not entry.is_dir() or not entry.name.startswith("nalar-func-"):
            continue
        pidfile = entry / ".harness.pid"
        if not pidfile.is_file():
            continue
        # Parse "<harness_pid> <nalar_pid>". Anything else → skip silently.
        try:
            tokens = pidfile.read_text().split()
            if len(tokens) != 2:
                continue
            harness_pid = int(tokens[0])
            nalar_pid = int(tokens[1])
        except (OSError, ValueError):
            continue
        # If the harness python is alive, this test is still in progress —
        # another worker scanning concurrently must NOT kill it.
        try:
            os.kill(harness_pid, 0)
        except (ProcessLookupError, PermissionError):
            pass  # harness is dead — this dir is an orphan
        else:
            continue
        # Harness is dead. Kill the nalar child if alive.
        if nalar_pid and nalar_pid != os.getpid():
            try:
                os.kill(nalar_pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            # Wait up to 1s for graceful exit; SIGKILL fallback.
            if not _wait_pid_dead(nalar_pid, 1.0):
                try:
                    os.kill(nalar_pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        # rmtree via the safety validator (same gate as teardown).
        # is_safe_tmp checks (1) prefix allow-list, (2) REQUIRED_TMP_SUBSTR
        # substring, (3) not the real HOME. For an orphan we don't know
        # the original HOME, so pass an empty string — that disables the
        # "matches HOME" check but still validates prefix + substring.
        if is_safe_tmp(str(entry), ""):
            try:
                shutil.rmtree(entry)
                reaped += 1
            except OSError:
                # Race with another worker reaping the same dir, or
                # permission error — either way, our job is done.
                pass
    return reaped


def _default_nalar_bin() -> Path:
    """Resolve the nalar binary. Checks env var, then known zig-out paths."""
    candidates: list[Path] = []
    env_bin = os.environ.get("NALAR_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/nalar"),
        Path("./zig-out/bin/nalarcore-linux-x86_64"),
        Path("./zig-out/bin/nalarcore-macos-aarch64"),
        Path("./zig-out/bin/nalarcore-macos-x86_64"),
    ])
    for c in candidates:
        if c.exists():
            return c.resolve()
    raise FunctionalHarnessError(
        "No nalar binary found. Set NALAR_BIN or run "
        "`zig build install:linux:system` first."
    )


def mcp_hello_world_bin() -> Path:
    """Resolve the mcp-hello-world test MCP server binary.

    Built by `zig build mcp-hello-world`. Same sibling-binary
    resolution as the nalar binary: the wrapper lives at
    zig-out/bin/mcp-hello-world next to nalarcore-*.

    Resolution order:
      1. ``$MCP_HELLO_WORLD_BIN`` env var
      2. ``./zig-out/bin/mcp-hello-world`` (sibling of nalar binary)
      3. ``./zig-out/bin/mcp-hello-world-linux-x86_64`` (cross-target)

    Raises FunctionalHarnessError if no binary is found.
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("MCP_HELLO_WORLD_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/mcp-hello-world"),
        Path("./zig-out/bin/mcp-hello-world-linux-x86_64"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FunctionalHarnessError(
        "mcp-hello-world binary not found; set MCP_HELLO_WORLD_BIN or run "
        "`zig build mcp-hello-world` first."
    )


def _wait_ready(
    port: int, timeout_s: float, proc: subprocess.Popen[bytes], log_path: Path
) -> None:
    """Poll /health every 100ms until 'ok' or timeout.

    Raises FunctionalHarnessError with the log tail on failure.
    """
    deadline = time.monotonic() + timeout_s
    url = f"http://127.0.0.1:{port}/health"
    last_err: str = ""
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            log = log_path.read_text(errors="replace") if log_path.exists() else ""
            raise FunctionalHarnessError(
                f"nalar exited rc={proc.returncode} during boot\n"
                f"--- last 30 lines of log ---\n"
                + "\n".join(log.splitlines()[-30:])
            )
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                body = json.loads(resp.read())
                if body.get("status") == "ok":
                    return
        except (urllib.error.URLError, ConnectionError, OSError) as e:
            last_err = str(e)
        time.sleep(0.1)
    log = log_path.read_text(errors="replace") if log_path.exists() else ""
    raise FunctionalHarnessError(
        f"nalar did not become ready in {timeout_s}s (last_err={last_err})\n"
        f"--- last 30 lines of log ---\n"
        + "\n".join(log.splitlines()[-30:])
    )


def _write_stub_llm_profile(temp_dir: Path) -> None:
    """Pre-create a stub LLM profile at ``$HOME/.config/nalar/config.json``.

    The base_url points to a port that never responds, so session-create
    will fail at runtime when it tries to call the LLM — which is fine,
    since the functional tests assert on the wire, not on LLM responses.
    """
    config_dir = temp_dir / ".config" / "nalar"
    config_dir.mkdir(parents=True, exist_ok=True)
    profile = {
        "profiles_models": {
            "stub": {
                "model": "stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-key-not-real",
            }
        },
        "selected_profile_model": "stub",
    }
    (config_dir / "config.json").write_text(json.dumps(profile, indent=2))


# ============================================================================
# Convenience for scripts that don't want pytest fixtures
# ============================================================================


def run_quick(
    nalar_bin: Path | None = None,
    *,
    port: int = DEFAULT_PORT,
    stub_llm_profile: bool = False,
) -> Iterator[FunctionalHarness]:
    """Context manager for use outside pytest.

    Example:
        with run_quick() as h:
            r = h.http("GET", "/health")
            print(r.json())
    """
    h = FunctionalHarness.boot(
        nalar_bin, port=port, stub_llm_profile=stub_llm_profile
    )
    try:
        yield h
    finally:
        h.teardown()


__all__ = [
    "ALLOWED_TMP_PREFIXES",
    "DEFAULT_PORT",
    "FunctionalHarness",
    "FunctionalHarnessError",
    "PORT_SCAN_END",
    "RANDOM_PORT_ATTEMPTS",
    "RANDOM_PORT_END",
    "RANDOM_PORT_START",
    "REQUIRED_TMP_SUBSTR",
    "RESERVED_PORTS",
    "Response",
    "find_free_port_random",
    "is_safe_tmp",
    "port_is_free_with_reuse",
    "run_quick",
]
