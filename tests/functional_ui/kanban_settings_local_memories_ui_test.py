"""Playwright UI tests for Local Memories embedded inside the Agent tab.

After the move (task_1788364730728_5), Local Memories is no longer a
standalone tab in Kanban Settings — it lives inside the Agent tab as
a section below the AgentView (Knowledge + Tools + System Prompt).
This suite verifies:

  1. The standalone "Local Memories" tab is gone (only Columns + Agent remain).
  2. Opening the Agent tab renders the Local Memories section when the
     kanban has a path, and the section actually lists memories.
  3. When the kanban has no path, the Agent tab shows the no-path hint
     instead of the memories listing.
  4. Legacy ?tab=memories still lands on the Agent tab (backward compat).

No real LLM is invoked. The point is to verify the *render + read path*
of the embedded memories listing.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Any

import pytest

from ui_harness import UIHarness


# ─── Helpers ────────────────────────────────────────────────────────────────


def _create_workspace(h: UIHarness, name: str = "ui-kanban-mem-ws") -> str:
    r = h.http("POST", "/api/workspaces", json_body={"name": name}, expect=201)
    return r.json()["id"]


def _create_kanban(
    h: UIHarness, workspace_id: str, name: str = "ui kanban mem", path: str | None = None
) -> str:
    body: dict[str, Any] = {"name": name}
    if path is not None:
        body["path"] = path
    r = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/items/kanban",
        json_body=body,
        expect=201,
    )
    return r.json()["item"]["id"]


def _kanban_settings_url(
    h: UIHarness, kanban_id: str, tab: str | None = None
) -> str:
    """Kanban Settings is a path route: /app/kanban/:itemId/settings."""
    base = f"/app/kanban/{kanban_id}/settings"
    if tab:
        base += f"?tab={tab}"
    return h.web_url(base)


def _wait_for_agent_panel(page, timeout_ms: int = 20000) -> None:
    page.locator('[data-testid="kanban-settings-page-agent-panel"]').first.wait_for(
        timeout=timeout_ms, state="visible"
    )


# ─── Tests ──────────────────────────────────────────────────────────────────


def test_no_standalone_local_memories_tab(ui_harness: UIHarness, page) -> None:
    """Kanban Settings now has only 2 tabs: Columns and Agent."""
    h = ui_harness
    ws_id = _create_workspace(h)
    # Even with a path, there should be no standalone memories tab.
    tmpdir = tempfile.mkdtemp(prefix="nalar-kanban-mem-test-")
    try:
        kanban_id = _create_kanban(h, ws_id, path=tmpdir)

        page.goto(_kanban_settings_url(h, kanban_id), wait_until="domcontentloaded", timeout=30000)
        page.locator('[data-testid="kanban-settings-page-tabs"]').wait_for(timeout=15000, state="visible")

        # Only Columns + Agent tabs should exist.
        tabs = page.locator('[data-testid^="kanban-settings-page-tab-"]')
        tab_ids = [tabs.nth(i).get_attribute("data-testid") for i in range(tabs.count())]
        assert "kanban-settings-page-tab-columns" in tab_ids
        assert "kanban-settings-page-tab-agent" in tab_ids
        assert "kanban-settings-page-tab-memories" not in tab_ids, (
            f"Standalone Local Memories tab should not exist, found: {tab_ids}"
        )
        assert len(tab_ids) == 2, f"Expected exactly 2 tabs, got {tab_ids}"
    finally:
        try:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


def test_agent_tab_embeds_local_memories_listing(ui_harness: UIHarness, page) -> None:
    """Agent tab renders the Local Memories section and lists existing memories."""
    h = ui_harness
    ws_id = _create_workspace(h)
    tmpdir = tempfile.mkdtemp(prefix="nalar-kanban-mem-test-")
    try:
        kanban_id = _create_kanban(h, ws_id, path=tmpdir)

        # Seed a local memory via the API so the listing has something to show.
        mem_name = "test-memory.md"
        mem_content = "# Test Memory\nThis is a local memory for the kanban."
        h.http(
            "POST",
            "/api/local-memories",
            json_body={"name": mem_name, "content": mem_content, "cwd": tmpdir},
            expect=201,
        )

        # Verify via API that the memory exists.
        r = h.http("GET", "/api/local-memories", params={"cwd": tmpdir}, expect=200)
        memories = r.json().get("memories", [])
        assert any(m["name"] == mem_name for m in memories), (
            f"Seeded memory {mem_name!r} not found via API: {memories!r}"
        )

        # Open Kanban Settings on the Agent tab.
        page.goto(_kanban_settings_url(h, kanban_id, tab="agent"), wait_until="domcontentloaded", timeout=30000)
        _wait_for_agent_panel(page)

        # The Agent tab should contain the embedded memories section.
        section = page.locator('[data-testid="kanban-settings-page-agent-memories-section"]')
        assert section.count() > 0, "Agent tab should contain the memories section wrapper"

        memories_container = page.locator('[data-testid="kanban-settings-page-agent-memories"]')
        assert memories_container.count() > 0, "Agent tab should contain the memories listing when kanban has a path"

        # The WorkspaceItemMemoriesView should be visible inside the Agent tab.
        # It renders with data-testid="workspace-item-memories-view".
        memories_view = page.locator('[data-testid="workspace-item-memories-view"]')
        memories_view.first.wait_for(timeout=15000, state="visible")

        # The seeded memory should appear in the listing.
        # WorkspaceItemMemoriesView renders each memory as a row with
        # data-testid="workspace-item-memories-row-{name}".
        # Wait for the list to load (it fetches via API on mount).
        page.wait_for_timeout(1500)
        mem_row = page.locator(f'[data-testid="workspace-item-memories-row-{mem_name}"]')
        # Also try text-based fallback if the row testid pattern differs.
        if mem_row.count() == 0:
            mem_row = page.locator(f"text={mem_name}")
        assert mem_row.count() > 0, (
            f"Memory {mem_name!r} not visible inside Agent tab's embedded listing. "
            f"Check that WorkspaceItemMemoriesView is correctly embedded and fetches with cwd={tmpdir!r}"
        )
    finally:
        try:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


def test_agent_tab_shows_no_path_hint_when_kanban_has_no_path(
    ui_harness: UIHarness, page
) -> None:
    """When kanban has no path, Agent tab shows the no-path hint instead of listing."""
    h = ui_harness
    ws_id = _create_workspace(h)
    kanban_id = _create_kanban(h, ws_id, path=None)

    page.goto(_kanban_settings_url(h, kanban_id, tab="agent"), wait_until="domcontentloaded", timeout=30000)
    _wait_for_agent_panel(page)

    # Should show the no-path hint.
    hint = page.locator('[data-testid="kanban-settings-page-agent-memories-no-path"]')
    hint.wait_for(timeout=10000, state="visible")
    assert "No directory is set" in hint.text_content() or "no directory" in hint.text_content().lower()

    # Should NOT show the memories listing.
    assert page.locator('[data-testid="kanban-settings-page-agent-memories"]').count() == 0


def test_legacy_memories_tab_param_lands_on_agent(ui_harness: UIHarness, page) -> None:
    """Legacy ?tab=memories URL still works — it now maps to the Agent tab."""
    h = ui_harness
    ws_id = _create_workspace(h)
    tmpdir = tempfile.mkdtemp(prefix="nalar-kanban-mem-test-")
    try:
        kanban_id = _create_kanban(h, ws_id, path=tmpdir)

        page.goto(_kanban_settings_url(h, kanban_id, tab="memories"), wait_until="domcontentloaded", timeout=30000)
        # Should land on Agent panel, not columns.
        _wait_for_agent_panel(page)

        # Columns list should NOT be visible.
        assert page.locator('[data-testid="kanban-settings-page-column-list"]').count() == 0
        # Agent panel should be visible.
        assert page.locator('[data-testid="kanban-settings-page-agent-panel"]').count() > 0
    finally:
        try:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


def test_agent_tab_memories_not_visible_on_columns_tab(
    ui_harness: UIHarness, page
) -> None:
    """Local Memories section is only visible when Agent tab is active."""
    h = ui_harness
    ws_id = _create_workspace(h)
    tmpdir = tempfile.mkdtemp(prefix="nalar-kanban-mem-test-")
    try:
        kanban_id = _create_kanban(h, ws_id, path=tmpdir)

        # Open on default (columns) tab.
        page.goto(_kanban_settings_url(h, kanban_id), wait_until="domcontentloaded", timeout=30000)
        page.locator('[data-testid="kanban-settings-page-column-list"]').wait_for(timeout=15000, state="visible")

        # Memories section should NOT be visible on columns tab.
        assert page.locator('[data-testid="kanban-settings-page-agent-memories"]').count() == 0
        assert page.locator('[data-testid="kanban-settings-page-agent-memories-section"]').count() == 0

        # Click Agent tab — now it should appear.
        page.locator('[data-testid="kanban-settings-page-tab-agent"]').click()
        _wait_for_agent_panel(page)
        assert page.locator('[data-testid="kanban-settings-page-agent-memories-section"]').count() > 0
    finally:
        try:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass
