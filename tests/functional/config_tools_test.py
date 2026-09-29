"""Functional tests for the config.json `tools` default checklist (plan
2026-09-22-tools-menu-config-default-tools, decisions D2/D4).

Verifies the wire round-trip of the top-level `tools` array through
GET/PUT /api/config/nalar with the EXACT frontend wire shapes:

  1. GET returns `tools: null` when the on-disk key is absent.
  2. PUT of the whole config WITHOUT a `tools` key (a Settings save from
     another tab) does NOT erase `tools` from disk (the PUT-strip
     footgun — this is the test that catches a missing write-struct
     field).
  3. PUT with `"tools": [...]` persists and GET reflects it.
  4. PUT `"tools": []` persists as an explicit empty list (≠ null).
  5. PUT with an unknown tool name → 400 + a clear InvalidToolName
     message, disk untouched.
  6. PUT `"tools": null` preserves the existing value (the collapse of
     absent ≡ null on the wire).

Each test boots a fresh nalar against an isolated tmpdir HOME via the
shared preboot fixture pattern (config_simplify_test.py). Ports come
from the harness's random picker (never 8081).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from harness import (
    FunctionalHarness,
    _default_nalar_bin,
    _find_free_port,
    _reap_orphan_test_pids,
    _wait_ready,
    is_safe_tmp,
)


# ─── Preboot fixture: seed config.json BEFORE the binary starts ──────────


def _platform_config_dir(temp_dir: Path) -> Path:
    """Mirror nalar's `getDefaultConfigDir` (Config.zig) per-OS layout:
      - macOS   → <HOME>/Library/Application Support/nalar/
      - Windows → <APPDATA>/nalar/ (fixture sets the child's APPDATA)
      - else    → <XDG_CONFIG_HOME or HOME/.config>/nalar/
    """
    import platform as _platform
    system = _platform.system()
    if system == "Darwin":
        return temp_dir / "Library" / "Application Support" / "nalar"
    if system == "Windows":
        return temp_dir / "AppData" / "Roaming" / "nalar"
    return temp_dir / ".config" / "nalar"


@pytest.fixture
def preboot(default_nalar_bin):
    """`h = preboot(cfg_dict)` — writes config.json into a fresh tempdir
    layout (at the PLATFORM-CORRECT path), THEN boots nalar against it.
    Yields the booted harness.
    """
    booted: list[FunctionalHarness] = []

    def make(cfg: dict) -> FunctionalHarness:
        # Mirror FunctionalHarness.boot steps 1-5, but seed the config
        # BEFORE spawning the binary (step 7).
        orig_home = os.environ.get("HOME", "") or os.environ.get("USERPROFILE", "")
        if not orig_home:
            try:
                orig_home = str(Path.home())
            except Exception:
                orig_home = ""
        if not orig_home:
            raise RuntimeError("HOME not set; refusing to boot")
        try:
            _reap_orphan_test_pids()
        except Exception as e:
            print(f"warning: orphan reap failed: {e}", file=sys.stderr)

        chosen_port = _find_free_port()
        temp_dir = Path(tempfile.mkdtemp(prefix="nalar-func-"))
        if not is_safe_tmp(str(temp_dir), orig_home):
            raise RuntimeError(f"unsafe tmp path: {temp_dir}")

        config_dir = _platform_config_dir(temp_dir)
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "config.json").write_text(json.dumps(cfg, indent=2))

        bin_path = default_nalar_bin
        log_path = temp_dir / "nalar.log"
        log_file = log_path.open("wb")
        # Snapshot parent Windows/XDG vars so teardown() restores them.
        orig_userprofile = os.environ.get("USERPROFILE", "")
        orig_appdata = os.environ.get("APPDATA", "")
        orig_localappdata = os.environ.get("LOCALAPPDATA", "")
        orig_xdg_config_home = os.environ.get("XDG_CONFIG_HOME", "")
        orig_xdg_state_home = os.environ.get("XDG_STATE_HOME", "")
        orig_xdg_data_home = os.environ.get("XDG_DATA_HOME", "")
        orig_xdg_cache_home = os.environ.get("XDG_CACHE_HOME", "")
        env = os.environ.copy()
        env["HOME"] = str(temp_dir)
        # XDG isolation applies on every platform, not just Windows: on Linux
        # getDefaultConfigDir resolves $XDG_CONFIG_HOME/nalar before
        # $HOME/.config/nalar, so a child that inherits the parent's
        # XDG_CONFIG_HOME (set to /home/runner/.config on the GH ubuntu
        # runner) writes config.json outside temp_dir and the assertions
        # below read a file this server never wrote. Mirrors
        # FunctionalHarness.boot.
        xdg_config = temp_dir / ".config"
        xdg_state = temp_dir / ".local" / "state"
        xdg_data = temp_dir / ".local" / "share"
        xdg_cache = temp_dir / ".cache"
        xdg_config.mkdir(parents=True, exist_ok=True)
        xdg_state.mkdir(parents=True, exist_ok=True)
        xdg_data.mkdir(parents=True, exist_ok=True)
        xdg_cache.mkdir(parents=True, exist_ok=True)
        env["XDG_CONFIG_HOME"] = str(xdg_config)
        env["XDG_STATE_HOME"] = str(xdg_state)
        env["XDG_DATA_HOME"] = str(xdg_data)
        env["XDG_CACHE_HOME"] = str(xdg_cache)
        if os.name == "nt":
            appdata_roaming = temp_dir / "AppData" / "Roaming"
            appdata_local = temp_dir / "AppData" / "Local"
            (appdata_roaming / "nalar").mkdir(parents=True, exist_ok=True)
            appdata_local.mkdir(parents=True, exist_ok=True)
            env["USERPROFILE"] = str(temp_dir)
            env["APPDATA"] = str(appdata_roaming)
            env["LOCALAPPDATA"] = str(appdata_local)
        proc = subprocess.Popen(
            [str(bin_path), "--port", str(chosen_port)],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        try:
            log_file.close()
        except Exception:
            pass
        try:
            (temp_dir / ".harness.pid").write_text(f"{os.getpid()} {proc.pid}\n")
        except OSError:
            pass

        try:
            _wait_ready(chosen_port, 30.0, proc, log_path)
        except Exception:
            proc.kill()
            log_file.close()
            raise

        h = FunctionalHarness(
            port=chosen_port,
            nalar_bin=bin_path,
            temp_dir=temp_dir,
            orig_home=orig_home,
            log_path=log_path,
            pid=proc.pid,
            orig_userprofile=orig_userprofile,
            orig_appdata=orig_appdata,
            orig_localappdata=orig_localappdata,
            orig_xdg_config_home=orig_xdg_config_home,
            orig_xdg_state_home=orig_xdg_state_home,
            orig_xdg_data_home=orig_xdg_data_home,
            orig_xdg_cache_home=orig_xdg_cache_home,
        )
        booted.append(h)
        return h

    try:
        yield make
    finally:
        for h in booted:
            try:
                h.teardown()
            except Exception:
                pass


# ─── Fixtures / helpers ──────────────────────────────────────────────────

PROFILE = {
    "model": "tools-model",
    "base_url": "https://tools.example.com",
    "api_key": "tools-key",
    "url_style": "openai",
}


def _base_config(**extra) -> dict:
    """A profile-only config so the PUT live-reload validates (backfill
    provides the credentials `validate()` requires)."""
    cfg = {
        "profiles_models": {"p1": dict(PROFILE)},
        "active_profile": "p1",
    }
    cfg.update(extra)
    return cfg


def _settings_body(tools_marker=...):
    """The EXACT whole-config shape NalarSettings.vue sends on Save from
    any tab: profiles + operational settings, no top-level LLM defaults.
    `tools_marker=...` (Ellipsis) OMITS the key (another tab's save);
    otherwise the value is included verbatim.
    """
    body = {
        "profiles": {"p1": dict(PROFILE)},
        "active_profile": "p1",
        "mcp_servers": None,
        "notify_on_complete": False,
        "notify_on_error": False,
        "web_launch_enabled": False,
        "model_compaction_size_kb": 100,
        "max_capacity_token_model": None,
        "compaction_threshold_percent": None,
        "retry_delay_ms": 0,
    }
    if tools_marker is not ...:
        body["tools"] = tools_marker
    return body


def _on_disk(h: FunctionalHarness) -> dict:
    return json.loads((_platform_config_dir(h.temp_dir) / "config.json").read_text())


# ─── (a) GET returns tools: null when the key is absent ──────────────────


def test_get_returns_tools_null_when_key_absent(preboot) -> None:
    """A config.json without `tools` serves `tools: null` on the wire —
    the key must be PRESENT so the frontend can tell 'legacy defaults'
    from a backend that never shipped the field."""
    h = preboot(_base_config())

    r = h.http("GET", "/api/config/nalar", expect=200).json()
    assert "tools" in r, f"tools key missing from GET wire: {r!r}"
    assert r["tools"] is None, f"expected tools: null, got {r['tools']!r}"


# ─── (b) Settings save WITHOUT a tools key must not erase it ─────────────


def test_put_without_tools_key_preserves_on_disk_value(preboot) -> None:
    """Seed `tools` first, then PUT the whole config from another tab
    (no `tools` key). The on-disk list and GET must both survive —
    this is the PUT-strip footgun from plan §2.2."""
    seeded = ["command", "read_file", "glob"]
    h = preboot(_base_config(tools=seeded))

    # Sanity: the seed is visible before the save.
    r = h.http("GET", "/api/config/nalar", expect=200).json()
    assert r["tools"] == seeded, f"seed not visible on GET: {r['tools']!r}"

    # Another tab's Settings save — whole config, NO tools key.
    h.http("PUT", "/api/config/nalar", json_body=_settings_body(), expect=200)

    r2 = h.http("GET", "/api/config/nalar", expect=200).json()
    assert r2["tools"] == seeded, (
        f"PUT without a tools key erased the list: {r2['tools']!r}"
    )
    assert _on_disk(h).get("tools") == seeded, (
        f"PUT without a tools key erased tools from disk: {_on_disk(h)!r}"
    )


# ─── (c) PUT with a tools array persists and GET reflects it ─────────────


def test_put_with_tools_array_persists(preboot) -> None:
    h = preboot(_base_config())

    new_list = ["command", "write_file", "kanban_list"]
    h.http(
        "PUT", "/api/config/nalar",
        json_body=_settings_body(tools_marker=new_list),
        expect=200,
    )

    r = h.http("GET", "/api/config/nalar", expect=200).json()
    assert r["tools"] == new_list, f"GET did not reflect PUT: {r['tools']!r}"
    assert _on_disk(h).get("tools") == new_list, (
        f"tools did not land on disk: {_on_disk(h)!r}"
    )


# ─── (d) PUT "tools": [] persists as an explicit empty list ──────────────


def test_put_empty_tools_array_persists(preboot) -> None:
    """`[]` is the explicit-zero checklist (D2). It must round-trip as an
    empty ARRAY — collapsing back to null would snap the UI to the 25
    legacy defaults."""
    h = preboot(_base_config(tools=["command"]))

    h.http("PUT", "/api/config/nalar", json_body=_settings_body(tools_marker=[]),
           expect=200)

    r = h.http("GET", "/api/config/nalar", expect=200).json()
    assert "tools" in r, f"tools key missing from GET wire: {r!r}"
    assert r["tools"] == [], f"expected explicit [], got {r['tools']!r}"
    assert r["tools"] is not None, "[] collapsed to null on the wire"
    assert _on_disk(h).get("tools") == [], (
        f"explicit [] did not land on disk: {_on_disk(h)!r}"
    )


# ─── (e) Unknown tool name → 400 + clear message ─────────────────────────


def test_put_unknown_tool_name_returns_400(preboot) -> None:
    seeded = ["command", "read_file"]
    h = preboot(_base_config(tools=seeded))

    r = h.http(
        "PUT", "/api/config/nalar",
        json_body=_settings_body(tools_marker=["command", "definitely_not_a_tool"]),
        expect=400,
    ).json()
    err = r.get("error", "")
    assert "InvalidToolName" in err, f"missing InvalidToolName in 400 body: {r!r}"
    assert "definitely_not_a_tool" in err, (
        f"400 body does not name the offending tool: {r!r}"
    )

    # Validation runs before any write — the rejected list never lands.
    assert _on_disk(h).get("tools") == seeded, (
        f"rejected PUT mutated the on-disk list: {_on_disk(h)!r}"
    )


# ─── (f) PUT "tools": null preserves the existing value ──────────────────


def test_put_explicit_null_preserves_existing_value(preboot) -> None:
    """An explicit JSON null parses to the same `null` as an absent key
    (the desired collapse) → no change. A Save that sends
    `tools: null` must not wipe the list."""
    seeded = ["command", "glob"]
    h = preboot(_base_config(tools=seeded))

    h.http("PUT", "/api/config/nalar", json_body=_settings_body(tools_marker=None),
           expect=200)

    r = h.http("GET", "/api/config/nalar", expect=200).json()
    assert r["tools"] == seeded, f"explicit null erased the list: {r['tools']!r}"
    assert _on_disk(h).get("tools") == seeded, (
        f"explicit null erased tools from disk: {_on_disk(h)!r}"
    )
