"""Functional tests for the web-launch toggle (browser mode, random port).

Plan: docs/superpowers/plans/2026-09-10-web-launch-toggle.md
Task: task_1789052626064_0

Lifecycle A: the server keeps running regardless of the flag — the flag
only drives the settings UI (URL pill + auto-open) and the startup port
default (random when on, 8081 when off). Covered here:

  Test 1 — GET defaults `web_launch_enabled=false` on a fresh install.
  Test 2 — PUT true round-trips through GET + on-disk config.json.
  Test 3 — PUT false flips an existing true.
  Test 4 — Omitting the key on PUT preserves the on-disk value
           (`?bool = null` "don't touch" sentinel).
  Test 5 — GET /api/web/status reports the live bound port + URL and
           reflects the flag (false → true across a PUT).
  Test 6 — Status URL is reachable (same origin serves the SPA).

The harness boots pabrik on a random free port (never 8081), so Test 5
locks in that the status endpoint reports the LIVE port, not a
hardcoded default.
"""

from __future__ import annotations

import json
import platform
import shutil
from pathlib import Path

import pytest
import urllib.request

from harness import FunctionalHarness


def _platform_config_dir(temp_dir: Path) -> Path:
    system = platform.system()
    if system == "Darwin":
        return temp_dir / "Library" / "Application Support" / "pabrik"
    if system == "Windows":
        import os

        appdata = os.environ.get("APPDATA") or str(temp_dir / "AppData" / "Roaming")
        if appdata.startswith(str(temp_dir)):
            return Path(appdata) / "pabrik"
        return temp_dir / "AppData" / "Roaming" / "pabrik"
    return temp_dir / ".config" / "pabrik"


@pytest.fixture
def web_harness(default_pabrik_bin) -> FunctionalHarness:
    h = FunctionalHarness.boot(
        default_pabrik_bin,
        stub_llm_profile=True,
    )
    if platform.system() == "Darwin":
        linux_cfg = h.temp_dir / ".config" / "pabrik" / "config.json"
        mac_cfg = h.temp_dir / "Library" / "Application Support" / "pabrik" / "config.json"
        if linux_cfg.exists():
            mac_cfg.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(linux_cfg, mac_cfg)
    try:
        yield h
    finally:
        try:
            h.teardown()
        except Exception:
            pass


def _on_disk_config(h: FunctionalHarness) -> dict:
    path = _platform_config_dir(h.temp_dir) / "config.json"
    return json.loads(path.read_text())


def _put_web_launch(
    h: FunctionalHarness,
    *,
    web_launch_enabled: bool | None = None,
    extra: dict | None = None,
) -> None:
    """PUT /api/config/pabrik with the profiles scaffolding the backend
    expects. None omits the key (locks in the null sentinel)."""
    body: dict = {
        "profiles": {
            "stub": {
                "model": "stub-model",
                "base_url": "http://127.0.0.1:1",
                "api_key": "stub-key-not-real",
            }
        },
        "active_profile": "stub",
    }
    if web_launch_enabled is not None:
        body["web_launch_enabled"] = web_launch_enabled
    if extra:
        body.update(extra)
    h.http("PUT", "/api/config/pabrik", json_body=body, expect=200)


def test_get_returns_web_launch_disabled_on_fresh_install(
    web_harness: FunctionalHarness,
) -> None:
    r = web_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert r.get("web_launch_enabled") is False, (
        f"expected web_launch_enabled=false on fresh install; got {r.get('web_launch_enabled')!r}"
    )


def test_put_web_launch_true_round_trips_through_get_and_disk(
    web_harness: FunctionalHarness,
) -> None:
    _put_web_launch(web_harness, web_launch_enabled=True)

    r = web_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert r.get("web_launch_enabled") is True

    on_disk = _on_disk_config(web_harness)
    assert on_disk.get("web_launch_enabled") is True


def test_put_web_launch_false_flips_an_existing_true(
    web_harness: FunctionalHarness,
) -> None:
    _put_web_launch(web_harness, web_launch_enabled=True)
    r1 = web_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert r1.get("web_launch_enabled") is True

    _put_web_launch(web_harness, web_launch_enabled=False)
    r2 = web_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert r2.get("web_launch_enabled") is False
    assert _on_disk_config(web_harness).get("web_launch_enabled") is False


def test_omitting_web_launch_does_not_reset_it(
    web_harness: FunctionalHarness,
) -> None:
    _put_web_launch(web_harness, web_launch_enabled=True)
    assert _on_disk_config(web_harness).get("web_launch_enabled") is True

    _put_web_launch(web_harness)
    r = web_harness.http("GET", "/api/config/pabrik", expect=200).json()
    assert r.get("web_launch_enabled") is True, (
        "omitting web_launch_enabled on PUT must preserve the on-disk value"
    )


def test_web_status_reports_live_port_and_reflects_flag(
    web_harness: FunctionalHarness,
) -> None:
    """GET /api/web/status returns the harness's live random port (not a
    hardcoded 8081) and tracks the flag across a PUT."""
    s1 = web_harness.http("GET", "/api/web/status", expect=200).json()
    assert s1.get("running") is True
    assert s1.get("enabled") is False
    assert s1.get("port") == web_harness.port, (
        f"status port should be the live bound port {web_harness.port}; got {s1.get('port')!r}"
    )
    assert s1.get("url") == f"http://127.0.0.1:{web_harness.port}/", (
        f"unexpected status url: {s1.get('url')!r}"
    )

    _put_web_launch(web_harness, web_launch_enabled=True)
    s2 = web_harness.http("GET", "/api/web/status", expect=200).json()
    assert s2.get("enabled") is True
    assert s2.get("port") == web_harness.port
    assert s2.get("url") == f"http://127.0.0.1:{web_harness.port}/"


def test_web_status_url_serves_http(
    web_harness: FunctionalHarness,
) -> None:
    """The advertised URL origin is actually reachable (lifecycle A: the
    same server serves the UI — no second listener needed). Note: `/`
    itself 404s without `--static-dir` (the harness boots API-only),
    so we assert on `/health`, which proves the origin is live."""
    import urllib.parse

    s = web_harness.http("GET", "/api/web/status", expect=200).json()
    url = s.get("url")
    assert url is not None
    health_url = urllib.parse.urljoin(url, "/health")
    with urllib.request.urlopen(health_url, timeout=10) as resp:
        assert resp.status == 200
