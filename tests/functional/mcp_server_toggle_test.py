"""
Functional toggle test for the MCP server `enabled` flag (Task 5).

Backend coverage (unit/static, in-repo):
  - `Config.zig` parses `enabled` (absent / non-bool → true).
  - `rebuildMcpServersParsed` omits `enabled` when true, keeps
    `enabled: false` when disabled.
  - `buildMCPToolsRun` skips explicitly-disabled servers before any
    spawn/connect; `handle_mcp_tool` rejects calls to disabled servers.

What THIS module covers (wire round-trip, no LLM call):
  (a) PUT a config with a disabled stdio server
      (frontend serializer shape: {command, ...} + `enabled: false`
      only when disabled; inert `/bin/true` command since we assert
      exclusion, never tool output) → GET returns `enabled: false`
      with the command preserved, and the on-disk config.json matches.
  (b) Enumeration proxy: there is no clean HTTP seam that lists the
      agent's enumerated tools (enumeration happens inside
      `buildMCPToolsRun` during a workflow run, which needs a live
      LLM). So we assert the wire contract enumeration depends on:
      PUT disabled → GET `enabled: false`; subsequent PUT flip to
      enabled (omit the key, exactly what the frontend serializer
      sends) → GET shows the key absent (which the backend parses as
      enabled → the server IS enumerated again).
  (c) Sibling preservation + explicit-true tolerance: a disabled server
      coexists with an enabled sibling; toggling one does not clobber
      the other; an explicit `enabled: true` round-trips as enabled
      (backend accepts it; rebuild may omit the key on next write).

Run:
    NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
      python3 -m pytest tests/functional/mcp_server_toggle_test.py -v
"""

from __future__ import annotations

import json
import platform
import sys
from pathlib import Path

from harness import FunctionalHarness


def _platform_config_dir(home: Path) -> Path:
    """Mirror `LlmConfig.getDefaultConfigDir` (Config.zig) per-OS layout."""
    system = platform.system()
    if system == "Darwin":
        return home / "Library" / "Application Support" / "nalar"
    if system == "Windows":
        appdata = sys.platform == "win32" and __import__("os").environ.get("APPDATA")
        if appdata and appdata.startswith(str(home)):
            return Path(appdata) / "nalar"
        return home / "AppData" / "Roaming" / "nalar"
    return home / ".config" / "nalar"


def test_disabled_stdio_server_round_trips_enabled_false() -> None:
    """PUT disabled stdio server → GET returns enabled:false (wire + disk)."""
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()

        # EXACT frontend serializer shape for a disabled stdio server:
        # {command, ...} + enabled:false only when disabled.
        put_body = {
            **initial,
            "mcp_servers": {
                "toggled_off": {
                    "command": "/bin/true",
                    "enabled": False,
                },
            },
        }
        harness.http("PUT", "/api/config/nalar", json_body=put_body, expect=200)

        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        assert "toggled_off" in servers, (
            f"disabled server missing after PUT: {list(servers.keys())}"
        )
        entry = servers["toggled_off"]
        assert entry.get("command") == "/bin/true", f"command lost: {entry!r}"
        assert entry.get("enabled") is False, (
            f"expected enabled:false to round-trip, got: {entry!r}"
        )

        # On-disk shape matches (proves the generic json.Value deep-copy
        # in PUT preserved `enabled` through the disk write).
        cfg_path = _platform_config_dir(Path(harness.temp_dir)) / "config.json"
        assert cfg_path.exists(), f"config.json not written at {cfg_path}"
        on_disk = json.loads(cfg_path.read_text())
        disk_entry = (on_disk.get("mcp_servers") or {}).get("toggled_off") or {}
        assert disk_entry.get("enabled") is False, (
            f"on-disk enabled flag lost: {disk_entry!r}"
        )
    finally:
        harness.teardown()


def test_flip_disabled_to_enabled_omits_key() -> None:
    """Disabled → enabled flip (omit key) → GET shows absent (== enabled).

    This is the enumeration proxy: `buildMCPToolsRun` skips ONLY an
    explicit `.bool false`; a missing key parses as enabled, so the
    server is enumerated again. No HTTP seam lists enumerated tools
    directly (enumeration runs inside the workflow, which needs a live
    LLM), so the wire contract — explicit-false vs absent — is what we
    lock in here.
    """
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()

        # 1. Disable.
        harness.http(
            "PUT",
            "/api/config/nalar",
            json_body={
                **initial,
                "mcp_servers": {
                    "flip": {"command": "/bin/true", "enabled": False},
                },
            },
            expect=200,
        )
        disabled = harness.http("GET", "/api/config/nalar", expect=200).json()
        assert (disabled.get("mcp_servers") or {}).get("flip", {}).get("enabled") is False

        # 2. Re-enable with the EXACT frontend shape (omit `enabled`).
        enabled_base = harness.http("GET", "/api/config/nalar", expect=200).json()
        harness.http(
            "PUT",
            "/api/config/nalar",
            json_body={
                **enabled_base,
                "mcp_servers": {
                    "flip": {"command": "/bin/true"},
                },
            },
            expect=200,
        )
        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        assert "flip" in servers, "server dropped by enable-flip PUT"
        assert servers["flip"].get("command") == "/bin/true"
        # Omit-when-true: enabled servers serialize WITHOUT the key
        # (absent parses as enabled → server is enumerated again).
        assert servers["flip"].get("enabled") in (None, True), (
            f"expected enabled absent/true after flip, got: {servers['flip']!r}"
        )
    finally:
        harness.teardown()


def test_disabled_sibling_preserved_and_explicit_true_tolerated() -> None:
    """Disabled + enabled siblings coexist; explicit true parses as enabled."""
    harness = FunctionalHarness.boot(stub_llm_profile=True)
    try:
        initial = harness.http("GET", "/api/config/nalar", expect=200).json()
        harness.http(
            "PUT",
            "/api/config/nalar",
            json_body={
                **initial,
                "mcp_servers": {
                    "off": {"command": "/bin/true", "enabled": False},
                    "on": {"command": "/bin/true", "enabled": True},
                },
            },
            expect=200,
        )
        got = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers = got.get("mcp_servers") or {}
        assert set(servers.keys()) == {"off", "on"}, (
            f"sibling servers not preserved: {list(servers.keys())}"
        )
        assert servers["off"].get("enabled") is False
        # Explicit true must NOT disable (backend: only `.bool false`
        # disables; missing/non-bool/true all mean enabled).
        assert servers["on"].get("enabled") in (None, True), (
            f"explicit true should stay enabled, got: {servers['on']!r}"
        )

        # Toggle only "off" → "on" must not clobber the sibling.
        harness.http(
            "PUT",
            "/api/config/nalar",
            json_body={
                **got,
                "mcp_servers": {
                    "off": {"command": "/bin/true"},
                    "on": {"command": "/bin/true", "enabled": True},
                },
            },
            expect=200,
        )
        got2 = harness.http("GET", "/api/config/nalar", expect=200).json()
        servers2 = got2.get("mcp_servers") or {}
        assert set(servers2.keys()) == {"off", "on"}, (
            f"sibling dropped by toggle PUT: {list(servers2.keys())}"
        )
        assert servers2["off"].get("enabled") in (None, True)
    finally:
        harness.teardown()
