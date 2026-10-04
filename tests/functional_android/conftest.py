"""Shared pytest fixtures for the Android functional UI suite.

Five fixtures carry the weight:

* ``default_pabrik_bin`` (session) — resolves a built ``pabrik`` binary.
* ``android_emulator`` (session) — the serial of a **running emulator**, or a
  skip that says why the suite needs one.
* ``gradle_env`` (session) — ``JAVA_HOME``/``ANDROID_HOME``, or a skip naming
  what is missing.
* ``android_harness`` (module) — one real ``pabrik``, one isolated tmpdir HOME,
  every scenario seeded into that instance's own ``agent.db``.
* ``instrumented_results`` (module) — one Gradle run, parsed.

Why module-scoped rather than function-scoped, when ``tests/functional/`` uses
function scope: this suite's per-test cost is a Gradle build + install + device
handshake, not a process boot. A fresh server per assertion would multiply a
three-minute suite by the scenario count for no isolation gain — isolation comes
from giving every scenario its own ``session_id`` and from the instrumented side
clearing the app's own state between tests (see ``ClearAppStateRule``). The
precedent is ``tests/functional/android_chat_sse_contract_test.py``, which
shadows the same fixture to module scope for the same reason.

### Why the emulator is required rather than merely preferred

The APK is built to reach the host at ``10.0.2.2``, which is the *emulator's*
alias for the host machine's loopback interface. On a physical device that
address means nothing, so a run on real hardware would fail in a way that looks
like a broken app. The suite therefore refuses to guess: it wants an emulator
serial, and says so.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Iterator

import pytest

from android_gradle import resolve_gradle_env, run_instrumented
from db_seed import DbSeed
from harness import FunctionalHarness, FunctionalHarnessError
from scenarios import SCENARIOS
from seed_scenarios import seed_all

#: Where the app lives, relative to the repository root.
_ANDROID_PROJECT = Path("src") / "apps" / "android_mobile"

#: The emulator's alias for the host machine's loopback interface. A server
#: bound to 127.0.0.1 (pabrik has no `--host` flag) is reachable on it.
EMULATOR_HOST_ALIAS = "10.0.2.2"


# ─── Session-scoped: resolve the pabrik binary once ─────────────────────────


def _repo_root() -> Path:
    """The repository root, found by walking up for the Gradle wrapper's parent.

    pytest's rootdir is the worktree root, but a fixture that hardcodes `.`
    breaks the moment somebody runs pytest from a subdirectory.
    """
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / _ANDROID_PROJECT / "gradlew").exists():
            return candidate
    raise AssertionError(f"no Android project above {here}")


def _resolve_pabrik_bin() -> Path:
    """Find the pabrik binary in standard locations.

    Same resolution order as ``tests/functional/conftest.py`` and
    ``tests/functional_ui/conftest.py`` — duplicated rather than imported
    because a conftest fixture is only visible inside its own directory tree,
    and this suite is a sibling of both rather than a child of either.
    """
    candidates: list[Path] = []
    env_bin = os.environ.get("PABRIK_BIN") or os.environ.get("PABRIK_BIN")
    if env_bin:
        candidates.append(Path(env_bin))
    candidates.extend([
        Path("./zig-out/bin/pabrik"),
        Path("./zig-out/bin/pabrik.exe"),
        Path("./zig-out/bin/pabrikcore-linux-x86_64"),
        Path("./zig-out/bin/pabrikcore-macos-aarch64"),
        Path("./zig-out/bin/pabrikcore-macos-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64.exe"),
        # Pre-rebrand artifact names, probed after the current ones so a
        # developer who has not rebuilt since the rename still gets a binary.
        Path("./zig-out/bin/pabrik"),
        Path("./zig-out/bin/pabrik.exe"),
        Path("./zig-out/bin/pabrikcore-linux-x86_64"),
        Path("./zig-out/bin/pabrikcore-macos-aarch64"),
        Path("./zig-out/bin/pabrikcore-macos-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64"),
        Path("./zig-out/bin/pabrikcore-windows-x86_64.exe"),
    ])
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c.resolve()
    raise FileNotFoundError(
        "No pabrik binary found. Set PABRIK_BIN or run "
        "`zig build install:linux:system` first."
    )


@pytest.fixture(scope="session")
def default_pabrik_bin() -> Path:
    """Session-scoped: the pabrik binary path. Skips the test if missing."""
    try:
        return _resolve_pabrik_bin()
    except FileNotFoundError as e:
        pytest.skip(str(e))


# ─── Session-scoped: is there an emulator, and where is the toolchain? ─────


def _attached_serials(adb: Path) -> list[str]:
    """Serials in the `device` state, or an empty list if adb cannot answer.

    Best-effort by design. The adb *client* is unreliable on a development box
    where several sessions run their own servers, and that is not a reason to
    skip: an explicitly set ``ANDROID_SERIAL`` is just as good an answer, and
    the caller falls back to it.
    """
    try:
        completed = subprocess.run(
            [str(adb), "devices"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if completed.returncode != 0:
        return []

    serials: list[str] = []
    for line in completed.stdout.decode("utf-8", errors="replace").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    return serials


@pytest.fixture(scope="session")
def android_emulator() -> str:
    """The emulator's serial, or a skip that explains what is needed.

    Emulator-only, and deliberately: the base URL the suite builds with is the
    emulator's host alias, so real hardware would fail as though the app were
    broken.
    """
    from_env = os.environ.get("ANDROID_SERIAL", "").strip()
    if from_env.startswith("emulator-"):
        return from_env

    adb = Path(os.environ.get("ANDROID_HOME", Path.home() / "Android" / "Sdk")) / "platform-tools" / "adb"
    if adb.exists():
        emulators = [s for s in _attached_serials(adb) if s.startswith("emulator-")]
        if emulators:
            return emulators[0]

    pytest.skip(
        "no emulator attached. This suite reaches the host at "
        f"{EMULATOR_HOST_ALIAS}, which only exists inside an emulator, so a "
        "physical device cannot run it. Start an AVD (e.g. `emulator -avd "
        "Medium_Phone -no-window -no-audio -no-snapshot`) and re-run; if "
        "several devices are attached, set ANDROID_SERIAL=emulator-5554."
    )


@pytest.fixture(scope="session")
def gradle_env(android_emulator: str) -> dict[str, str]:
    """The environment `connectedDebugAndroidTest` needs, or a skip.

    Pinned to the emulator through ``ANDROID_SERIAL``, because a developer with
    a phone plugged in as well would otherwise have the run land on whichever
    device adb listed first — and the phone cannot reach the host alias.
    """
    try:
        env = resolve_gradle_env(_repo_root())
    except AssertionError as e:
        pytest.skip(str(e))
    env["ANDROID_SERIAL"] = android_emulator
    return env


# ─── Module-scoped: one real pabrik, every scenario seeded into it ──────────


@pytest.fixture(scope="module")
def android_harness(default_pabrik_bin: Path) -> Iterator[FunctionalHarness]:
    """One isolated pabrik for the module, on a free port (never 8081).

    ``stub_llm_profile=True`` writes a config with a single profile whose
    ``base_url`` points at a dead port. It is what makes ``GET /api/config/pabrik``
    return a profile for the composer's model picker; no scenario here needs a
    turn to complete, because every row is seeded into the DB directly.

    ``boot()`` picks a random port in 20000..32000 and refuses 8081, so this
    never collides with the always-running dev backend.
    """
    h = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except FunctionalHarnessError as e:
            pytest.fail(f"android_harness teardown refused: {e}", pytrace=False)


@pytest.fixture(scope="module")
def seed_db(android_harness: FunctionalHarness) -> Path:
    """Path to the harness instance's own ``agent.db``.

    ``pabrik`` derives it from ``HOME``, which the harness shadowed to its
    tmpdir, so this is always inside ``pabrik-func-*``. ``DbSeed`` re-validates
    that with ``is_safe_tmp`` before it opens the file.
    """
    return android_harness.temp_dir / ".config" / "pabrik" / "agent.db"


@pytest.fixture(scope="module")
def seeded(android_harness: FunctionalHarness, seed_db: Path) -> dict[str, str]:
    """Seed every scenario, and hand back the base URL the app must be built with.

    Returns a small dict rather than a tuple so the failure message at a call
    site reads as a sentence.
    """
    seed = DbSeed(seed_db)
    with seed.connect() as conn:
        sessions = seed_all(seed, conn)

    return {
        "base_url": f"http://{EMULATOR_HOST_ALIAS}:{android_harness.port}",
        "sessions": sessions,
    }


# ─── Module-scoped: one Gradle run for the whole suite ────────────────────


@pytest.fixture(scope="module")
def instrumented_results(seeded: dict, gradle_env: dict):
    """Build, install and run the instrumented suite exactly once.

    The result is cached for the module, so ten scenario assertions cost one
    Gradle invocation rather than ten — see the module docstring. A Gradle-level
    failure raises here, which surfaces on the first test that needs the results
    with the tail of Gradle's output attached.
    """
    return run_instrumented(
        base_url=seeded["base_url"],
        project_dir=_repo_root() / _ANDROID_PROJECT,
        env=gradle_env,
    )


__all__ = ["SCENARIOS", "EMULATOR_HOST_ALIAS"]
