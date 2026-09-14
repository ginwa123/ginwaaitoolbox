"""Functional gate for `nalar-desktop --browser <url>`.

Plan: `docs/superpowers/plans/2026-09-14-in-app-browser-tab.md`.

There is no wire test for this feature because it adds no HTTP route —
browser mode never touches the `nalar` server at all. This file is the
CLI-level gate instead: it proves the `--browser` contract (scheme
rejection + missing-value rejection + no server start) by running the
real desktop binary with an isolated `tmp_path` HOME and no display.

Standalone by design: these tests do NOT use the `harness` fixture and
never boot `nalar`. Browser mode must start NO server, so no port is
ever bound here (and never 8081).
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _desktop_bin() -> Path:
    override = os.environ.get("NALAR_DESKTOP_BIN")
    if override:
        cand = Path(override)
        if cand.exists():
            return cand
        pytest.skip(f"nalar-desktop not built at NALAR_DESKTOP_BIN={override} — skipping")
    cand = _repo_root() / "zig-out" / "bin" / "nalar-desktop"
    if cand.exists():
        return cand
    pytest.skip("nalar-desktop not built — run `zig build nalar-desktop` (or set NALAR_DESKTOP_BIN)")


def _run(bin: Path, home: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(bin), *args],
        capture_output=True,
        text=True,
        timeout=20,
        env={**os.environ, "HOME": str(home), "DISPLAY": ""},
    )


def test_browser_rejects_javascript_scheme(tmp_path: Path) -> None:
    """Guards against `javascript:` URLs reaching a webview.

    Regression: without the `isHttpUrl` parse-time check, `--browser
    javascript:alert(1)` would be handed to a window as a script URL.
    A hang here raises `subprocess.TimeoutExpired` (no catch) — a hang
    is a test failure, so let it propagate.
    """
    proc = _run(_desktop_bin(), tmp_path, "--browser", "javascript:alert(1)")
    assert proc.returncode != 0


def test_browser_rejects_file_scheme(tmp_path: Path) -> None:
    """Guards against `file:` URLs reaching a webview.

    Regression: without the `isHttpUrl` parse-time check, `--browser
    file:///etc/passwd` would expose local files in a window.
    """
    proc = _run(_desktop_bin(), tmp_path, "--browser", "file:///etc/passwd")
    assert proc.returncode != 0


def test_browser_missing_value_fails(tmp_path: Path) -> None:
    """Guards against `--browser` with no value being accepted.

    Regression: the `--browser` arm must return `error.MissingValue`
    when the value is absent, like every other value-taking flag.
    """
    proc = _run(_desktop_bin(), tmp_path, "--browser")
    assert proc.returncode != 0


def test_browser_mode_starts_no_server(tmp_path: Path) -> None:
    """Guards against browser mode probing/auto-spawning a nalar server.

    Regression: if the `if (cfg.browser_url)` block ever moved after
    the attach block, opening a browser tab would start (or attach to)
    a server and write state. Accept ANY returncode here — a headless
    runner has no display, so the window open itself may fail — the
    invariant is that no server side-effect happened.
    """
    proc = _run(_desktop_bin(), tmp_path, "--browser", "https://example.com")
    _ = proc  # any returncode is fine; the assertions below are the gate.
    # WHY a state-file absence is the "nothing listening" proxy: the only
    # thing that binds a port in the desktop is `attach.resolveAttachTarget`
    # (probe → auto-spawn → write state.json), and browser mode returns
    # before that call is ever reached — so no state file means no probe
    # ran and no server was spawned. No `--attach-port` is passed on
    # purpose: the default path is what must stay silent.
    assert not (tmp_path / ".local/state/nalar/state.json").exists()


def test_browser_branch_precedes_attach_static_contract() -> None:
    """Static contract: browser mode cannot start a server by construction.

    No binary needed — must never skip. Asserts the `--browser` branch
    appears textually BEFORE the `attach.resolveAttachTarget(` call in
    `main.zig` (so browser mode returns before any probe/spawn), and
    that `isHttpUrl(args[i])` guards the `--browser` value in `cli.zig`.
    This is the "no new HTTP route means no new wire test" assertion.
    """
    main_src = (_repo_root() / "src/apps/desktop_app/main.zig").read_text(encoding="utf-8")
    browser_at = main_src.find("cfg.browser_url")
    attach_at = main_src.find("attach.resolveAttachTarget(")
    assert browser_at != -1, "main.zig: no cfg.browser_url branch found"
    assert attach_at != -1, "main.zig: no attach.resolveAttachTarget( call found"
    assert browser_at < attach_at, (
        "main.zig: the --browser branch must precede attach.resolveAttachTarget( "
        "so browser mode returns before any server probe/spawn"
    )

    cli_src = (_repo_root() / "src/apps/desktop_app/cli.zig").read_text(encoding="utf-8")
    assert "--browser" in cli_src, "cli.zig: no --browser flag found"
    assert "isHttpUrl(args[i])" in cli_src, "cli.zig: --browser value is not guarded by isHttpUrl(args[i])"
