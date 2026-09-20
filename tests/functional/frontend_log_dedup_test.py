"""Functional tests for POST /api/logs dedup (Migration 075 regression).

Replays the EXACT JSON batch the frontend `frontendLogClient.ts`
sends when a `console.error` fires (see the DevTools screenshot in
task_1789917534485_4: `{"events":[{level, kind, message, route_path}]}`).

Regression (2026-09-20): Migration 075 renamed `logs.created_at` →
`logs.created_at_nano`. The POST handler's INSERT and the GET
handler were updated, but the POST dedup SELECT still referenced
`created_at` → every POST failed at the dedup step with
500 `{"error":"Failed to dedup log"}` ("no such column:
created_at" on a production DB that has run all migrations).

Unit tests missed it because their `:memory:` helper only ran
Migration 064 (which creates the OLD column name), so the stale
SQL passed in tests while failing in production. The in-file Zig
tests now mirror the 075 rename; these functional tests lock the
wire behaviour end-to-end against a real binary + real SQLite.

Covers:
  * EXACT-FRONTEND-BODY — the screenshot's batch → 204, no 500.
  * DEDUP-HIT — immediate re-POST of the same batch → 204 and the
    row's `count` becomes 2 (no second row).
  * FRESH-EVENT — a different message → 204 and a second row.
"""

from __future__ import annotations

from harness import FunctionalHarness


# The exact batch shape from the failing DevTools screenshot:
# a console_error for a kanban prefetch failure, enriched with the
# current route_path by frontendLogClient.
def _kanban_fetch_error_batch() -> dict:
    return {
        "events": [
            {
                "level": "error",
                "kind": "console_error",
                "message": "Failed to fetch kanban tasks for item item_178785157619947723",
                "route_path": "app?view=workspace&workspaceId=ws_1785055733544_28e79c9db8950100&itemId=item_1788811112791088699",
            }
        ]
    }


def _get_logs(harness: FunctionalHarness) -> list[dict]:
    r = harness.http("GET", "/api/logs", params={"limit": 100}, expect=200)
    body = r.json()
    assert "logs" in body, f"GET /api/logs should return a logs list, got keys {list(body.keys())}"
    return body["logs"]


def test_exact_frontend_batch_returns_204(harness: FunctionalHarness):
    """The screenshot's batch must persist (204), not 500 dedup-fail."""
    harness.http("POST", "/api/logs", json_body=_kanban_fetch_error_batch(), expect=204)

    rows = _get_logs(harness)
    mine = [l for l in rows if l["message"] == "Failed to fetch kanban tasks for item item_178785157619947723"]
    assert len(mine) == 1, f"expected 1 persisted row, got {len(mine)}: {rows!r}"
    assert mine[0]["kind"] == "console_error"
    assert mine[0]["count"] == 1


def test_immediate_repost_dedups_to_count_2(harness: FunctionalHarness):
    """Same batch within the 1s window → 204 + count=2, still 1 row."""
    batch = _kanban_fetch_error_batch()
    harness.http("POST", "/api/logs", json_body=batch, expect=204)
    harness.http("POST", "/api/logs", json_body=batch, expect=204)

    rows = _get_logs(harness)
    mine = [l for l in rows if l["message"] == "Failed to fetch kanban tasks for item item_178785157619947723"]
    assert len(mine) == 1, f"dedup should keep 1 row, got {len(mine)}: {rows!r}"
    assert mine[0]["count"] == 2, f"dedup re-POST should bump count to 2, got {mine[0]['count']!r}"


def test_different_message_inserts_second_row(harness: FunctionalHarness):
    """A distinct message must not dedup — it inserts a fresh row."""
    harness.http("POST", "/api/logs", json_body=_kanban_fetch_error_batch(), expect=204)
    harness.http(
        "POST",
        "/api/logs",
        json_body={"events": [{"level": "warn", "kind": "console_warn", "message": "unrelated warning"}]},
        expect=204,
    )

    rows = _get_logs(harness)
    messages = sorted(l["message"] for l in rows)
    assert "Failed to fetch kanban tasks for item item_178785157619947723" in messages
    assert "unrelated warning" in messages
    assert len(rows) == 2, f"expected 2 rows, got {len(rows)}: {messages!r}"
