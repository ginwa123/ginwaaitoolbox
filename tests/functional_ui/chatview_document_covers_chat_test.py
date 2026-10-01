"""The document viewer COVERS the chat it was opened from.

Repro: click a session in the RECENT list, then click a document. The URL
becomes `/app/<ws>/chat/<session>?doc=<id>`, which mounts the ChatView AND
the DocumentsView overlay at the same time. The document is meant to cover
the chat (it is an `absolute inset-0` overlay inside the same `<main>`), but
the chat's floating chrome painted ON TOP of it: the composer dock, the
scroll-to-bottom arrow and the scroll slider were all visible over the
document body, which made the viewer look broken.

The cause was a missing stacking context, and the whole reason this is a
browser test: `main` and `.chat-column` are both `position: relative` with
`z-index: auto`, which does NOT open a stacking context. So the chat's
z-ladder (scroll slider / pill rail 20, composer dock 30, scroll-to-bottom
31) and the document overlay's `z-index: 10` were all compared in the ROOT
stacking context, where every chat tier outranks 10 and wins. jsdom has no
layout engine and does not apply SFC `<style>` blocks, so it can see
neither the computed `isolation` nor the resulting paint order — both halves
of this contract are invisible to the unit suite.

What is asserted here, by `elementFromPoint` (hit-testing walks the same
stacking order that painting does, so the returned element is the one the
user actually sees):

  1. `elementFromPoint` at the centre of the composer card, the
     scroll-to-bottom arrow and the scroll slider all land INSIDE the
     document overlay — i.e. the document, not the chat, is on top;
  2. `.chat-column` actually computes `isolation: isolate`, so the
     containment is real rather than an accidental z-index coincidence;
  3. the chat is still MOUNTED underneath, because the overlay is
     deliberately an overlay — that is what keeps a Back/Forward or a
     document switch instant. If the chat were simply unmounted, the paint
     order would look right while the behaviour regressed.

The unit half of the contract lives in
`src/apps/desktop/src/__tests__/ChatView.stackingContainment.spec.ts`.

Run (frontend served from THIS worktree; the backend binary may come from
anywhere since only frontend code is under test):
    NALAR_BIN=/home/ginwa/ginwaaitoolbox/zig-out/bin/nalarcore-linux-x86_64 \\
        /tmp/nalar-ui-venv/bin/python -m pytest -s \\
        tests/functional_ui/chatview_document_covers_chat_test.py -v
"""

from __future__ import annotations

from db_seed import DbSeed

BODY = (
    "Message {i} paragraph one.\\n\\n"
    "Message {i} paragraph two with longer text so the bubble has real "
    "height in the virtual scroller. Lorem ipsum dolor sit amet, "
    "consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    "labore et dolore magna aliqua.\\n\\n"
    "Message {i} paragraph three with even more filler so each bubble "
    "measures a few hundred pixels tall in real layout."
)


def _seed_db_path(h) -> "object":
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_session(h, session_id: str, workspace_id: str, count: int = 40) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "Doc covers chat")
        conn.execute(
            "UPDATE sessions SET workspace_id = ? WHERE id = ?",
            (workspace_id, session_id),
        )
        stamps = DbSeed.baseline_timestamps(count=count, interval_seconds=30)
        for i in range(count):
            body = BODY.format(i=i)
            if i % 2 == 0:
                seed.seed_user_message(conn, session_id, body, created_at=stamps[i])
            else:
                seed.seed_assistant_message(conn, session_id, body, created_at=stamps[i])


def _open_chat_then_document(ui_harness, page, session_id: str) -> tuple[str, str]:
    """The exact repro: chat session first, then the document over it."""
    h = ui_harness
    ws = h.http("POST", "/api/workspaces", json_body={"name": "doc-over-chat-ws"}, expect=201)
    workspace_id = ws.json()["id"]
    _seed_session(h, session_id, workspace_id)

    # A real document, created over the API so the viewer has a body.
    doc = h.http(
        "POST",
        f"/api/workspaces/{workspace_id}/documents",
        json_body={
            "title": "Release plan",
            "content": "# Release plan\\n\\nShip the viewer fix.\\n",
        },
        expect=201,
    )
    document_id = doc.json()["document"]["id"]

    # Step 1 — the session is open (this is the half of the repro that
    # leaves a ChatView mounted underneath).
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}"),
        wait_until="load",
        timeout=30000,
    )
    page.wait_for_function(
        "() => { const w = document.querySelector('.messages-scroll-hide-native');"
        " return !!(w && w.querySelector('.virtual-scroller')); }",
        timeout=20000,
    )
    page.wait_for_function(
        "() => { const d = document.querySelector('.composer-dock');"
        " return !!d && d.offsetHeight > 0; }",
        timeout=20000,
    )
    # Not at the bottom -> the scroll-to-bottom arrow is on screen, which
    # is one of the three elements the bug report showed leaking.
    page.evaluate(
        "() => { const el = document.querySelector('.messages-scroll-hide-native')"
        " .querySelector('.virtual-scroller'); if (el) el.scrollTop = 0; }"
    )
    page.wait_for_timeout(2500)

    # Step 2 — click a document. Navigating with ?doc= is exactly what the
    # sidebar's DOCUMENTS section does.
    page.goto(
        h.web_url(f"/app/{workspace_id}/chat/{session_id}?doc={document_id}"),
        wait_until="load",
        timeout=30000,
    )
    page.wait_for_selector('[data-testid="documents-view"]', timeout=20000)
    page.wait_for_selector('[data-testid="documents-rendered"]', timeout=20000)
    page.wait_for_timeout(1500)
    return workspace_id, document_id


#: Who is painted on top at the centre of each piece of chat chrome, plus
#: the containment the fix is supposed to install.
_PROBE_SCRIPT = r"""
() => {
  const overlay = document.querySelector('[data-testid="documents-view"]');
  const column = document.querySelector('.chat-column');
  if (!overlay || !column) return { missing: true };

  const describe = (el) => {
    if (!el) return 'null';
    const tid = el.getAttribute('data-testid');
    return el.tagName + (tid ? '#' + tid : '');
  };
  const mid = (el) => {
    const r = el.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  };
  // The three elements the bug screenshot actually showed on top of the
  // document: the composer card, the scroll-to-bottom arrow, the slider.
  const targets = {
    composerCard: document.querySelector('.composer-card'),
    scrollToBottom: document.querySelector('.chat-scroll-to-bottom'),
    scrollSlider: document.querySelector('.chat-scroll-slider'),
  };
  const points = {};
  for (const [name, el] of Object.entries(targets)) {
    if (!el) { points[name] = { absent: true }; continue; }
    const [x, y] = mid(el);
    const hit = document.elementFromPoint(x, y);
    points[name] = {
      point: [Math.round(x), Math.round(y)],
      hit: describe(hit),
      insideDocOverlay: !!(hit && overlay.contains(hit)),
    };
  }

  const cs = getComputedStyle(column);
  return {
    missing: false,
    points,
    isolation: cs.isolation,
    position: cs.position,
    zIndex: cs.zIndex,
    // The overlay is deliberately an overlay: the chat stays mounted
    // behind it so Back/Forward and document switches stay instant.
    chatStillMounted: !!document.querySelector('.composer-dock'),
    docTitle: (document.querySelector('[data-testid="documents-title"]') || {}).textContent || '',
  };
}
"""


def test_document_overlay_paints_over_the_chat_chrome(ui_harness, page) -> None:
    session_id = "sess-doc-covers-chat"
    _open_chat_then_document(ui_harness, page, session_id)

    p = page.evaluate(_PROBE_SCRIPT)
    print(f"\n[doc-covers-chat] probe: {p}")
    assert not p.get("missing"), "document overlay or chat column not found"

    for name in ("composerCard", "scrollToBottom", "scrollSlider"):
        pt = p["points"][name]
        # The scroll-to-bottom arrow is `v-if`-gated on not being at the
        # bottom; the composer card and the slider are always present.
        if pt.get("absent"):
            continue
        assert pt["insideDocOverlay"], (
            f"{name} is painted ON TOP of the document at {pt['point']} "
            f"(hit {pt['hit']}). The chat chrome leaked over the document "
            "viewer — this is the reported bug."
        )

    assert p["docTitle"].strip() == "Release plan", (
        f"document title is {p['docTitle']!r}, expected 'Release plan' — "
        "the overlay may not have loaded at all"
    )


def test_chat_column_opens_a_stacking_context(ui_harness, page) -> None:
    """The containment itself, so the paint order is not a coincidence.

    Without `isolation: isolate` the chat's z-ladder competes in the root
    stacking context and the fix only holds for the three elements that
    happen to exist today. This asserts the cause, so a future z-index
    added to the chat cannot silently re-break every overlay.
    """
    session_id = "sess-doc-isolation"
    _open_chat_then_document(ui_harness, page, session_id)

    p = page.evaluate(_PROBE_SCRIPT)
    print(f"\n[doc-covers-chat] isolation: {p}")
    assert not p.get("missing"), "document overlay or chat column not found"

    assert p["position"] == "relative", (
        f".chat-column position is {p['position']!r}; the composer dock "
        "anchors to it, so it must stay relative"
    )
    assert p["isolation"] == "isolate", (
        f".chat-column computes isolation: {p['isolation']!r}, expected "
        "'isolate'. Without it the chat's z-ladder escapes into the root "
        "stacking context and outranks the document overlay's z-index: 10."
    )

    # And the chat really is still mounted behind the overlay — the fix is
    # containment, not unmounting. If this ever flipped to False the paint
    # assertions above would still pass while the behaviour regressed.
    assert p["chatStillMounted"], (
        "the chat is no longer mounted behind the document; the overlay is "
        "supposed to COVER a still-mounted chat so document switches and "
        "Back/Forward stay instant"
    )
