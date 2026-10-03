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


def _snapshot_parent_env() -> dict[str, str | None]:
    """Lazy alias, for the same reason as the two probes above."""
    from harness import snapshot_parent_env as impl

    return impl()


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

    def test_returns_true_once_the_child_is_reaped(self) -> None:
        """A pid that is gone reports dead — on every platform.

        The child is REAPED (`p.wait()`) before the probe runs, and that is
        load-bearing rather than incidental.

        On POSIX an exited-but-unreaped child is a zombie: the pid still
        exists, so `os.kill(pid, 0)` keeps succeeding and any liveness probe
        built on it correctly reports "alive" until the parent reaps. This
        test asserted the opposite on the first run and went red on both
        `functional Linux` and `functional macOS` while passing on Windows,
        where there is no zombie state and the process handle signals death
        immediately.

        The zombie case is also why this is named after reaping. It is NOT a
        defect: the previous implementation behaved identically on POSIX, and
        nothing in the harness depends on the difference — `_wait_dead`
        asks `Popen.poll()`, which reaps, and the orphan reaper only ever
        looks at children whose parent (the harness) is already dead, so
        init has reaped them. Recorded here because the asymmetry is
        surprising enough to get a test wrong once already.
        """
        p = _spawn_sleeper(seconds=0.1)
        p.wait()
        assert _wait_pid_dead(p.pid, 1.0) is True
        assert _pid_is_alive(p.pid) is False

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

    def test_every_direct_construction_snapshots_the_parent_env(self) -> None:
        """The same guard for the environment, which fails the same way.

        A hand-built harness that omits `_env_backup` cannot tell "APPDATA was
        unset" from "APPDATA was the empty string", so `teardown()` deletes it
        from the parent process. The next module's nalar then dies inside
        `Config.zig:getDefaultConfigPath` — before reaching the code that
        module was testing.

        Measured: after `http2_tls_test.py` ran, the parent process had LOST
        `USERPROFILE`, `APPDATA` and `LOCALAPPDATA` outright, and the next
        module failed on an assertion about a completely different feature
        (`server_port_bind_test` looking for "already in use" in stderr). It
        passes in isolation, so it only ever shows up as an unexplained
        order-dependent CI failure.
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
                    pid_node = next(
                        k.value for k in node.keywords if k.arg == "pid"
                    )
                    if isinstance(pid_node, ast.Constant) and pid_node.value is None:
                        continue
                checked += 1
                if "_env_backup" not in kws:
                    offenders.append(
                        f"{path.name}:{node.lineno} FunctionalHarness(...) "
                        f"without _env_backup=snapshot_parent_env()"
                    )
        assert not offenders, (
            "every direct FunctionalHarness(...) that spawns a process must pass "
            "_env_backup=snapshot_parent_env(), or its teardown() corrupts the "
            "parent environment for every module that runs after it:\n  "
            + "\n  ".join(offenders)
        )
        assert checked >= 3, (
            f"only found {checked} spawning construction sites — the AST "
            f"walk is probably not matching anymore, so this guard is vacuous"
        )


#: Captured once at import, before any test mutates ``os.environ``. Several
#: tests below deliberately overwrite HOME, so `_harness` cannot read the real
#: home from the environment at call time.
_REAL_HOME = os.environ.get("HOME") or os.environ.get("USERPROFILE") or ""


class TestParentEnvIsRestoredExactly:
    """`teardown()` must be the EXACT inverse of `boot()`'s parent-env shadow.

    These are cheap: they construct a harness with `pid=None`/`dry_run=True` so
    nothing is spawned and nothing is killed — only the env bookkeeping runs.

    The invariant under test is the whole reason the two bugs existed. The
    old restore used lossy `""`-means-"absent" snapshots plus a *synthesised*
    `orig_home` (on Windows `HOME` is unset, so it was derived from
    `USERPROFILE`), which meant a teardown could add a variable that never
    existed and delete three that did.
    """

    @staticmethod
    def _harness(backup, shadowed):
        import pathlib
        import tempfile

        from harness import REQUIRED_TMP_SUBSTR, FunctionalHarness

        # The REAL home (captured at import, since some tests here overwrite
        # HOME), so `is_safe_tmp()` accepts the tempdir in teardown's safety
        # net. `orig_home` plays no part in the env bookkeeping these tests
        # are about — that comes from `backup`/`shadowed` — so this does not
        # weaken them.
        real_home = _REAL_HOME
        # The prefix MUST carry REQUIRED_TMP_SUBSTR, or `is_safe_tmp()` rejects
        # the dir and teardown's safety net raises instead of cleaning up.
        tmp = pathlib.Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
        return FunctionalHarness(
            port=8080,
            nalar_bin=pathlib.Path("nalar-does-not-exist"),
            temp_dir=tmp,
            orig_home=real_home,
            log_path=tmp / "nalar.log",
            pid=None,
            dry_run=True,
            _proc=None,
            _env_backup=backup,
            _env_shadowed=shadowed,
        )

    @pytest.fixture
    def _restore_env(self):
        """Undo whatever a test did to os.environ, whatever that was."""
        saved = dict(os.environ)
        try:
            yield
        finally:
            os.environ.clear()
            os.environ.update(saved)

    @pytest.mark.usefixtures("_restore_env")
    def test_variable_that_was_absent_is_removed_not_invented(self) -> None:
        """The exact regression: teardown must POP an absent key, not set it.

        `http2_tls_test._spawn_nalar` built the harness by hand and left the
        `orig_*` fields at their `""` default. `teardown()` read `""` as
        "nothing to restore" and called `os.environ.pop`, deleting `APPDATA`
        from the parent process outright.
        """
        from harness import _SHADOWED_ENV_KEYS, snapshot_parent_env

        for key in ("APPDATA", "USERPROFILE", "LOCALAPPDATA"):
            assert key in _SHADOWED_ENV_KEYS, (
                f"{key} must be in the snapshot key set, or a shadow of it "
                f"can never be restored"
            )

        backup = snapshot_parent_env()
        # Pretend none of these were set, which is what the lossy "" default
        # used to claim.
        for key in ("APPDATA", "USERPROFILE", "LOCALAPPDATA"):
            backup[key] = None

        shadow_dir = "C:/some/harness-temp-dir"
        shadowed = {
            "APPDATA": shadow_dir + "/AppData/Roaming",
            "USERPROFILE": shadow_dir,
            "LOCALAPPDATA": shadow_dir + "/AppData/Local",
        }
        os.environ.update(shadowed)
        for key in shadowed:
            backup.setdefault(key, None)

        self._harness(backup, shadowed).teardown()

        for key in shadowed:
            assert key not in os.environ, (
                f"{key} was absent before the harness shadowed it, so teardown "
                f"must remove it again rather than leaving it behind"
            )

    @pytest.mark.usefixtures("_restore_env")
    def test_absent_home_is_not_invented_from_the_synthesised_orig_home(self) -> None:
        """Windows has no `HOME`; restoring `orig_home` created one.

        `orig_home` falls back to `USERPROFILE` on Windows precisely so that
        `is_safe_tmp()` has something to compare against. That makes it a
        value `HOME` never held, and the old unconditional
        `os.environ["HOME"] = self.orig_home` wrote it into the environment
        anyway — changing what `Path.home()` and `~` expand to for every test
        that ran afterwards.

        Modelled on a harness that DID shadow HOME, which is what `boot()` does
        on Windows. A harness that shadowed nothing restores nothing at all —
        see `test_a_hand_built_harness_does_not_restore_what_it_never_shadowed`
        for that half of the rule.
        """
        from harness import snapshot_parent_env

        shadow = "C:/some/harness-temp-dir"
        backup = snapshot_parent_env()
        backup["HOME"] = None  # HOME genuinely unset, as on Windows
        os.environ["HOME"] = shadow

        self._harness(backup, {"HOME": shadow}).teardown()

        assert "HOME" not in os.environ, (
            "teardown invented a HOME that did not exist before the harness "
            "ran; orig_home is a SYNTHESISED fallback (USERPROFILE on Windows) "
            "and must never be written back"
        )

    @pytest.mark.usefixtures("_restore_env")
    def test_present_variable_is_restored_to_its_original_value(self) -> None:
        backup = _snapshot_parent_env()
        backup["APPDATA"] = "C:/real/AppData/Roaming"
        os.environ["APPDATA"] = "C:/shadow/AppData/Roaming"

        self._harness(backup, {"APPDATA": "C:/shadow/AppData/Roaming"}).teardown()

        assert os.environ["APPDATA"] == "C:/real/AppData/Roaming"

    @pytest.mark.usefixtures("_restore_env")
    def test_nested_harnesses_restore_the_TRUE_original_in_both_orders(self) -> None:
        """The case the clobber-only guard above does not cover.

        Two harnesses overlap. The inner one snapshots the environment while
        the outer's shadow is already active, so its "original" value IS the
        outer's shadowed tempdir. Restoring per-harness therefore looks
        correct -- every harness puts back exactly what it recorded -- and
        still leaves the parent pointing into a directory that no longer
        exists.

        Measured with two real `boot()` harnesses, outer torn down first:

            DIRTY HOME:         None -> '...\\nalar-func-x94db7s6'  exists=False
            DIRTY USERPROFILE:  'C:\\Users\\ginwa' -> '...\\nalar-func-x94db7s6'  exists=False
            DIRTY APPDATA:      'C:\\Users\\ginwa\\AppData\\Roaming'
                                -> '...\\nalar-func-x94db7s6\\AppData\\Roaming'  exists=False

        An `APPDATA` pointing at a removed directory is what makes the next
        nalar die inside `Config.zig:getDefaultConfigPath` -- before it
        reaches the code the next test is trying to exercise.

        So the harness restores against a process-wide baseline captured by
        the OUTERMOST shadow, not against its own snapshot. Both teardown
        orders are checked, because only one of them was broken.
        """
        from harness import FunctionalHarness, _SHADOWED_ENV_KEYS

        for order in ("inner-first", "outer-first"):
            real = {k: os.environ.get(k) for k in _SHADOWED_ENV_KEYS}

            outer = self._harness(dict(real), {"APPDATA": "C:/outer/AppData/Roaming"})
            os.environ["APPDATA"] = "C:/outer/AppData/Roaming"
            inner = self._harness(dict(real), {"APPDATA": "C:/inner/AppData/Roaming"})
            os.environ["APPDATA"] = "C:/inner/AppData/Roaming"

            if order == "inner-first":
                inner.teardown()
                outer.teardown()
            else:
                outer.teardown()
                inner.teardown()

            for k in _SHADOWED_ENV_KEYS:
                now = os.environ.get(k)
                assert now == real[k], (
                    f"{order}: {k} should be back to its true original "
                    f"{real[k]!r}, got {now!r}. A harness restored another "
                    f"harness's shadow, which points into a deleted tempdir."
                )
                if real[k] is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = real[k]

    def test_a_hand_built_harness_does_not_restore_what_it_never_shadowed(self) -> None:
        """`_env_shadowed` empty means "I mutated nothing" -- restore nothing.

        Three suites build a harness by hand and pass a child `env` dict
        instead of shadowing the parent. Restoring HOME from their own
        snapshot looks harmless and is not: taken under another harness's
        shadow, that snapshot is a tempdir that is about to be deleted, so the
        "restore" injects it into the environment.
        """
        from harness import _SHADOWED_ENV_KEYS

        real_home = os.environ.get("HOME")
        # A snapshot taken while some other harness's shadow was active.
        stale = dict({k: os.environ.get(k) for k in _SHADOWED_ENV_KEYS})
        stale["HOME"] = "C:/deleted/outer-tempdir"

        os.environ["HOME"] = "C:/real/home"
        h = self._harness(stale, {})
        h.teardown()

        assert os.environ.get("HOME") == "C:/real/home", (
            "a harness that shadowed nothing in the parent must not restore "
            "anything; HOME was changed from 'C:/deleted/outer-tempdir' to "
            f"{os.environ.get('HOME')!r}"
        )
        if real_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = real_home

    @pytest.mark.usefixtures("_restore_env")
    def test_does_not_clobber_a_variable_another_harness_now_owns(self) -> None:
        """Two harnesses can be alive at once; teardown order must not matter.

        The outer harness shadows APPDATA, the inner one shadows it again. If
        the OUTER tears down first, a blind restore would put back the real
        value and the inner harness's child processes would then write their
        config into the developer's real roaming profile.

        The guard is that a key is only restored while it still holds the
        value *this* harness installed.
        """
        backup = _snapshot_parent_env()
        backup["APPDATA"] = "C:/real/AppData/Roaming"

        outer_shadow = "C:/outer/AppData/Roaming"
        inner_shadow = "C:/inner/AppData/Roaming"

        os.environ["APPDATA"] = outer_shadow
        outer = self._harness(backup, {"APPDATA": outer_shadow})

        os.environ["APPDATA"] = inner_shadow  # inner harness shadows again

        outer.teardown()

        assert os.environ["APPDATA"] == inner_shadow, (
            "teardown clobbered a variable it no longer owns; the inner "
            "harness's shadow must survive the outer harness's teardown"
        )

    @pytest.mark.usefixtures("_restore_env")
    def test_teardown_twice_is_still_a_no_op(self) -> None:
        backup = _snapshot_parent_env()
        backup["APPDATA"] = "C:/real/AppData/Roaming"
        os.environ["APPDATA"] = "C:/shadow/AppData/Roaming"

        h = self._harness(backup, {"APPDATA": "C:/shadow/AppData/Roaming"})
        h.teardown()
        h.teardown()

        assert os.environ["APPDATA"] == "C:/real/AppData/Roaming"

    def test_snapshot_distinguishes_absent_from_empty(self) -> None:
        """The property the whole fix rests on, asserted directly."""
        from harness import _SHADOWED_ENV_KEYS, snapshot_parent_env

        # Pick a key, remove it, snapshot, then set it to "" and snapshot again.
        key = "APPDATA"
        assert key in _SHADOWED_ENV_KEYS
        saved = os.environ.pop(key, None)
        try:
            absent = snapshot_parent_env()[key]
            os.environ[key] = ""
            empty = snapshot_parent_env()[key]
        finally:
            if saved is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = saved

        assert absent is None, "an unset variable must snapshot as None"
        assert empty == "", "an empty variable must snapshot as ''"
        assert absent != empty, (
            "the snapshot collapsed 'absent' and 'empty' into one value, which "
            "is what let teardown delete variables it should have restored"
        )


class TestOverlappingBootHarnesses:  # noqa: D101 - see the test docstrings
    """Two LIVE `boot()` harnesses must not poison the parent environment.

    The hand-built-harness tests above pass an explicit `_env_backup`, so they
    cannot reach the code that decides WHAT the backup is. Only `boot()`
    does, which is why this needed a real test with real servers: a
    hand-built harness with a supplied baseline passes whether or not the
    process-wide baseline exists, and a first attempt at guarding this
    regression was verified not to fail when the baseline was removed.

    Both teardown orders are covered because only one of them was broken, and
    the broken one is invisible to any test that only checks the intermediate
    state.
    """

    def test_environment_is_pristine_after_both_orders(
        self, default_nalar_bin
    ) -> None:
        from harness import _SHADOWED_ENV_KEYS, FunctionalHarness

        for order in ("inner-first", "outer-first"):
            real = {k: os.environ.get(k) for k in _SHADOWED_ENV_KEYS}
            try:
                outer = FunctionalHarness.boot(default_nalar_bin)
                inner = FunctionalHarness.boot(default_nalar_bin)
                if order == "inner-first":
                    inner.teardown()
                    outer.teardown()
                else:
                    outer.teardown()
                    inner.teardown()

                for k in _SHADOWED_ENV_KEYS:
                    now = os.environ.get(k)
                    assert now == real[k], (
                        f"{order}: {k} should be back to {real[k]!r}, got "
                        f"{now!r}. A harness restored another harness's "
                        f"shadow, which points into a tempdir that teardown "
                        f"has since deleted -- and an APPDATA like that "
                        f"makes the next nalar die in "
                        f"Config.zig:getDefaultConfigPath before it reaches "
                        f"the code under test."
                    )
            finally:
                for k, v in real.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v

    def test_baseline_is_released_so_a_later_run_starts_clean(
        self, default_nalar_bin
    ) -> None:
        """The refcount has to return to zero, or the baseline goes stale.

        If `teardown` forgets to release, the next `boot()` reuses a baseline
        captured before an earlier harness ran, and the parent environment is
        restored to whatever it was then rather than to what it is now. That
        failure is invisible within one test and shows up as cross-test drift
        much later.
        """
        import harness as harness_mod

        from harness import FunctionalHarness

        h = FunctionalHarness.boot(default_nalar_bin)
        assert harness_mod._ENV_BASELINE_OWNERS >= 1, (
            "boot() must register a baseline participant while it is alive"
        )
        h.teardown()
        assert harness_mod._ENV_BASELINE_OWNERS == 0, (
            "teardown did not release the baseline; a later boot() would "
            "restore a stale environment"
        )
        assert harness_mod._ENV_BASELINE is None, (
            "the baseline should be cleared once the last harness is gone"
        )


class TestBootLeavesTheParentEnvironmentAlone:
    """The whole environment, not just the keys we thought to track.

    This is the end-to-end version of the invariant above, and it exists
    because the first attempt at that fix satisfied every key-level test and
    still broke the suite.

    `boot()` recorded what it shadowed by diffing the ENTIRE environment
    against the snapshot:

        {k: v for k, v in os.environ.items() if env_backup.get(k) != v}

    Every key we do not track — `PATH`, `SystemRoot`, `TEMP` — has no entry in
    `env_backup`, so `env_backup.get(k)` is `None`, so it compares unequal to
    its own current value and is recorded as "shadowed". `teardown()` then
    restored it by popping it, and the parent process lost `PATH` and
    `SystemRoot`.

    The key-level tests above all passed, because every one of them looked at
    a key that *is* tracked. What gave it away was the *next* boot failing
    with `subprocess.Popen ... NotADirectoryError: [WinError 267]` — a broken
    process environment, surfacing as a mysterious directory error. That
    repro is the test: assert the FULL environment round-trips.
    """

    def test_every_variable_survives_a_boot_teardown_round_trip(
        self, default_nalar_bin
    ) -> None:
        from harness import FunctionalHarness

        before = dict(os.environ)
        h = FunctionalHarness.boot(default_nalar_bin)
        try:
            # Sanity: the boot really did shadow something, so a no-op round
            # trip cannot make this pass vacuously.
            from harness import _SHADOWED_ENV_KEYS

            changed = [
                k
                for k in _SHADOWED_ENV_KEYS
                if os.environ.get(k) != before.get(k)
            ]
            if os.name == "nt":
                assert changed, (
                    "boot() shadowed none of the parent environment on "
                    "Windows, so this test would assert nothing"
                )
        finally:
            h.teardown()

        after = dict(os.environ)

        lost = sorted(set(before) - set(after))
        assert not lost, (
            "teardown() DELETED these variables from the parent process; an "
            f"untracked key must never be treated as 'was absent':\n  "
            + "\n  ".join(f"{k}={before[k]!r}" for k in lost)
        )

        added = sorted(set(after) - set(before))
        assert not added, (
            "teardown() ADDED these variables to the parent process; the "
            f"synthesised `orig_home` fallback must never be written back:\n  "
            + "\n  ".join(f"{k}={after[k]!r}" for k in added)
        )

        changed = sorted(k for k in before if before[k] != after.get(k))
        assert not changed, (
            "teardown() left these variables holding the wrong value:\n  "
            + "\n  ".join(f"{k}: {before[k]!r} -> {after.get(k)!r}" for k in changed)
        )

    def test_two_boots_in_a_row_both_work(self, default_nalar_bin) -> None:
        """The symptom of losing `PATH`/`SystemRoot`: only the 2nd boot fails.

        Kept as its own test because it is what actually surfaced the bug, and
        it fails with a Windows error code that points nowhere near the cause
        (`NotADirectoryError` from `Popen`, not "your environment is broken").
        Asserting the error message would be useless; asserting that a second
        boot succeeds is not.
        """
        import subprocess

        from harness import FunctionalHarness

        for attempt in (1, 2):
            h = FunctionalHarness.boot(default_nalar_bin)
            try:
                assert h.health() is not None
            finally:
                h.teardown()
            # Prove the environment is still usable at all — this is the
            # cheapest possible subprocess spawn, and it is the thing that
            # breaks when SystemRoot or PATH goes missing.
            out = subprocess.run(
                [sys.executable, "-c", "print('env ok')"],
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert out.returncode == 0, (
                f"after boot/teardown #{attempt} the parent environment can no "
                f"longer start a process: rc={out.returncode} "
                f"stderr={out.stderr[-500:]!r}"
            )