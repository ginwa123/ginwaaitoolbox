"""Functional tests for the config-simplify change (plan
2026-08-24-config-simplify-remove-defaults).

Verifies the wire round-trip after removing the top-level LLM defaults
(api_key/model/base_url/url_style/max_tokens/system_prompt) from
config.json:

  1. A config WITHOUT top-level keys but WITH a profile + active_profile
     boots fine; GET /api/config/pabrik returns a profile-only payload.
  2. PUT with a body that omits the defaults entirely (exactly what the
     new frontend sends) → 200; the on-disk file does NOT gain any of
     the six removed keys; profiles survive.
  3. OLD-format compat: a config WITH top-level keys still boots and
     serves (present keys win over backfill).
  4. PUT live-reload succeeds on a profile-only config (backfill provides
     the credentials the validator requires).

Each test boots a fresh pabrik against an isolated tmpdir HOME. Ports are
picked in 8080..8199 — never 8081.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

from harness import (
    FunctionalHarness,
    _default_pabrik_bin,
    _find_free_port,
    _reap_orphan_test_pids,
    _wait_ready,
    is_safe_tmp,
    snapshot_parent_env,
)


# ─── Preboot fixture: seed config.json BEFORE the binary starts ──────────


def _platform_config_dir(temp_dir: Path) -> Path:
    """Mirror pabrik's `getDefaultConfigDir` (Config.zig) per-OS layout:
      - macOS   → <HOME>/Library/Application Support/pabrik/
      - Windows → <APPDATA>/pabrik/ (the preboot fixture sets the
        child's APPDATA to <temp_dir>/AppData/Roaming, so this is
        deterministic — it does NOT read the parent's APPDATA, which
        points at the real home)
      - else    → <XDG_CONFIG_HOME or HOME/.config>/pabrik/
    """
    import platform as _platform
    system = _platform.system()
    if system == "Darwin":
        return temp_dir / "Library" / "Application Support" / "pabrik"
    if system == "Windows":
        return temp_dir / "AppData" / "Roaming" / "pabrik"
    return temp_dir / ".config" / "pabrik"


@pytest.fixture
def preboot(default_pabrik_bin):
    """`h = preboot(cfg_dict)` — writes config.json into a fresh tempdir
    layout (at the PLATFORM-CORRECT path), THEN boots pabrik against it.
    Yields the booted harness.
    """
    booted: list[FunctionalHarness] = []

    def make(cfg: dict) -> FunctionalHarness:
        # Mirror FunctionalHarness.boot steps 1-5, but seed the config
        # BEFORE spawning the binary (step 7).
        orig_home = os.environ.get("HOME", "") or os.environ.get("USERPROFILE", "")
        if not orig_home:
            # Windows has no HOME by default; fall back like boot() does.
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
        temp_dir = Path(tempfile.mkdtemp(prefix="pabrik-func-"))
        if not is_safe_tmp(str(temp_dir), orig_home):
            raise RuntimeError(f"unsafe tmp path: {temp_dir}")

        config_dir = _platform_config_dir(temp_dir)
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "config.json").write_text(json.dumps(cfg, indent=2))

        bin_path = default_pabrik_bin
        log_path = temp_dir / "pabrik.log"
        log_file = log_path.open("wb")
        # Snapshot parent Windows/XDG vars so teardown() restores them
        # (the fixture never shadows the parent env, unlike boot()).
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
        # getDefaultConfigDir resolves $XDG_CONFIG_HOME/pabrik before
        # $HOME/.config/pabrik, so a child that inherits the parent's
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
            # Windows pabrik reads %APPDATA%/pabrik/config.json
            # (Config.zig windows branch) — NOT HOME/.config. Point
            # the child's APPDATA/LOCALAPPDATA/USERPROFILE at
            # the tempdir (mirroring FunctionalHarness.boot); without
            # this the binary reads/writes the REAL %APPDATA% config
            # and the seeded file is invisible (all 4 tests fail +
            # the runner's real config gets clobbered by PUTs).
            appdata_roaming = temp_dir / "AppData" / "Roaming"
            appdata_local = temp_dir / "AppData" / "Local"
            (appdata_roaming / "pabrik").mkdir(parents=True, exist_ok=True)
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
            pabrik_bin=bin_path,
            temp_dir=temp_dir,
            orig_home=orig_home,
            log_path=log_path,
            pid=proc.pid,
            # Pass the Popen handle too. FunctionalHarness._wait_dead
            # answers "is the server dead?" from this handle via poll();
            # without it the harness has to fall back to probing the bare
            # pid, which on Windows cannot distinguish an exited process
            # from a live one.
            _proc=proc,
            orig_userprofile=orig_userprofile,
            orig_appdata=orig_appdata,
            orig_localappdata=orig_localappdata,
            orig_xdg_config_home=orig_xdg_config_home,
            orig_xdg_state_home=orig_xdg_state_home,
            orig_xdg_data_home=orig_xdg_data_home,
            orig_xdg_cache_home=orig_xdg_cache_home,
            # This helper builds a child `env` dict and never shadows the
            # PARENT process, so `_env_shadowed` is empty — but teardown
            # still needs an exact snapshot. Without one it restores HOME
            # from the synthesised `orig_home` (which on Windows is derived
            # from USERPROFILE), inventing a variable that never existed.
            _env_backup=snapshot_parent_env(),
            _env_shadowed={},
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


# ─── Test 1: profile-only config boots; GET has no default fields ────────


def test_profile_only_config_boots_and_get_has_no_default_fields(preboot) -> None:
    """A config.json without top-level api_key/model/base_url/url_style
    boots cleanly. GET /api/config/pabrik → 200 with `profiles` present
    and NONE of the removed keys on the wire.
    """
    h = preboot({
        "profiles_models": {
            "alpha": {
                "model": "alpha-model",
                "base_url": "https://alpha.example.com",
                "api_key": "alpha-key",
                "url_style": "anthropic",
            },
        },
        "active_profile": "alpha",
        "notify_on_complete": True,
        "retry_delay_ms": 1000,
    })

    r = h.http("GET", "/api/config/pabrik", expect=200).json()
    profiles = r.get("profiles") or {}
    assert "alpha" in profiles, f"profile missing from GET: {r!r}"
    assert profiles["alpha"]["model"] == "alpha-model"
    assert r.get("active_profile") == "alpha"

    for key in ("api_endpoint", "api_key", "model", "url_style",
                "temperature", "max_tokens", "system_prompt"):
        assert key not in r, (
            f"removed top-level default '{key}' still on GET wire: {r!r}"
        )


# ─── Test 2: PUT without defaults never writes them to disk ─────────────


def test_put_without_defaults_keeps_file_clean(preboot) -> None:
    """PUT exactly what the new frontend sends (no top-level defaults)
    → 200; the on-disk config.json gains none of the six keys; the
    PUT'd profile survives.
    """
    h = preboot({
        "profiles_models": {},
        "active_profile": None,
    })

    put_body = {
        "profiles": {
            "work": {
                "model": "work-model",
                "base_url": "https://work.example.com",
                "api_key": "work-key",
                "url_style": "openai",
            },
        },
        "active_profile": "work",
        "notify_on_complete": False,
        "retry_delay_ms": 500,
    }
    h.http("PUT", "/api/config/pabrik", json_body=put_body, expect=200)

    on_disk = json.loads(
        (_platform_config_dir(h.temp_dir) / "config.json").read_text()
    )
    for key in ("api_key", "model", "base_url", "url_style",
                "max_tokens", "system_prompt"):
        assert key not in on_disk, (
            f"PUT re-wrote removed key '{key}' to disk: {on_disk!r}"
        )
    assert "work" in (on_disk.get("profiles_models") or {})
    assert on_disk.get("active_profile") == "work"
    assert on_disk.get("retry_delay_ms") == 500


# ─── Test 3: old-format config (with top-level keys) still boots ─────────


def test_old_format_config_still_boots(preboot) -> None:
    """Backward compat: a legacy config WITH top-level keys boots and
    serves. Present keys win over backfill — the server starts exactly
    as it did before this change.
    """
    h = preboot({
        "api_key": "legacy-key",
        "model": "legacy-model",
        "base_url": "https://legacy.example.com",
        "url_style": "openai",
        "profiles_models": {
            "p1": {
                "model": "p1-model",
                "base_url": "https://p1.example.com",
                "api_key": "p1-key",
                "url_style": "openai",
            },
        },
        "active_profile": "p1",
    })

    r = h.http("GET", "/api/config/pabrik", expect=200).json()
    assert "p1" in (r.get("profiles") or {})
    assert r.get("active_profile") == "p1"


# ─── Test 4: PUT live-reload succeeds on a profile-only config ───────────


def test_put_live_reload_succeeds_on_profile_only_config(preboot) -> None:
    """The PUT handler live-reloads LlmConfig from disk after saving.
    On a profile-only config the reload must SUCCEED (backfill provides
    the credentials validate() requires) — no degraded error body.
    """
    h = preboot({
        "profiles_models": {
            "solo": {
                "model": "solo-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "solo-key",
                "url_style": "openai",
            },
        },
        "active_profile": "solo",
    })

    body = h.http(
        "PUT", "/api/config/pabrik",
        json_body={"retry_delay_ms": 250},
        expect=200,
    ).json()
    err = body.get("error", "")
    assert "failed" not in err.lower(), (
        f"PUT live-reload degraded on profile-only config: {body!r}"
    )

    # And the value landed on disk.
    on_disk = json.loads(
        (_platform_config_dir(h.temp_dir) / "config.json").read_text()
    )
    assert on_disk.get("retry_delay_ms") == 250
