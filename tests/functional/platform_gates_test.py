"""Contract tests for ``tests/platform_gates.py``.

The gate table is load-bearing and its failure mode is silent. If a row
names a file that no longer exists, the gate simply never fires and the
tests it was hiding come back — which looks like "the fix worked", not
like a broken gate. If a module ends up in BOTH lists, pytest never runs
the skip marker (the file was already ignored) and the reason a reviewer
would read is gone. Both are the kind of mistake that survives review and
is only discovered when a platform breaks.

So these tests are about the TABLE, not about the platform it gates. They
need no pabrik binary, no harness boot and no browser — they run on all
three CI platforms identically, which is deliberate: a test that could
only run on Linux could not police a table whose whole job is to describe
Linux's differences from the other two.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

from platform_gates import (
    GATES,
    Gate,
    collect_ignore_for,
    current_platform,
    gate_platforms,
    runtime_skip_reasons,
)

SUITES = ("functional", "functional_ui")


def _existing_modules() -> set[str]:
    """Every test module basename that exists across both suites."""
    here = Path(__file__).resolve().parent
    return {
        p.name
        for suite in SUITES
        for p in (here.parent / suite).glob("*_test.py")
    }


def test_every_gate_names_a_file_that_exists() -> None:
    """A gate for a renamed/deleted file is a gate that never fires."""
    existing = _existing_modules()
    missing = sorted(
        f"{g.platform}:{g.module}" for g in GATES if g.module not in existing
    )
    assert not missing, (
        "platform_gates.GATES references files that do not exist under "
        f"tests/{'/'.join(SUITES)}/: {missing}. Either the file was renamed "
        "(update the row) or the test was made portable (DELETE the row — "
        "a stale gate hides the next regression)."
    )


def test_no_module_is_gated_twice_on_one_platform() -> None:
    """First-wins de-duplication in the helpers would mask a conflict.

    ``_gates`` keeps the first row per module, so two disagreeing rows
    do not crash — they quietly resolve to one. That is exactly the kind
    of silent resolution this table must not have.
    """
    seen: set[tuple[str, str]] = set()
    dupes: list[str] = []
    for g in GATES:
        key = (g.platform, g.module)
        if key in seen:
            dupes.append(f"{g.platform}:{g.module}")
        seen.add(key)
    assert not dupes, f"duplicate (platform, module) rows: {sorted(set(dupes))}"


@pytest.mark.parametrize("platform", gate_platforms())
def test_import_and_runtime_gates_are_disjoint(platform: str) -> None:
    """A file is either never imported OR skipped — never both.

    Listed twice means the ``collect_ignore`` entry wins and the skip
    marker (with its reason) is never evaluated, so the platform's
    explanation for the skip silently disappears from the report.
    """
    ignored = set(collect_ignore_for(platform))
    skipped = set(runtime_skip_reasons(platform))
    assert not (ignored & skipped), (
        f"{platform}: {sorted(ignored & skipped)} is in both collect_ignore "
        "and the skip-marker map; the marker will never be evaluated."
    )


@pytest.mark.parametrize("platform", gate_platforms())
def test_every_row_carries_a_reason_a_reviewer_can_act_on(platform: str) -> None:
    """Every skip must say WHY, and name the platform or the blocker.

    A bare "skipped on Windows" is the failure this guards: the reader
    cannot tell whether to fix the test, fix the product, or accept the
    platform limit, so the row rots.
    """
    reasons = runtime_skip_reasons(platform)
    for module, reason in sorted(reasons.items()):
        assert reason.strip(), f"{platform}:{module} has an empty reason"
        # Long enough to be actionable, short enough to read in a report.
        assert len(reason) > 20, (
            f"{platform}:{module} reason is too terse to act on: {reason!r}"
        )
        lowered = reason.lower()
        assert any(
            hint in lowered for hint in ("windows", "macos", "linux", "/proc", "posix")
        ), (
            f"{platform}:{module} reason names neither the platform nor a "
            f"portable blocker: {reason!r}"
        )


def test_every_row_declares_the_platform_key_it_claims() -> None:
    """Guard against a row keyed on a platform string nothing can produce.

    ``_gates`` matches ``GATES[i].platform`` against the value
    ``current_platform()`` returns. A typo ("win64", "macos") produces a
    row that is dead code on every runner, and nothing in a green CI run
    says so.
    """
    known = set(gate_platforms())
    bogus = sorted({g.platform for g in GATES} - known)
    assert not bogus, f"GATES has rows keyed on unknown platforms: {bogus}"


def test_gates_are_built_for_this_platform_or_are_explicit_about_the_rest() -> None:
    """The Linux cell must not be gated at all, or the fix is not done.

    ``tests/platform_gates.py`` exists to let ubuntu-24.04 keep running
    everything it ran before. A Linux row is therefore either a bug in the
    table or a genuine product limit, and either way it has to be visible
    in a review of this file rather than discovered on a runner.
    """
    linux_rows = [g for g in GATES if g.platform == "linux"]
    assert not linux_rows, (
        "tests/platform_gates.py must not gate Linux: the whole point is "
        f"that ubuntu-24.04 keeps its full coverage. Found {[g.module for g in linux_rows]}"
    )


def test_current_platform_is_one_of_the_gate_keys() -> None:
    assert current_platform() in set(gate_platforms())
    assert current_platform() in ("win32", "darwin", "linux")


def test_helpers_honour_an_explicit_platform_argument() -> None:
    """The ``platform=`` parameter is what makes this file testable at all.

    Without it, a test asserting "these modules are skipped on Windows"
    could only run on Windows — and the table's whole job is to describe
    the other two platforms from a Linux runner.
    """
    for platform in gate_platforms():
        collect_ignore_for(platform)
        runtime_skip_reasons(platform)
    # Sanity: the three platforms are genuinely different, so a hardcoded
    # return value cannot pass this file.
    win = set(collect_ignore_for("win32")) | set(runtime_skip_reasons("win32"))
    mac = set(collect_ignore_for("darwin")) | set(runtime_skip_reasons("darwin"))
    lin = set(collect_ignore_for("linux")) | set(runtime_skip_reasons("linux"))
    assert win and not lin, "Windows must be gated and Linux must not"
    assert mac and not lin, "macOS must be gated and Linux must not"
    assert win != mac, "Windows and macOS gates are identical — one is probably wrong"
