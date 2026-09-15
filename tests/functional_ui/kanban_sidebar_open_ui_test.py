"""Reproduce: left-clicking a kanban workspace item in the sidebar must open the board.

Seeds a workspace + kanban via the backend API, loads ``/app`` (so the
sidebar tree is the entry point, not a deep link), clicks the kanban
row, and asserts the KanbanView board appears. Collects console errors
and page exceptions for diagnosis.

Run:
    NALAR_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/nalar \
      /home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest \
      tests/functional_ui/kanban_sidebar_open_ui_test.py -v -s
"""

from __future__ import annotations

from ui_harness import UIHarness


def _create_workspace(h: UIHarness, name: str = "ui-kanban-open-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(h: UIHarness, workspace_id: str, name: str = "UIOPEN_BOARD") -> str:
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body={"name": name},
        expect=201,
    )
    return r.json()["item"]["id"]


def test_sidebar_click_kanban_opens_board(ui_harness: UIHarness, page) -> None:
    """Clicking the kanban row in the sidebar opens its board."""
    h = ui_harness
    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id)

    errors: list[str] = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.on("pageerror", lambda exc: errors.append(str(exc)))

    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=30000)

    # Sidebar must list the seeded workspace.
    ws_row = page.locator("text=ui-kanban-open-ws").first
    ws_row.wait_for(timeout=20000, state="visible")

    # The item row may be hidden until its workspace is expanded.
    item_row = page.locator("text=UIOPEN_BOARD").first
    try:
        item_row.wait_for(timeout=3000, state="visible")
    except Exception:
        ws_row.click()
        item_row.wait_for(timeout=10000, state="visible")

    item_row.click()

    board = page.locator(f'[data-testid="kanban-view-{kanban_id}-columns"]')
    try:
        board.wait_for(timeout=20000, state="visible")
    finally:
        if errors:
            print("\n[console errors during kanban open]")
            for e in errors:
                print(f"  - {e[:300]}")
    assert board.is_visible(), (
        f"Kanban board did not open after sidebar click "
        f"(ws={ws_id}, kanban={kanban_id}). See console errors above / artifacts screenshot."
    )
def test_sidebar_rightclick_kanban_go_to_settings_opens_new_tab(
    ui_harness: UIHarness, page
) -> None:
    """Right-clicking the kanban row shows Go to settings; it opens a new tab."""
    h = ui_harness
    ws_id = _create_workspace(h, name="ui-kanban-menu-ws")
    kanban_id = _create_kanban(h, ws_id, name="UIMENU_BOARD")

    errors: list[str] = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.on("pageerror", lambda exc: errors.append(str(exc)))

    page.goto(h.web_url("/app"), wait_until="domcontentloaded", timeout=30000)
    page.locator("text=ui-kanban-menu-ws").first.wait_for(timeout=20000, state="visible")

    item_row = page.locator("text=UIMENU_BOARD").first
    try:
        item_row.wait_for(timeout=3000, state="visible")
    except Exception:
        page.locator("text=ui-kanban-menu-ws").first.click()
        item_row.wait_for(timeout=10000, state="visible")

    item_row.click(button="right")

    entry = page.locator('[data-testid="go-to-settings-item"]')
    entry.wait_for(timeout=10000, state="visible")

    with page.expect_popup() as popup_info:
        entry.click()
    popup = popup_info.value
    popup.wait_for_load_state("domcontentloaded", timeout=30000)
    assert f"/app/kanban/{kanban_id}/settings" in popup.url, (
        f"Settings popup opened at unexpected URL: {popup.url}"
    )
    # The current tab must stay put (never navigates to settings itself).
    assert "/settings" not in page.url, f"Current tab navigated: {page.url}"
    popup.close()
    if errors:
        print("\n[console errors during settings popup]")
        for e in errors:
            print(f"  - {e[:300]}")
