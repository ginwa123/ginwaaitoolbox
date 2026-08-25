"""Functional tests for the Nalar General settings
(plan 2026-08-25-notify-on-error-and-retry-ms-in-settings, task_1787671269086_0).

These tests exercise the wire shape of three operational settings that
the new "General" tab in Nalar Settings writes through:

  1. `notify_on_complete` (existing config.json field, but previously
     hidden from the UI) — opt-in OS notification on `finish_reason = "stop"`.
  2. `notify_on_error` (NEW field added by this plan) — opt-in OS
     notification on transport failure / TooManyRetries / outer catch.
  3. `retry_delay_ms` (existing field, hidden from the UI) — workflow
     backoff between failed LLM retries. Range 0–60 000; values > 60 000
     clamp to 60 000 at the PUT layer (see nalar_config_put.zig:133-135).

The functional harness boots a real nalar binary against an isolated
tmpdir HOME (boilerplate from `nalar_config_test.py`). Each test asserts
on the EXACT wire payload the frontend sends (or would send) + the
on-disk `config.json` to lock in the user-visible behavior.

Why this matters (recap of the 3 bugs the wire-rationalization skill
calls out):

  * **Route-order shadowing** — N/A here; /api/config/nalar is the only
    handler that touches these three fields.
  * **Empty-slice-as-NULL binding** — the PUT body's `notify_on_error`
    is typed `?bool = null`; an absent key MUST be treated as "don't
    touch", not as "set to false". Functional test below locks this
    in by reading the on-disk JSON after an omit-key PUT.
  * **Strict validators treating "" as a value** — N/A; we never send
    an empty string for these three fields.

Test outline:

  Test 1 — Defaults are seeded when the on-disk config is missing.
  Test 2 — PUT round-trips `notify_on_error` true → on-disk → GET.
  Test 3 — PUT with `notify_on_error: false` flips an existing true.
  Test 4 — Omitting `notify_on_error` on PUT does NOT touch the
           existing on-disk value (null = "don't touch" sentinel).
  Test 5 — Independent of `notify_on_complete` (write both, GET both,
           toggling one doesn't reset the other).
  Test 6 — `retry_delay_ms` is clamped to [0, 60_000] at the PUT layer.
  Test 7 — On-disk JSON shape preserves all three fields.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
from pathlib import Path

import pytest

from harness import FunctionalHarness


# ─── Cross-platform config path helper ──────────────────────────────────────
#
# nalar's `getDefaultConfigDir` is platform-specific; the harness writes
# the stub config to <HOME>/.config/nalar/ (Linux-style), so on macOS the
# stub installer writes to the WRONG path and we copy the file to the
# macOS-style location. To find the file the running nalar instance
# ACTUALLY reads, we mirror `getDefaultConfigDir` here.


def _platform_config_dir(temp_dir: Path) -> Path:
    """Mirror `nalar_config_get.zig::getDefaultConfigDir` per-OS layout:
      - macOS   → <HOME>/Library/Application Support/nalar/
      - Windows → <APPDATA>/nalar/
      - else    → <XDG_CONFIG_HOME or HOME/.config>/nalar/
    """
    system = platform.system()
    if system == "Darwin":
        return temp_dir / "Library" / "Application Support" / "nalar"
    if system == "Windows":
        appdata = os.environ.get("APPDATA") or str(temp_dir / "AppData" / "Roaming")
        if appdata.startswith(str(temp_dir)):
            return Path(appdata) / "nalar"
        return temp_dir / "AppData" / "Roaming" / "nalar"
    return temp_dir / ".config" / "nalar"


# ─── Custom harness fixture ────────────────────────────────────────────────


@pytest.fixture
def config_harness(default_nalar_bin) -> FunctionalHarness:
    """Boot nalar with `stub_llm_profile=True` so the harness
    pre-installs a `stub` profile (see harness.py::_write_stub_llm_profile).
    Cross-platform path shim: the harness writes the stub to the
    Linux-style `<HOME>/.config/nalar/config.json`, so on macOS we
    copy the file to the macOS path before nalar boots and reads it.
    """
    h = FunctionalHarness.boot(
        default_nalar_bin,
        stub_llm_profile=True,
    )
    if platform.system() == "Darwin":
        linux_cfg = h.temp_dir / ".config" / "nalar" / "config.json"
        mac_cfg = h.temp_dir / "Library" / "Application Support" / "nalar" / "config.json"
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


# ─── Helpers ────────────────────────────────────────────────────────────────


def _on_disk_config(h: FunctionalHarness) -> dict:
    """Read the on-disk config.json the running nalar loaded at boot.
    Mirrors _platform_config_dir above so the test reads what nalar reads.
    """
    path = _platform_config_dir(h.temp_dir) / "config.json"
    return json.loads(path.read_text())


def _put_general_settings(
    h: FunctionalHarness,
    *,
    profiles: dict | None = None,
    active_profile: str | None = None,
    notify_on_complete: bool | None = None,
    notify_on_error: bool | None = None,
    retry_delay_ms: int | None = None,
    extra: dict | None = None,
) -> None:
    """PUT `/api/config/nalar` with the General settings fields plus
    the bare-minimum profile / active_profile scaffolding the backend
    expects (the live-reload validator refuses an empty profiles map).

    Passing None for a setting omits that key on the wire — locks in
    the `?bool = null` / `?u32 = null` "don't touch" sentinel.
    """
    body: dict = {}
    if profiles is not None:
        body["profiles"] = profiles
    if active_profile is not None:
        body["active_profile"] = active_profile
    if notify_on_complete is not None:
        body["notify_on_complete"] = notify_on_complete
    if notify_on_error is not None:
        body["notify_on_error"] = notify_on_error
    if retry_delay_ms is not None:
        body["retry_delay_ms"] = retry_delay_ms
    if extra:
        body.update(extra)
    h.http("PUT", "/api/config/nalar", json_body=body, expect=200)


def _stub_profile() -> dict:
    """Bare-minimum profile payload: the same `stub` profile the
    harness installer writes, minus the API key (not needed for the
    PUT round-trip when the live-reload validator skips auth checks).
    """
    return {
        "stub": {
            "model": "stub-model",
            "base_url": "http://127.0.0.1:1",
            "api_key": "stub-key-not-real",
        }
    }


# ─── Test 1: defaults are seeded when the on-disk config is missing ────────


def test_get_returns_default_values_for_new_install(
    config_harness: FunctionalHarness,
) -> None:
    """A fresh harness has the on-disk config seeded by the stub
    installer (only `profiles_models` + `selected_profile_model`).
    GET /api/config/nalar MUST default the new fields to safe
    zero values:

      - `notify_on_complete: false`
      - `notify_on_error: false`     ← NEW field (plan 2026-08-25)
      - `retry_delay_ms: 0`

    The frontend uses these as the initial UI state via
    `syncFromConfig(... ?? false)` / `?? 0`.
    """
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("notify_on_complete") is False, (
        f"expected notify_on_complete=false on a fresh install; got {r.get('notify_on_complete')!r}"
    )
    assert r.get("notify_on_error") is False, (
        f"expected notify_on_error=false on a fresh install; got {r.get('notify_on_error')!r}"
    )
    assert r.get("retry_delay_ms") == 0, (
        f"expected retry_delay_ms=0 on a fresh install; got {r.get('retry_delay_ms')!r}"
    )


# ─── Test 2: PUT notify_on_error: true round-trips through GET + on-disk ───


def test_put_notify_on_error_true_round_trips_through_get_and_disk(
    config_harness: FunctionalHarness,
) -> None:
    """PUT {notify_on_error: true} → GET returns `true` AND the
    on-disk config.json shows `"notify_on_error": true`. This is
    the exact wire body the General tab sends when the user toggles
    "Notify when agent fails" on and clicks Save.
    """
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_complete=False,
        notify_on_error=True,
        retry_delay_ms=0,
    )

    # GET → field is true.
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("notify_on_error") is True, (
        f"notify_on_error should be true after PUT; got {r.get('notify_on_error')!r}"
    )

    # On-disk JSON → field is true (NOT just the in-memory reload).
    on_disk = _on_disk_config(config_harness)
    assert on_disk.get("notify_on_error") is True, (
        f"on-disk notify_on_error should be true; got {on_disk.get('notify_on_error')!r}"
    )


# ─── Test 3: explicit false flips an existing true ─────────────────────────


def test_put_notify_on_error_false_flips_an_existing_true(
    config_harness: FunctionalHarness,
) -> None:
    """Scenario: user has `notify_on_error: true` enabled. They
    toggle it OFF in the General tab and Save. PUT {notify_on_error:
    false} MUST persist, not silently default to true. This locks in
    the `if (input.notify_on_error) |n| { config_json.notify_on_error
    = n; }` apply block — a future refactor that only writes `true`
    (or only treats absent as `false`) would surface here.
    """
    # Seed: ON first.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_error=True,
    )
    # Sanity: GET shows true.
    r1 = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r1.get("notify_on_error") is True

    # Now toggle OFF.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_error=False,
    )
    # GET shows false; on-disk shows false.
    r2 = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r2.get("notify_on_error") is False, (
        f"notify_on_error should be false after explicit-false PUT; got {r2.get('notify_on_error')!r}"
    )
    on_disk = _on_disk_config(config_harness)
    assert on_disk.get("notify_on_error") is False, (
        f"on-disk notify_on_error should be false; got {on_disk.get('notify_on_error')!r}"
    )


# ─── Test 4: omitting notify_on_error on PUT preserves the on-disk value ───


def test_omitting_notify_on_error_does_not_reset_it(
    config_harness: FunctionalHarness,
) -> None:
    """The wire contract: a PUT body that omits `notify_on_error`
    leaves the on-disk value untouched. The TypeScript frontend uses
    `?bool = null` semantics — every save round-trip sends ALL three
    keys explicitly because NalarSettings.syncToConfig writes them
    through unconditionally, but the backend's apply block MUST be
    tolerant of omit (a curl script or a future refactor shouldn't
    accidentally wipe the toggle on save).

    Without the `if (input.notify_on_error) |n|` guard, the apply
    block would assign `null` (which the field type doesn't allow —
    `bool = false`), so the test indirectly verifies the guard exists.
    """
    # Seed: ON.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_complete=False,
        notify_on_error=True,
        retry_delay_ms=10_000,
    )
    on_disk_before = _on_disk_config(config_harness)
    assert on_disk_before.get("notify_on_error") is True
    assert on_disk_before.get("retry_delay_ms") == 10_000

    # PUT a body that ONLY carries `profiles` + `active_profile` —
    # no notify_on_error, no notify_on_complete, no retry_delay_ms.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
    )

    # GET shows the field is STILL true (untouched).
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("notify_on_error") is True, (
        f"omitting notify_on_error on PUT must preserve on-disk value; got {r.get('notify_on_error')!r}"
    )

    # On-disk check — exact value persisted.
    on_disk_after = _on_disk_config(config_harness)
    assert on_disk_after.get("notify_on_error") is True, (
        f"on-disk notify_on_error should still be true; got {on_disk_after.get('notify_on_error')!r}"
    )
    # While we're at it, retry_delay_ms should also be preserved.
    assert on_disk_after.get("retry_delay_ms") == 10_000, (
        f"on-disk retry_delay_ms should be untouched; got {on_disk_after.get('retry_delay_ms')!r}"
    )


# ─── Test 5: notify_on_error + notify_on_complete are independent ──────────


def test_notify_on_error_and_notify_on_complete_are_independent(
    config_harness: FunctionalHarness,
) -> None:
    """Both flags live on the wire shape as plain booleans. A PUT
    that sets BOTH independent values MUST round-trip BOTH. A future
    refactor that collapses them into a single tri-state `notif`
    enum would surface here (e.g. via only-on-complete surviving).
    """
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_complete=True,
        notify_on_error=False,
    )

    r1 = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r1.get("notify_on_complete") is True
    assert r1.get("notify_on_error") is False

    # Flip ONLY notify_on_error; complete stays true.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_complete=True,   # set again to model the frontend's
                                   # unconditional write-through
        notify_on_error=True,
    )

    r2 = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r2.get("notify_on_complete") is True, (
        f"notify_on_complete should be unchanged; got {r2.get('notify_on_complete')!r}"
    )
    assert r2.get("notify_on_error") is True, (
        f"notify_on_error should be true; got {r2.get('notify_on_error')!r}"
    )

    # Disk check.
    on_disk = _on_disk_config(config_harness)
    assert on_disk.get("notify_on_complete") is True
    assert on_disk.get("notify_on_error") is True


# ─── Test 6: retry_delay_ms clamps to [0, 60_000] on PUT ───────────────────


def test_retry_delay_ms_clamps_to_60_000_on_put(
    config_harness: FunctionalHarness,
) -> None:
    """The backend's apply block clamps retry_delay_ms to 60_000:
    values > 60_000 would let a user lock themselves out of
    cancelable recovery (one cancellation would have to wait the
    full delay). The frontend's number input also clamps at 60
    seconds (60_000 ms), so even the worst-case user input is safe.

    Lock the boundary behavior:

      - 0           → 0       (0 = no delay, the default)
      - 30_000      → 30_000  (in range)
      - 60_000      → 60_000  (max boundary)
      - 60_001      → 60_000  (just above → clamp)
      - 999_999     → 60_000  (way above → clamp)
    """
    # In-range → unchanged.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        retry_delay_ms=30_000,
    )
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("retry_delay_ms") == 30_000, (
        f"retry_delay_ms=30000 should round-trip; got {r.get('retry_delay_ms')!r}"
    )

    # At the boundary → unchanged.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        retry_delay_ms=60_000,
    )
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("retry_delay_ms") == 60_000, (
        f"retry_delay_ms=60000 should round-trip at the boundary; got {r.get('retry_delay_ms')!r}"
    )

    # Just above the boundary → clamps to 60_000.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        retry_delay_ms=60_001,
    )
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("retry_delay_ms") == 60_000, (
        f"retry_delay_ms=60001 should clamp to 60000; got {r.get('retry_delay_ms')!r}"
    )

    # Way above → clamps to 60_000. Also on-disk.
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        retry_delay_ms=999_999,
    )
    r = config_harness.http("GET", "/api/config/nalar", expect=200).json()
    assert r.get("retry_delay_ms") == 60_000, (
        f"retry_delay_ms=999999 should clamp to 60000; got {r.get('retry_delay_ms')!r}"
    )
    on_disk = _on_disk_config(config_harness)
    assert on_disk.get("retry_delay_ms") == 60_000, (
        f"on-disk retry_delay_ms should be clamped to 60000; got {on_disk.get('retry_delay_ms')!r}"
    )


# ─── Test 7: on-disk JSON shape preserves all three operational fields ─────


def test_on_disk_json_shape_preserves_all_three_operational_fields(
    config_harness: FunctionalHarness,
) -> None:
    """After a SET-all-three PUT, the on-disk config.json must
    literally contain all three keys with the expected values. This
    is the user-visible artifact — every reload (server restart,
    settings re-fetch) reads this file. If a future refactor
    introduces a transformation that drops, renames, or aliases any
    of the three keys, this test surfaces it.
    """
    _put_general_settings(
        config_harness,
        profiles=_stub_profile(),
        active_profile="stub",
        notify_on_complete=True,
        notify_on_error=True,
        retry_delay_ms=15_000,
    )

    on_disk = _on_disk_config(config_harness)

    # Exact keys, exact values.
    assert "notify_on_complete" in on_disk, (
        f"on-disk config missing 'notify_on_complete': keys={list(on_disk.keys())}"
    )
    assert "notify_on_error" in on_disk, (
        f"on-disk config missing 'notify_on_error': keys={list(on_disk.keys())}"
    )
    assert "retry_delay_ms" in on_disk, (
        f"on-disk config missing 'retry_delay_ms': keys={list(on_disk.keys())}"
    )

    # Direct equality (no ?bool / ?u32 ambiguity on disk — it's JSON).
    assert on_disk["notify_on_complete"] is True
    assert on_disk["notify_on_error"] is True
    assert on_disk["retry_delay_ms"] == 15_000
