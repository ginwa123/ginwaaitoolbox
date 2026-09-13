"""DB-seeded Playwright regression tests for the chatview ``<html>`` iframe
**presentation** — theme colours and content height.

Why this suite exists (2026-09-13, task_1789312493325_7 "html render"):

PR #309 renders every closed ``<html>...</html>`` block as a sandboxed
iframe. The frame was styled with a hardcoded ``background:#fff`` (both on
the ``.chat-html-frame`` element and inside ``buildHtmlSrcdoc``), and it
kept the browser's default iframe height (150 px) with no auto-resize. So
when the LLM answers with a *legitimate* HTML report — which is exactly
what the response-formatting prompt asks for when it picks HTML mode — the
chat UI grows a bright white slab with its own scrollbar inside an
otherwise dark (Kanagawa Dragon) transcript.

The payload in ``_REAL_HTML_REPORT`` is the verbatim ``response_content``
of ``llm_history`` row ``1789306073475690430`` (session
``task_1789301162387_3``), i.e. the EXACT wire shape that produced the
screenshot in the bug report: a prose sentence, then one ``<html>`` block
holding a full report (h2/h3/p/table/code/a), ~3.6 kB.

These assertions are the inverse of the old contract (they used to be
"white background"), so they fail on the pre-fix render:

* ``background`` of both the frame element and the frame's ``<body>`` must
  match the app's dark surface, not ``#fff``.
* ``color-scheme: dark`` must reach the frame document so native widgets
  (scrollbars, form controls) don't render light.
* The frame must be tall enough for its content — no inner scrollbar
  (``scrollHeight <= clientHeight``), the "double scroll jail".
"""

from __future__ import annotations

import re
from pathlib import Path

from db_seed import DbSeed
from ui_harness import UIHarness


# ─── The real wire payload (llm_history 1789306073475690430) ───────────────

_REAL_HTML_REPORT = """No stray processes, the port-8081 server was never touched. Here's the audit result:

<html>
<div style="font-family:ui-sans-serif,system-ui,sans-serif;line-height:1.5">
<h2>Audit: <code>nalar-tui</code> memory leak + slow typing/scrolling</h2>

<p><strong>Root cause found and fixed — PR <a href="https://github.com/ginwa123/ginwaaitoolbox/pull/479">#479</a></strong> · card moved to <em>in_review_task</em>. Everything below was measured by driving the real binary inside a pty (RSS from <code>/proc</code>, key→echo latency via <code>select</code>), with a control experiment proving the pty itself adds only 0.07 ms.</p>

<h3>Why it leaked (F1)</h3>
<p><code>tui_main.zig:39</code> handed the TUI <code>init.arena.allocator()</code> — the <strong>process-lifetime arena</strong>. An arena's <code>free()</code> only reclaims its <em>most recent</em> allocation; everything else is silently dropped. So every per-redraw temporary stayed forever: <strong>two whole frame buffers per draw</strong> (the previous-frame free and the <code>next</code> free were never in LIFO order), plus the diff writer's growth, <code>wrapText</code>'s per-chunk dupes and the per-message render arena. The leak scales with <em>terminal area × redraws</em>.</p>

<h3>Why typing/scrolling felt slow (F2 + F3)</h3>
<p><code>stdin</code> was drained with <code>readSliceShort</code>, which <em>despite its name</em> keeps reading until its destination buffer is completely full — so after each key it kept reading and only gave up when the tty's <code>VTIME</code> expired. An in-process trace settled it: <code>poll woke 0.0&nbsp;ms → read returned 108&nbsp;ms later</code>. On top of that, the loop blocked in <code>read()</code> and then slept a fixed 100&nbsp;ms with no <code>poll()</code>.</p>

<h3>Measured, same harness</h3>
<table style="border-collapse:collapse" border="1" cellpadding="6">
<tr><th>metric</th><th>before</th><th>after</th></tr>
<tr><td>RSS while fully idle</td><td>+1 760 KB/s</td><td><b>+4 KB/s</b></td></tr>
<tr><td>RSS per keystroke (200×50)</td><td>+364 KB</td><td><b>+0.4 KB</b></td></tr>
<tr><td>RSS per keystroke (400×100)</td><td>+2 785 KB</td><td><b>~0</b></td></tr>
<tr><td>keystroke latency p50 / p90</td><td>104 ms / 110 ms</td><td><b>1.1 ms / 1.1 ms</b></td></tr>
<tr><td>wheel-notch latency p50</td><td>104 ms</td><td><b>2.2 ms</b></td></tr>
<tr><td>typing+scroll soak</td><td>66 MB → 442 MB</td><td><b>15.2 MB → 14.8 MB (flat)</b></td></tr>
</table>

<h3>Also fixed (same leak/latency family)</h3>
<p>Per-frame re-wrapping with a dupe per chunk → borrowed subslices + one reused scratch list; row counting without allocation; <code>draw()</code> now transfers frame ownership instead of allocating + <code>memcpy</code>-ing a second frame (~80 KB × 10/s); the 10k-line scrollback cap no longer does a 10 000-entry memmove per appended line.</p>

<h3>Gates</h3>
<p><code>zig build test:tui</code> 165/165 · <code>zig build test</code> 3272 pass / 8 skip / 0 fail · new pty gate <code>tests/functional/tui_perf_test.py</code> 3 passed <em>and it fails on the pre-fix binary</em> (1 638 KB/s, 103.8 ms) · audit report at <code>docs/superpowers/plans/2026-09-13-audit-nalar-tui-memory-and-latency.md</code>.</p>

<p style="opacity:.8">Documented follow-ups (not in this PR): the 500 ms poll does a <em>blocking</em> HTTP GET on the UI thread (worst case 15 s stall while streaming — move to the already-written-but-dead <code>sse.zig</code> or a worker), <code>onMessages</code> re-parses an unbounded body and double-strips thinking tags, <code>seen_ids</code> is never pruned, and idle ticks still redraw unconditionally.</p>
</div>
</html>"""


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _open_chatview(page, h: UIHarness, session_id: str) -> None:
    page.goto(
        h.web_url(f"/app?view=chat&session={session_id}"),
        wait_until="load",
        timeout=30000,
    )


def _seed_report_session(h: UIHarness, session_id: str) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML frame layout")
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "run the audit", created_at=ts[0])
        seed.seed_assistant_message(
            conn, session_id, _REAL_HTML_REPORT, created_at=ts[1],
        )


def _frames_of(page):
    """Child frames (the sandboxed srcdoc iframes)."""
    return [f for f in page.frames if f != page.main_frame]


def _srcdoc_frame(page, timeout_ms: int = 15000):
    """The first ``about:srcdoc`` child frame, waited for."""
    deadline = timeout_ms
    step = 100
    while deadline > 0:
        for f in _frames_of(page):
            if f.url == "about:srcdoc":
                return f
        page.wait_for_timeout(step)
        deadline -= step
    raise AssertionError("no about:srcdoc child frame appeared")


def _rgb(hex_or_rgb: str) -> tuple[int, int, int]:
    """Normalise '#RRGGBB' / 'rgb(r, g, b)' / 'rgba(...)' to an (r,g,b) tuple."""
    s = hex_or_rgb.strip()
    if s.startswith("#"):
        s = s[1:]
        if len(s) == 3:
            s = "".join(c * 2 for c in s)
        return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))
    nums = [int(float(n)) for n in re.findall(r"[\d.]+", s)[:3]]
    return (nums[0], nums[1], nums[2])


def _luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


# ─── Test 1: the frame follows the app's dark surface, not #fff ─────────────


def test_html_frame_uses_dark_surface_not_white(
    ui_harness: UIHarness, page, artifacts_dir: Path,
) -> None:
    """The iframe must paint the app's dark surface, not a white slab.

    Pre-fix: ``.chat-html-frame { background: #fff }`` + a ``#fff`` body
    inside ``buildHtmlSrcdoc`` → a bright white box inside a dark
    transcript (the bug-report screenshot).
    """
    h = ui_harness
    session_id = "sess_html_frame_layout_001"
    _seed_report_session(h, session_id)

    _open_chatview(page, h, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    frame_el = page.locator("iframe.chat-html-frame").first
    # Visual evidence for the issue/PR (survives the run).
    frame_el.scroll_into_view_if_needed()
    page.wait_for_timeout(500)
    page.screenshot(path=str(artifacts_dir / "html-frame.png"))

    # Background declared on the frame ELEMENT (must no longer be #fff).
    el_bg = frame_el.evaluate("el => getComputedStyle(el).backgroundColor")
    assert _luminance(_rgb(el_bg)) < 0.35, (
        f"iframe element background is light ({el_bg!r}) — a white slab "
        f"inside the dark transcript."
    )

    # Background actually painted by the frame's own document.
    frame = _srcdoc_frame(page)
    doc = frame.evaluate(
        "() => {"
        "  const cs = getComputedStyle(document.body);"
        "  return {"
        "    bg: cs.backgroundColor,"
        "    fg: cs.color,"
        "    colorScheme: cs.colorScheme,"
        "  };"
        "}"
    )
    assert _luminance(_rgb(doc["bg"])) < 0.35, (
        f"iframe document body background is light ({doc['bg']!r}) — "
        f"the LLM's HTML report renders as a white box in the dark theme."
    )
    assert "dark" in (doc["colorScheme"] or ""), (
        f"iframe document must declare color-scheme:dark so native "
        f"scrollbars/widgets don't render light, got {doc['colorScheme']!r}."
    )
    # Text must be legible on that surface (light ink, not #111).
    assert _luminance(_rgb(doc["fg"])) > 0.5, (
        f"iframe document text colour ({doc['fg']!r}) is too dark for the "
        f"dark surface."
    )


# ─── Test 2: the frame grows to its content (no inner scrollbar) ────────────


def test_html_frame_height_matches_its_content(
    ui_harness: UIHarness, page,
) -> None:
    """A long HTML block must size the frame to its content instead of
    clipping it behind an inner scrollbar (the pre-fix 150 px default).
    """
    h = ui_harness
    session_id = "sess_html_frame_layout_002"
    _seed_report_session(h, session_id)

    _open_chatview(page, h, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    frame_el = page.locator("iframe.chat-html-frame").first

    # Wait for the auto-resize round-trip to settle.
    deadline = 8000
    last = None
    while deadline > 0:
        last = frame_el.evaluate("el => el.getBoundingClientRect().height")
        frame = _srcdoc_frame(page)
        content = frame.evaluate("() => document.documentElement.scrollHeight")
        if content > 0 and abs(last - content) <= 24:
            break
        page.wait_for_timeout(200)
        deadline -= 200

    frame = _srcdoc_frame(page)
    diag = frame.evaluate(
        "() => ({"
        "  scrollH: document.documentElement.scrollHeight,"
        "  clientH: document.documentElement.clientHeight,"
        "  innerH: window.innerHeight,"
        "  scrollTop: document.documentElement.scrollTop,"
        "})"
    )
    frame_box = frame_el.bounding_box()
    assert frame_box is not None
    assert frame_box["height"] > 180, (
        f"frame height is {frame_box['height']:.0f}px — the default iframe "
        f"height clips this ~3.6 kB report. Content height: "
        f"{diag['scrollH']}px."
    )
    inner_scroll = diag["scrollH"] - diag["clientH"]
    assert inner_scroll <= 24, (
        f"frame content overflows its viewport by {inner_scroll}px "
        f"(content {diag['scrollH']}px vs viewport {diag['clientH']}px) — "
        f"the chat shows an iframe-within-a-scroller."
    )


# ─── Test 3: the srcdoc shell carries the theme + resize contract ──────────


def test_srcdoc_shell_carries_theme_and_resize_script(
    ui_harness: UIHarness, page,
) -> None:
    """Source-level contract: the built srcdoc must (a) not hardcode a white
    body, (b) declare color-scheme, (c) include the auto-resize reporter so
    the parent can grow the frame.
    """
    h = ui_harness
    session_id = "sess_html_frame_layout_003"
    _seed_report_session(h, session_id)

    _open_chatview(page, h, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    srcdoc = page.locator("iframe.chat-html-frame").first.get_attribute("srcdoc") or ""

    assert "background:#fff" not in srcdoc.replace(" ", ""), (
        "srcdoc still hardcodes a white background"
    )
    assert "color-scheme" in srcdoc, "srcdoc must declare a color-scheme"
    assert "auto-resize" in srcdoc, (
        "srcdoc must carry the auto-resize reporter script"
    )
    # The LLM's payload is still rendered verbatim (no escaping regression).
    assert "nalar-tui" in srcdoc and "<h2>" in srcdoc
