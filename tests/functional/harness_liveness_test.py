"""Regression guards for the harness's process-liveness probe.

These are the tests that should have caught the windows-2022 functional
suite never completing. The failure was invisible from any single test:
`FunctionalHarness._wait_dead` answered "the server is dead" for a server
that was very much running, so

  * `shutil.rmtree` raised `PermissionError: [WinError 32]` because nalar
    still held `agent.db`,
  * every teardown burned the full 10 x 1s retry budget before re-raising
    (10 seconds per test), and
  * the server was never actually killed, so instances accumulated for the
    rest of the shard — which is what turned a ~2.7 s/test suite into
    ~44 s/test and pushed all three Windows shards past their timeout.

Nothing here boots nalar. The property under test is "does the probe tell
the truth about a process it spawned", so the child is a short-lived
Python process and every case runs in well under a second.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time

import pytest

# Imported lazily inside each test rather than at module scope: on the
# pre-fix harness.py these names do not exist, and a module-level import
# would turn "the guard fired" into a collection ERROR (exit 2) instead of
# a named assertion failure — which reads like a broken test file rather
# than a detected regression.


def _pid_is_alive(pid: int) -> bool:
    from harness import _pid_is_alive as impl

    return impl(pid)


def _wait_pid_dead(pid: int, timeout: float) -> bool:
    from harness import _wait_pid_dead as impl

    return impl(pid, timeout)


def _spawn_sleeper(seconds: float = 30.0) -> subprocess.Popen:
    """A child that is definitely alive and definitely not exiting."""
    return subprocess.Popen(
        [sys.executable, "-c", f"import time; time.sleep({seconds})"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class TestPidIsAlive:
    def test_reports_a_running_child_as_alive(self) -> None:
        p = _spawn_sleeper()
        try:
            assert _pid_is_alive(p.pid) is True
        finally:
            p.kill()
            p.wait()

    def test_reports_a_reaped_child_as_dead(self) -> None:
        p = _spawn_sleeper()
        p.kill()
        p.wait()
        assert _pid_is_alive(p.pid) is False

    def test_reports_the_current_process_as_alive(self) -> None:
        # The regression case that mattered: the old probe used
        # os.kill(pid, 0), which on Windows cannot tell an exited pid from
        # a live one. os.getpid() can never be dead, so a probe that says
        # otherwise is broken on this platform.
        assert _pid_is_alive(os.getpid()) is True

    @pytest.mark.parametrize("bad", [0, -1, -999])
    def test_rejects_non_positive_pids(self, bad: int) -> None:
        assert _pid_is_alive(bad) is False

    def test_windows_kill_zero_cannot_see_an_exited_pid(self) -> None:
        """Documents WHY the probe cannot be `os.kill(pid, 0)` on Windows.

        Not a test of our code — a test of the assumption the old
        implementation was built on. Measured on CPython 3.11.9/Windows,
        `os.kill(pid, 0)`:

            self / live child / NEVER-EXISTED pid / EXITED child
              -> no exception / no exception / WinError 87 / no exception

        So it does report a never-existed pid as dead, but it reports an
        EXITED pid as still alive — the handle lingers. That is the wrong
        direction for a "wait until it dies" loop, which is exactly what
        `_wait_pid_dead` is. If this ever starts reporting an exited pid as
        dead, `_pid_is_alive_windows` could be simplified to `os.kill`.
        """
        if os.name != "nt":
            pytest.skip("the lingering-handle behaviour is Windows-specific")
        p = _spawn_sleeper()
        try:
            assert _pid_is_alive(p.pid) is True
        finally:
            p.kill()
            p.wait()

        # The probe is right...
        assert _pid_is_alive(p.pid) is False
        # ...and this is the case os.kill gets wrong.
        returned_cleanly = True
        try:
            os.kill(p.pid, 0)
        except OSError:
            returned_cleanly = False
        assert returned_cleanly, (
            "os.kill(exited_pid, 0) now raises on Windows; "
            "_pid_is_alive_windows can be simplified to os.kill"
        )


class TestWaitPidDead:
    def test_does_not_claim_a_live_child_is_dead(self) -> None:
        """The exact defect: a 0.3s budget must expire, not return True."""
        p = _spawn_sleeper()
        try:
            t0 = time.monotonic()
            dead = _wait_pid_dead(p.pid, 0.3)
            elapsed = time.monotonic() - t0
            assert dead is False, (
                "reported a RUNNING child as dead — on Windows the old "
                "os.waitpid path did exactly this (os.WNOHANG is absent "
                "there, so it degenerated to blocking mode and raised "
                "ChildProcessError), and the consequence was rmtree racing "
                "a live nalar"
            )
            # And it must have actually waited out the budget rather than
            # short-circuiting on the first poll.
            assert elapsed >= 0.25, f"returned after {elapsed:.3f}s, not ~0.3s"
        finally:
            p.kill()
            p.wait()

    def test_returns_true_once_the_child_exits(self) -> None:
        p = _spawn_sleeper(seconds=0.1)
        assert _wait_pid_dead(p.pid, 5.0) is True
        p.wait()

    def test_zero_timeout_on_a_live_child_is_false(self) -> None:
        p = _spawn_sleeper()
        try:
            assert _wait_pid_dead(p.pid, 0.0) is False
        finally:
            p.kill()
            p.wait()


class TestWaitDeadUsesThePopenHandle:
    """`_wait_dead` must delegate to `Popen.poll()`, not re-probe the pid.

    Asserted against the SOURCE rather than by booting nalar: the property
    is "we did not reintroduce a hand-rolled liveness probe", and a
    functional test for it would need a real server plus a deliberately
    broken kill path — which is exactly the setup that made this hard to
    diagnose in the first place.
    """

    @staticmethod
    def _wait_dead_node():
        """The `_wait_dead` FunctionDef, found via the AST.

        AST rather than substring matching: `_wait_dead`'s docstring
        *describes* `os.kill(pid, 0)` and `os.waitpid` at length, because
        explaining why they are banned is the whole point of the comment. A
        `"os.kill(" not in source` check therefore fails on its own
        prose. Only real call nodes are inspected.
        """
        import ast
        import harness

        tree = ast.parse(open(harness.__file__, encoding="utf-8").read())
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "_wait_dead":
                return node
        raise AssertionError("FunctionalHarness._wait_dead not found in harness.py")

    @staticmethod
    def _called_names(node) -> set[str]:
        """Every `NAME.attr(...)` / `NAME(...)` called inside `node`."""
        import ast

        names: set[str] = set()
        for sub in ast.walk(node):
            if not isinstance(sub, ast.Call):
                continue
            func = sub.func
            if isinstance(func, ast.Attribute):
                names.add(func.attr)
            elif isinstance(func, ast.Name):
                names.add(func.id)
        return names

    def test_wait_dead_calls_no_liveness_api_other_than_poll(self) -> None:
        node = self._wait_dead_node()
        called = self._called_names(node)
        assert "kill" not in called, (
            "_wait_dead must not hand-roll a liveness probe; "
            "os.kill(pid, 0) cannot see an exited pid on Windows. "
            "Use self._proc.poll()."
        )
        assert "waitpid" not in called, (
            "_wait_dead must not call os.waitpid: os.WNOHANG does not exist "
            "on Windows, so it degenerates to blocking mode and raises "
            "ChildProcessError for a live child — which read as 'dead'."
        )
        assert "poll" in called, (
            "_wait_dead should use the Popen handle's poll(), which is "
            "correct on all three runners."
        )

    def test_boot_stores_the_popen_handle(self) -> None:
        import harness

        src = open(harness.__file__, encoding="utf-8").read()
        assert "_proc: subprocess.Popen" in src, (
            "FunctionalHarness must keep the Popen handle for poll(); "
            "without it _wait_dead has to guess liveness from the pid."
        )

    def test_every_direct_construction_passes_the_popen_handle(self) -> None:
        """`boot()` is not the only way to make a harness.

        `config_simplify_test.py` and `config_tools_test.py` re-implement the
        spawn so they can pre-write a config.json, then call
        `FunctionalHarness(...)` themselves. A construction site that omits
        `_proc` silently drops that harness onto the pid-probe fallback —
        the exact path that was broken on Windows — and nothing else fails.

        `http2_tls_test.py` is a third, and it was found by this guard
        rather than by reading.

        Sites that pass ``pid=None`` are exempt: there is no process to
        track, which is how `harness_safety_test.py` exercises the rmtree
        safety net without booting anything.
        """
        import ast
        import pathlib

        import harness

        tests_dir = pathlib.Path(harness.__file__).parent
        offenders: list[str] = []
        checked = 0
        for path in sorted(tests_dir.glob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                name = (
                    func.id
                    if isinstance(func, ast.Name)
                    else func.attr
                    if isinstance(func, ast.Attribute)
                    else None
                )
                if name != "FunctionalHarness":
                    continue
                kws = {k.arg for k in node.keywords if k.arg}
                if "pid" in kws:
                    # pid=None => nothing was spawned; nothing to poll.
                    pid_node = next(
                        k.value for k in node.keywords if k.arg == "pid"
                    )
                    if isinstance(pid_node, ast.Constant) and pid_node.value is None:
                        continue
                checked += 1
                if "_proc" not in kws:
                    offenders.append(
                        f"{path.name}:{node.lineno} FunctionalHarness(...) "
                        f"without _proc="
                    )
        assert not offenders, (
            "every direct FunctionalHarness(...) that spawns a process must "
            "pass _proc= so _wait_dead can use poll():\n  " + "\n  ".join(offenders)
        )
        assert checked >= 3, (
            f"only found {checked} spawning construction sites — the AST "
            f"walk is probably not matching anymore, so this guard is vacuous"
        )