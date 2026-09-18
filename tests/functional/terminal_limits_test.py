"""Functional wire test for terminal max-20 cap + 429.

Replays the EXACT JSON body the frontend sends (see TerminalTab.vue
newSession -> createTerminalSession(cwd, {cols, rows})):

  POST /api/terminal/sessions { cwd, cols, rows } -> 201 { id, pid }
  21st create while 20 live -> 429 { error }

Also verifies a DELETE frees a slot (next create is 201 again).

Busy-exempt idle-kill is covered by Zig unit tests in
terminal_session.zig (isBusyByStamps + sweep with test seams) — the
30min timeout is not fast-forwardable over HTTP, so the harness only
asserts the cap wire contract here.
"""

from __future__ import annotations

from typing import Any

from harness import FunctionalHarness


def _create(
    harness: FunctionalHarness, expect: int = 201
) -> dict[str, Any]:
    r = harness.http(
        "POST",
        "/api/terminal/sessions",
        json_body={"cwd": str(harness.temp_dir), "cols": 80, "rows": 24},
        expect=expect,
    )
    return r.json()


def test_21st_terminal_returns_429(harness: FunctionalHarness) -> None:
    """20 live sessions fill the cap; the 21st is rejected with 429."""
    ids: list[str] = []
    try:
        for _ in range(20):
            created = _create(harness, expect=201)
            assert created["id"]
            ids.append(created["id"])

        rejected = _create(harness, expect=429)
        # makeErrorResponse shape: { error: <message> }
        assert "max 20" in str(rejected.get("error", "")).lower() or "max 20" in str(
            rejected
        ).lower()
    finally:
        for sid in ids:
            harness.http(
                "DELETE", f"/api/terminal/sessions/{sid}", expect=(200, 404)
            )


def test_delete_frees_a_slot(harness: FunctionalHarness) -> None:
    """After DELETE, a new create succeeds again (slot freed)."""
    ids: list[str] = []
    try:
        for _ in range(20):
            ids.append(_create(harness, expect=201)["id"])
        _create(harness, expect=429)

        harness.http("DELETE", f"/api/terminal/sessions/{ids.pop()}", expect=200)
        recreated = _create(harness, expect=201)
        ids.append(recreated["id"])
        assert recreated["id"]
    finally:
        for sid in ids:
            harness.http(
                "DELETE", f"/api/terminal/sessions/{sid}", expect=(200, 404)
            )
