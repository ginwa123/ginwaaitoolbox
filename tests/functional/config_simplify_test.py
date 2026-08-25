"""Functional tests for the config-simplify change (plan
2026-08-24-config-simplify-remove-defaults).

Verifies the wire round-trip after removing the top-level LLM defaults
(api_key/model/base_url/url_style/max_tokens/system_prompt) from
config.json:

  1. A config WITHOUT top-level keys but WITH a profile + active_profile
     boots fine; GET /api/config/nalar returns a profile-only payload.
  2. PUT with a body that omits the defaults entirely (exactly what the
     new frontend sends) → 200; the on-disk file does NOT gain any of
     the six removed keys; profiles survive.
  3. OLD-format compat: a config WITH top-level keys still boots and
     serves (present keys win over backfill).
  4. PUT live-reload succeeds on a profile-only config (backfill provides
     the credentials the validator requires).

Each test boots a fresh nalar against an isolated tmpdir HOME. Ports are
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
      - Windows → <APPDATA>/nalar/
      - else    → <XDG_CONFIG_HOME or HOME/.config>/nalar/
    """
    import platform as _platform
    system = _platform.system()
    if system == "Darwin":
        return temp_dir / "Library" / "Application Support" / "nalar"
    if system == "Windows":
        appdata = os.environ.get("APPDATA") or str(temp_dir / "AppData" / "Roaming")
        # The harness shadows HOME, not APPDATA; resolve relative to temp_dir.
        if appdata.startswith(str(temp_dir)):
            return Path(appdata) / "nalar"
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
        orig_home = os.environ.get("HOME", "")
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
        env = os.environ.copy()
        env["HOME"] = str(temp_dir)
        proc = subprocess.Popen(
            [str(bin_path), "--port", str(chosen_port)],
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
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
    boots cleanly. GET /api/config/nalar → 200 with `profiles` present
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

    r = h.http("GET", "/api/config/nalar", expect=200).json()
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
    h.http("PUT", "/api/config/nalar", json_body=put_body, expect=200)

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

    r = h.http("GET", "/api/config/nalar", expect=200).json()
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
        "PUT", "/api/config/nalar",
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
