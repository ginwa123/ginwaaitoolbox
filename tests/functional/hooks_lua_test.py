"""Functional service-level verification for single-file Lua hooks.

Branch: worktree/hook2312maspodmp2131 (plan
docs/superpowers/plans/2026-09-12-hook-lua-pre-post-tool-use.md).

What this covers
================
Hooks (`<config>/.hooks/register_hook.lua :: init(event, data)`) wrap
tool *dispatch*, which only happens inside an LLM-driven agent loop.
A full end-to-end run (stub LLM returning a tool_call) is too heavy
for a wire test — the same call command_tool_test.py makes — so this
file verifies the service-level halves and leaves execution behavior
to the Zig dispatch tests in src/agentic_loop/handle_tool.zig
("hook dispatch: ..." — real registry + real read_file exec + real
Lua: baseline, pre-deny skips exec, pre-modify rewrites args,
post-replace swaps output):

  * BOOT-SAFE — service boots and serves with a valid hook present,
    with a syntactically broken hook present (fail-open: a broken
    hook can never break the service), and with no hook at all.
  * NON-INTERFERENCE — workspace/agent creation (non-tool paths)
    still 201 with a deny-all hook installed (hooks only wrap tool
    dispatch, nothing else).
  * PATH CONVENTION — the hook resolves under the isolated HOME's
    config dir (<tmp>/.config/nalar/hooks/register_hook.lua).
  * EXAMPLE VALIDITY — the shipped examples/hooks/register_hook.lua
    parses as Lua (via system lua5.4 when available, skipped otherwise).

Run:
    NALAR_BIN=<worktree>/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/hooks_lua_test.py -v
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from harness import FunctionalHarness

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_HOOK = REPO_ROOT / "examples" / "hooks" / "register_hook.lua"

DENY_ALL_HOOK = """\
function init(event, data)
  if event == 'pre_tool_use' then
    return { deny = 'blocked by functional test hook' }
  end
  return nil
end
"""

BROKEN_HOOK = "function init(((\n"


def _hooks_dir(harness: FunctionalHarness) -> Path:
    d = harness.temp_dir / ".config" / "nalar" / "hooks"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _write_hook(harness: FunctionalHarness, content: str) -> Path:
    p = _hooks_dir(harness) / "register_hook.lua"
    p.write_text(content, encoding="utf-8")
    return p


def _service_healthy(harness: FunctionalHarness) -> None:
    assert harness.health(), f"service unhealthy:\n{harness.tail_log()}"
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    names = [t["name"] for t in r.json().get("tools", [])]
    assert len(names) >= 1, "registry returned 0 tools — fixture broken?"


def test_service_healthy_with_valid_hook(harness: FunctionalHarness) -> None:
    """A valid hook file must not disturb boot or the tool registry."""
    p = _write_hook(harness, DENY_ALL_HOOK)
    assert p.exists()
    _service_healthy(harness)


def test_service_healthy_with_broken_hook(harness: FunctionalHarness) -> None:
    """A syntactically broken hook must fail open, never break serving."""
    _write_hook(harness, BROKEN_HOOK)
    _service_healthy(harness)


def test_service_healthy_without_hook(harness: FunctionalHarness) -> None:
    """Baseline: no hooks dir at all serves normally."""
    _service_healthy(harness)


def test_non_tool_paths_unaffected_by_deny_all_hook(
    harness: FunctionalHarness,
) -> None:
    """Deny-all hook installed, but workspace/agent creation (which runs
    no tools) must still succeed — hooks wrap dispatch only."""
    _write_hook(harness, DENY_ALL_HOOK)
    r = harness.http("POST", "/api/workspaces", json_body={"name": "hook-ws"}, expect=201)
    ws_id = r.json()["id"]
    r = harness.http(
        "POST",
        f"/api/workspaces/{ws_id}/items/agent",
        json_body={"name": "hook-agent", "path": "/tmp/hook-test"},
        expect=201,
    )
    body = r.json()
    assert body.get("item") is not None, f"missing 'item' envelope: {body!r}"


def test_example_hook_is_valid_lua() -> None:
    """The shipped example must parse. Needs a system lua; skipped without."""
    assert EXAMPLE_HOOK.exists(), f"example missing: {EXAMPLE_HOOK}"
    lua = shutil.which("lua5.4") or shutil.which("lua")
    if lua is None:
        import pytest

        pytest.skip("no system lua available")
    src = EXAMPLE_HOOK.read_text(encoding="utf-8")
    assert "function init(event, data)" in src, "example must define init(event, data)"
    r = subprocess.run(
        [lua, "-e", f"assert(loadfile({str(EXAMPLE_HOOK)!r}))"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert r.returncode == 0, f"example failed to parse: {r.stderr}"
