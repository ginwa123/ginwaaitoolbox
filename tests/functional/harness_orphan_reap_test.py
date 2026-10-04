"""Tests for the orphan-pabrik-pid reap step in FunctionalHarness.boot().

When the harness Python is killed unexpectedly (Ctrl+C, ``kill -9``, OOM,
terminal close), its pabrik child survives in its own process group
(``subprocess.Popen(start_new_session=True)``) and continues to hold the
TCP port the test allocated. After ~120 such incidents the harness's
8080..8199 scan window is exhausted and every subsequent test errors at
boot with ``No free port found in 8080..8199 (excluding 8081)``.

These tests cover the reap logic that runs at the top of every ``boot()``
to clean up after prior aborted runs. The reap step:

  1. Scans ``<tempfile.gettempdir()>/pabrik-func-*/.harness.pid``.
  2. For each pidfile, parses ``<harness_pid> <pabrik_pid>``.
  3. If ``harness_pid`` is no longer alive, the dir is orphaned — kill
     ``pabrik_pid`` (SIGTERM → wait 1s → SIGKILL) and ``rmtree`` the dir
     via the existing ``is_safe_tmp()`` safety validator.

These tests run WITHOUT a real pabrik binary. The "pabrik" pid is just a
long-lived Python sleeper spawned with ``start_new_session=True`` to
mimic the pabrik spawn pattern.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

from harness import (
    FunctionalHarness,
    REQUIRED_TMP_SUBSTR,
    _pid_is_alive,
    _reap_orphan_test_pids,  # added by the patch — see test_boot_writes_pidfile
)


# ============================================================================
# Helpers
# ============================================================================


def _spawn_long_lived_child() -> subprocess.Popen[bytes]:
    """Spawn a 60-second sleeper in its own process group, like pabrik.

    Returns the Popen handle. Caller must call ``.kill()`` if the test
    fails before reap does.
    """
    return subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _pid_alive(pid: int) -> bool:
    """Return True iff ``pid`` names a live process.

    Delegates to the harness's own probe rather than repeating an
    ``os.kill(pid, 0)`` here. That call cannot answer the question on
    Windows: it raises ``[WinError 87]`` for a pid that never existed (so
    "dead" happens to be right) but returns cleanly for a pid that has
    already exited (so a dead nalar reads as alive). The harness now
    probes with OpenProcess/WaitForSingleObject, and a test that graded
    the reaper against a different, weaker definition of "alive" would
    quietly stop testing what ships.
    """
    return _pid_is_alive(pid)


def _pid_state(pid: int) -> str | None:
    """Return the /proc/<pid>/status State field, or None if pid is gone.

    Values: R (running), S (sleeping), D (disk sleep), Z (zombie),
    T (stopped), X (dead). Returns None when ESRCH (no such process).
    """
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("State:"):
                    # "State:\tZ (zombie)" → "Z"
                    parts = line.split()
                    return parts[1] if len(parts) > 1 else None
    except (FileNotFoundError, ProcessLookupError):
        return None
    return None


def _force_kill_child(child: subprocess.Popen[bytes]) -> None:
    """Best-effort SIGKILL for cleanup. Used as a last resort in finally."""
    # Windows has no signal.SIGKILL (AttributeError on access); SIGTERM
    # maps to TerminateProcess there, which is the same last-resort
    # semantic.
    sig = getattr(signal, "SIGKILL", signal.SIGTERM)
    try:
        os.kill(child.pid, sig)
    except OSError:
        # Already dead (POSIX ESRCH) or Windows [WinError 87]. Either way
        # there is nothing to kill; swallowing here keeps finally-blocks
        # from masking the test result.
        pass


def _make_orphan_marker(temp_dir: Path, harness_pid: int, pabrik_pid: int) -> None:
    """Write the pidfile as boot() would."""
    (temp_dir / ".harness.pid").write_text(f"{harness_pid} {pabrik_pid}\n")


def _reap_child_zombie(child: subprocess.Popen[bytes], timeout: float = 2.0) -> None:
    """waitpid() a child so its zombie status is cleared.

    After reap() kills the pabrik child, the child becomes a zombie
    (state=Z) until its parent (the test runner, via Popen) calls
    waitpid. Without this, a liveness probe keeps reporting "alive"
    even though reap's job is done.
    """
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass  # reap didn't kill it — leave as-is


def _rmtree_retry(path: Path, attempts: int = 10, delay_s: float = 0.5) -> None:
    """rmtree with backoff for Windows' transient post-exit file locks.

    After teardown() stops the fake-pabrik tree, pabrik.log can stay
    locked for ~0.5s even though both processes are dead (verified via
    tasklist: no cmd.exe/python.exe survivor — the OS/AV releases the
    redirected-stdout handle asynchronously). The harness's own
    teardown rmtree already retries for exactly this; manual cleanups
    in tests need the same treatment. POSIX never hits it (unlink
    works on open files), so the loop is a single fast pass there.
    """
    last: OSError | None = None
    for _ in range(attempts):
        try:
            import shutil
            shutil.rmtree(path)
            return
        except OSError as e:
            last = e
            time.sleep(delay_s)
    assert last is not None  # attempts >= 1, so last is always set
    raise last


# ============================================================================
# Task 1: _reap_orphan_test_pids kills an orphan pabrik pid + rmtree's its dir
# ============================================================================


def test_reap_kills_orphan_pabrik_and_removes_dir() -> None:
    """A stale pidfile whose harness parent is dead → reap kills the pabrik
    child and rmtree's the tempdir.

    This is the exact failure mode the user hit on 2026-08-23: a prior
    ``pytest -n auto`` run was killed -9, the workers died, the pabrik
    children survived in their own pgids, and every subsequent test
    errored at boot with "No free port found in 8080..8199".
    """
    child = _spawn_long_lived_child()
    assert _pid_alive(child.pid), "child should be alive right after spawn"

    # Create a fake orphan tempdir under tempfile.gettempdir() so the
    # reap scan finds it. Use the safety substring so is_safe_tmp accepts.
    temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    _make_orphan_marker(temp_dir, harness_pid=0, pabrik_pid=child.pid)

    try:
        # PID 0 is special on Linux (kernel's idle task / swapper). It
        # is always "alive" in the sense that kill -0 won't raise ESRCH
        # for PID 0 in some contexts. To be safe, use a PID we know is
        # dead: spawn a sleeper, kill it, wait for reap, then reuse
        # that PID. (Cheaper: use os.kill on a high number that we
        # verify is dead first.)
        # Simplest correct path: create a real sub-process, kill it,
        # waitpid it (so it's not a zombie — waitpid is the only way
        # to make the OS mark a pid as truly gone), then use it.
        #
        # Windows exception: a terminated child's process handle stays
        # open in the parent (Popen._active/finalizer), so os.kill()
        # keeps reporting "alive" even after wait()+del+gc (verified
        # empirically). Instead use a never-assigned pid above
        # Windows' max pid (2^22): OpenProcess deterministically
        # fails, which is exactly the "harness dead" signal reap
        # keys on (os.kill raising of any kind).
        if sys.platform == "win32":
            dead_pid = 99_999_999
            assert not _pid_alive(dead_pid), "never-assigned pid must read dead"
        else:
            dead_pid_proc = subprocess.Popen(
                [sys.executable, "-c", "pass"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            dead_pid_proc.wait(timeout=5.0)
            dead_pid = dead_pid_proc.pid
        # Rewrite the pidfile with the dead PID as the "harness parent".
        _make_orphan_marker(temp_dir, harness_pid=dead_pid, pabrik_pid=child.pid)

        # Sanity check: dead_pid is gone, child is alive, dir exists.
        assert not _pid_alive(dead_pid), "dead_pid should not be alive"
        assert _pid_alive(child.pid), "child should be alive before reap"
        assert temp_dir.is_dir()

        # Act.
        reaped = _reap_orphan_test_pids()

        # Reap the zombie via the test runner (Popen is the parent).
        _reap_child_zombie(child)

        # Assert: child killed, dir removed, count reported.
        assert reaped >= 1, "reap should report at least one orphan reaped"
        assert child.returncode is not None, (
            "child.wait() must have returned — reap killed it but didn't reap the zombie"
        )
        assert not temp_dir.exists(), "orphan tempdir should be rmtree'd"
    finally:
        _force_kill_child(child)


# ============================================================================
# Task 3: edge cases
# ============================================================================


def test_reap_idempotent_when_no_orphans() -> None:
    """Calling reap twice with no orphans is safe; second call is a no-op."""
    # First call on a clean tree.
    assert _reap_orphan_test_pids() >= 0
    # Second call immediately after.
    assert _reap_orphan_test_pids() >= 0


def test_reap_skips_live_harness() -> None:
    """A pidfile whose harness parent is alive is NOT reaped.

    This is the cross-xdist safety case: worker A scanning for orphans
    must NOT kill worker B's live test's pabrik child.
    """
    child = _spawn_long_lived_child()
    temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    # Mark our own process (the test runner) as the harness parent — we
    # are alive, so reap must skip this entry.
    _make_orphan_marker(temp_dir, harness_pid=os.getpid(), pabrik_pid=child.pid)

    try:
        _reap_orphan_test_pids()
        # Child is still alive.
        assert _pid_alive(child.pid), "child must NOT be killed when harness is alive"
        assert temp_dir.is_dir(), "tempdir must NOT be rmtree'd when harness is alive"
    finally:
        _force_kill_child(child)
        _reap_child_zombie(child)
        # Manual cleanup of the tempdir (it survived reap).
        if temp_dir.is_dir():
            import shutil
            shutil.rmtree(temp_dir)


def test_reap_skips_malformed_pidfile() -> None:
    """A pidfile with garbage content is silently skipped; tempdir untouched."""
    temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    try:
        (temp_dir / ".harness.pid").write_text("garbage-not-pids\n")
        # Should not raise, should not rmtree.
        _reap_orphan_test_pids()
        assert temp_dir.is_dir(), "malformed pidfile must not trigger rmtree"
    finally:
        import shutil
        shutil.rmtree(temp_dir)


def test_reap_skips_empty_pidfile() -> None:
    """An empty pidfile is silently skipped; tempdir untouched."""
    temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    try:
        (temp_dir / ".harness.pid").write_text("")
        _reap_orphan_test_pids()
        assert temp_dir.is_dir()
    finally:
        import shutil
        shutil.rmtree(temp_dir)


# ============================================================================
# Task 2: boot() writes the pidfile and teardown() removes it
# ============================================================================


@pytest.fixture
def built_pabrik(tmp_path: Path) -> Path:
    """Path to a fake-but-executable pabrik binary that boots on the given port.

    The fake binary binds the requested port (with SO_REUSEADDR so it can
    bind TIME_WAIT ports just like real pabrik), prints '{"status":"ok"}'
    on /health, exits 0 on /test/shutdown (so teardown()'s graceful
    path works), and sleeps forever otherwise — sufficient for the
    boot pidfile test which only needs the harness to reach the
    post-Popen state.
    """
    port_env_file = tmp_path / "port"
    fake = tmp_path / "fake-pabrik"
    fake.write_text(
        "#!/usr/bin/env python3\n"
        "import http.server, socketserver, sys, json, os, signal\n"
        "port = int(sys.argv[2])\n"
        "open(" + repr(str(port_env_file)) + ", 'w').write(str(port))\n"
        "class H(http.server.BaseHTTPRequestHandler):\n"
        "    def do_GET(self):\n"
        "        if self.path == '/health':\n"
        "            self.send_response(200)\n"
        "            self.send_header('Content-Type','application/json')\n"
        "            self.end_headers()\n"
        "            self.wfile.write(b'{\"status\":\"ok\"}')\n"
        "        elif self.path == '/test/shutdown':\n"
        "            self.send_response(200)\n"
        "            self.end_headers()\n"
        "            try:\n"
        "                self.wfile.write(b'bye')\n"
        "                self.wfile.flush()\n"
        "            except Exception:\n"
        "                pass\n"
        "            os._exit(0)\n"
        "        else:\n"
        "            self.send_response(404); self.end_headers()\n"
        "    def do_POST(self):\n"
        "        # The real binary serves POST /test/shutdown (main.zig)\n"
        "        # and the harness's graceful path sends POST. Without\n"
        "        # this the fake 501s the shutdown; on Windows teardown\n"
        "        # then SIGTERMs only the .cmd wrapper, orphaning the\n"
        "        # python grandchild that holds pabrik.log open\n"
        "        # (rmtree fails with PermissionError [WinError 32]). POSIX masks\n"
        "        # this because killpg takes the whole group (and unlink\n"
        "        # works on open files there).\n"
        "        if self.path == '/test/shutdown':\n"
        "            self.send_response(200)\n"
        "            self.end_headers()\n"
        "            try:\n"
        "                self.wfile.write(b'bye')\n"
        "                self.wfile.flush()\n"
        "            except Exception:\n"
        "                pass\n"
        "            os._exit(0)\n"
        "        else:\n"
        "            self.send_response(404); self.end_headers()\n"
        "    def log_message(self, *a, **k): pass\n"
        "class ReusableServer(socketserver.TCPServer):\n"
        "    allow_reuse_address = True\n"
        "with ReusableServer(('127.0.0.1', port), H) as srv:\n"
        "    srv.serve_forever()\n"
    )
    fake.chmod(0o755)
    if sys.platform == "win32":
        # Windows CreateProcess cannot execute a shebang script
        # directly ([WinError 193] "%1 is not a valid Win32
        # application"). Launch it through a .cmd wrapper, which
        # CreateProcess dispatches via cmd.exe automatically
        # (verified empirically: Popen(["x.cmd"]) works, Popen on
        # the .py itself raises 193). The wrapper forwards argv
        # (%*) so boot()'s `--port <n>` reaches the script.
        # NOTE: /test/shutdown above exits the python grandchild
        # via os._exit so teardown()'s graceful path releases the
        # log file; killing the cmd wrapper alone would orphan the
        # grandchild and block rmtree with PermissionError.
        launcher = tmp_path / "fake-pabrik.cmd"
        launcher.write_text(
            '@"%s" "%s" %%*\r\n' % (sys.executable, fake),
            encoding="ascii",
        )
        return launcher
    return fake


def test_boot_writes_pidfile_with_both_pids(
    built_pabrik: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """boot() writes <harness_pid> <pabrik_pid> to <tempdir>/.harness.pid."""
    # Use a per-test HOME so is_safe_tmp doesn't see the dev's HOME.
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("PABRIK_BIN", str(built_pabrik))

    h = FunctionalHarness.boot(built_pabrik)
    try:
        pidfile = h.temp_dir / ".harness.pid"
        assert pidfile.is_file(), "boot() must write the pidfile"
        content = pidfile.read_text().strip().split()
        assert len(content) == 2, f"pidfile must have 2 tokens, got: {content!r}"
        assert int(content[0]) == os.getpid(), "first pid must be the harness python"
        assert int(content[1]) == h.pid, "second pid must be the pabrik child"
    finally:
        h.teardown()


def test_teardown_removes_pidfile(
    built_pabrik: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """teardown() removes the pidfile before rmtree'ing the tempdir.

    Without this, a dry-run teardown would leave the pidfile behind and
    a subsequent boot would (incorrectly) see the tempdir as orphaned.
    """
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("PABRIK_BIN", str(built_pabrik))

    h = FunctionalHarness.boot(built_pabrik)
    pidfile = h.temp_dir / ".harness.pid"
    assert pidfile.is_file()
    h.teardown()
    # After teardown, the tempdir is gone (rmtree'd).
    assert not h.temp_dir.exists(), "tempdir should be rmtree'd by teardown"


def test_teardown_dry_run_removes_pidfile(
    built_pabrik: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Under PABRIK_FUNCTIONAL_DRY_RUN=1, teardown skips rmtree but still
    removes the pidfile so the next boot doesn't reap this entry."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("PABRIK_BIN", str(built_pabrik))
    monkeypatch.setenv("PABRIK_FUNCTIONAL_DRY_RUN", "1")

    h = FunctionalHarness.boot(built_pabrik)
    pidfile = h.temp_dir / ".harness.pid"
    assert pidfile.is_file()
    h.teardown()
    # Tempdir survives (dry_run) but pidfile is gone.
    assert h.temp_dir.is_dir(), "dry_run keeps the tempdir"
    assert not pidfile.exists(), "dry_run teardown must remove the pidfile"
    # Manual cleanup since dry_run skipped rmtree. Retry: pabrik.log can
    # stay transiently locked just after teardown on Windows (see
    # _rmtree_retry) — the harness's own rmtree path already retries.
    _rmtree_retry(h.temp_dir)


# ============================================================================
# Task 4: TIME_WAIT saturation regression (find_free_port uses SO_REUSEADDR)
# ============================================================================


def test_find_free_port_picks_time_wait_port() -> None:
    """_find_free_port uses SO_REUSEADDR so it can scan past TIME_WAIT.

    Regression for the 2026-08-23 failure where rapid test runs saturated
    the 8080..8199 scan window with server-side TIME_WAITs (last ~60s),
    causing every subsequent test to error with 'No free port found'.
    The harness's scan socket now sets SO_REUSEADDR — the same option
    pabrik's listener already uses — so the scan can pick ports in
    TIME_WAIT state and pabrik can subsequently bind them.
    """
    from harness import _find_free_port, DEFAULT_PORT, PORT_SCAN_END

    # Find a port that's currently FREE on this host (avoid the dev's 8081
    # and don't assume 8080 is free — earlier tests may have left it bound).
    target_port = None
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        for p in range(DEFAULT_PORT, PORT_SCAN_END + 1):
            if p == 8081:
                continue
            try:
                probe.bind(("127.0.0.1", p))
            except OSError:
                continue
            target_port = p
            break
    if target_port is None:
        pytest.skip("no free port available to seed TIME_WAIT")

    # Create a server-side TIME_WAIT on target_port: bind a listener,
    # accept a connection, close from the server side (which puts the
    # server's port into TIME_WAIT), then close everything else.
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", target_port))
    srv.listen(1)
    cli = socket.socket()
    cli.connect(("127.0.0.1", target_port))
    conn, _ = srv.accept()
    conn.close()  # server-side close → server-side TIME_WAIT on target_port
    srv.close()
    cli.close()
    time.sleep(0.1)  # let the kernel register the TIME_WAIT

    # Sanity: without SO_REUSEADDR, bind() should now FAIL on target_port
    # (proves we actually have a TIME_WAIT to test against).
    sanity = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sanity.bind(("127.0.0.1", target_port))
        sanity.close()
        pytest.skip(
            f"could not seed a TIME_WAIT on {target_port} "
            f"(kernel bind succeeded → no TIME_WAIT)"
        )
    except OSError:
        pass  # expected — TIME_WAIT blocks the bind

    # _find_free_port must succeed despite the TIME_WAIT.
    # Use target_port as the start so it's the first candidate.
    found = _find_free_port(start=target_port)
    assert found == target_port, (
        f"scan must pick {target_port} despite its TIME_WAIT; "
        f"got {found} (SO_REUSEADDR not set?)"
    )
