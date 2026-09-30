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

from chatview_boot import (
    bind_session_workspace,
    create_workspace,
    open_chatview,
)
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


# ─── Second real payload (llm_history 1789313976387498377) ────────────────
#
# Same session, the follow-up answer. This one is the "still bad" case from
# the report: the model authored its HTML for a LIGHT page — GitHub's
# `background:#f6f8fa` inline on every <pre>. An inline background beats the
# frame's stylesheet, so the frame's theme ink (light) landed on the
# payload's own light chip → washed-out code blocks.

_LIGHT_AUTHORED_HTML_REPORT = """The follow-up bug is found, fixed, and proven — **PR #481** (new PR, because #479 got merged mid-session and couldn't carry the follow-up commit).

<html>
<div style="font-family:ui-sans-serif,system-ui,sans-serif;line-height:1.55">

<h2>Why "the next prompt response not showup in TUI"</h2>

<p><strong>Root cause (F7):</strong> <code>App.onMessages</code> decided <em>"this turn is over"</em> by scanning the <strong>whole</strong> polled array for <em>any</em> assistant row with <code>finish_reason="stop"</code>:</p>

<pre style="background:#f6f8fa;padding:10px;border-radius:6px;overflow-x:auto"><code>if (self.is_streaming) {
    while (idx &lt; arr.items.len) : (idx += 1) {
        ... if (assistant row has finish_reason == "stop") { self.is_streaming = false; break; }
    }
}</code></pre>

<p>But that array is <code>GET /api/llm/session/:id/messages?limit=100&amp;direction=asc</code> — the <strong>session window</strong>, so it always contains the <em>previous</em> turn's completed reply. The very first poll of turn 2 (~500&nbsp;ms after Enter) found <strong>turn 1's <code>stop</code></strong>, set <code>is_streaming = false</code>, and <code>handleTick</code> stopped returning <code>.poll_messages</code> — nothing else was ever fetched. Turn 1 only worked because the array had no earlier stop, so <strong>every later turn in a session was dead</strong>. It also explains the missing <em>user</em> message in your screenshot: the queued row is inserted by the backend worker, so that single (first and last) poll can predate the insert — it carried no news at all, and polling then stopped for good.</p>

<h3>Fix</h3>
<p>The turn-over decision now happens inside the same render pass and only rows <strong>new in this poll</strong> may end the turn (already-rendered rows are history); the flag is applied <em>after</em> the loop so the batch that contains the stop still renders. The <code>finish_reason</code>-less legacy fallback is scoped the same way. Same screenshot, cosmetic: <code>onSendOk</code> now writes the session id once in the right slot (it used to leave <code>new session</code> forever and stamp <code>session session-1789312667194</code> on the left).</p>

<h3>Evidence — test written first, failed, then passed</h3>
<pre style="background:#f6f8fa;padding:10px;border-radius:6px;overflow-x:auto"><code># tests/functional/tui_turn_streaming_test.py — fake backend, two turns in one session
before:  test_second_turn_renders_after_the_previous_turn_finished FAILED
         AssertionError: turn-2 reply never reached the viewport
after:   2 passed</code></pre>

<table style="border-collapse:collapse" border="1" cellpadding="6">
<tr><th>gate</th><th>result</th></tr>
<tr><td><code>zig build test:tui</code></td><td>169/169 (+4 new: prev-turn stop, raced poll, legacy rows, status bar)</td></tr>
<tr><td><code>zig build test</code></td><td>3272 pass · 8 skip · 0 fail</td></tr>
<tr><td>pty suites (<code>tui_perf_test</code> + <code>tui_turn_streaming_test</code>)</td><td>5 passed</td></tr>
<tr><td>perf probe (leak/latency regression guard)</td><td>idle +1 KB/s · 0.76 KB/key · p50 2.8 ms · PASS</td></tr>
</table>

<p><strong>PR <a href="https://github.com/ginwa123/ginwaaitoolbox/pull/481">#481</a></strong> — <em>fix(tui): a finished previous turn no longer silences the next one</em> — open on branch <code>worktree/audit-tui-turn-scoping-1789301162387</code>, rebased on current <code>main</code> (I verified the TUI/test/doc files are byte-identical to the commit I measured). Card is back in <strong>in_review_task</strong>.</p>

<p style="opacity:.85">Note: <strong>PR #479 was merged as <code>dc653788</code> while I was working</strong>, so a commit pushed to that branch after the merge would not have reached main — hence the fresh branch + cherry-pick. Your installed <code>~/.local/bin/nalar-tui</code> is from Sep&nbsp;2, so it has neither fix yet; to try both right now:</p>
<pre style="background:#f6f8fa;padding:10px;border-radius:6px;overflow-x:auto"><code>cd ~/.config/nalar/.worktrees/audit-tui-app-1789301141999 &amp;&amp; zig build install-tui</code></pre>

<p style="opacity:.85">Still open from the audit (documented in §7 of the report, not in this PR): the 500&nbsp;ms poll does a <em>blocking</em> HTTP GET on the UI thread (worst case 15&nbsp;s stall while streaming → the right fix is the already-written-but-dead <code>sse.zig</code>, or a worker thread); <code>onMessages</code> re-parses an unbounded body and strips thinking tags twice; <code>seen_ids</code> is never pruned; nothing stops the spinner if a turn never emits a stop row.</p>

</div>
</html>"""


# ─── Helpers ────────────────────────────────────────────────────────────────


def _seed_db_path(h: UIHarness) -> Path:
    return h.temp_dir / ".config" / "nalar" / "agent.db"


def _seed_report_session(h: UIHarness, workspace_id: str, session_id: str) -> None:
    _seed_html_session(h, workspace_id, session_id, _REAL_HTML_REPORT)


def _seed_html_session(
    h: UIHarness, workspace_id: str, session_id: str, content: str
) -> None:
    seed = DbSeed(_seed_db_path(h))
    with seed.connect() as conn:
        seed.seed_session(conn, session_id, "HTML frame layout")
        bind_session_workspace(conn, workspace_id, session_id)
        ts = DbSeed.baseline_timestamps(count=2, interval_seconds=30)
        seed.seed_user_message(conn, session_id, "run the audit", created_at=ts[0])
        seed.seed_assistant_message(conn, session_id, content, created_at=ts[1])


# ─── Computed-style sweep inside the frame ─────────────────────────────────
#
# Returns, per text-carrying surface, the COMPOSITED background (rgba chips
# are flattened onto their ancestors) plus the text colour, so the caller can
# require dark surfaces and light ink without re-implementing CSS compositing.
_SURFACE_SWEEP_JS = """() => {
  const parse = (c) => {
    const m = (c || '').match(/[\\d.]+/g) || [];
    return { r: +m[0] || 0, g: +m[1] || 0, b: +m[2] || 0, a: m.length > 3 ? +m[3] : 1 };
  };
  const lum = ({ r, g, b }) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  };
  const effectiveBg = (el) => {
    const stack = [];
    for (let n = el; n; n = n.parentElement) {
      const p = parse(getComputedStyle(n).backgroundColor);
      if (p.a > 0) stack.push(p);
      if (p.a >= 1) break;
    }
    let out = { r: 30, g: 30, b: 30 };
    for (let i = stack.length - 1; i >= 0; i--) {
      const p = stack[i];
      out = {
        r: p.r * p.a + out.r * (1 - p.a),
        g: p.g * p.a + out.g * (1 - p.a),
        b: p.b * p.a + out.b * (1 - p.a),
      };
    }
    return out;
  };
  const out = [];
  for (const el of document.querySelectorAll('pre, code, th, td, li, p, h1, h2, h3')) {
    const cs = getComputedStyle(el);
    const bg = effectiveBg(el);
    const fg = parse(cs.color);
    const l1 = lum(fg), l2 = lum(bg);
    out.push({
      tag: el.tagName.toLowerCase(),
      sample: (el.textContent || '').trim().slice(0, 24),
      bg: [Math.round(bg.r), Math.round(bg.g), Math.round(bg.b)],
      fg: [fg.r, fg.g, fg.b],
      bgLum: +l2.toFixed(3),
      fgLum: +l1.toFixed(3),
      contrast: +(((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05))).toFixed(2),
    });
  }
  return out;
}"""


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
    workspace_id = create_workspace(h)
    _seed_report_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
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
    workspace_id = create_workspace(h)
    _seed_report_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
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
    workspace_id = create_workspace(h)
    _seed_report_session(h, workspace_id, session_id)

    open_chatview(page, h, workspace_id, session_id)
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


# ─── Test 4: a payload authored for a LIGHT page stays legible ─────────────


def test_light_authored_payload_surfaces_are_neutralised(
    ui_harness: UIHarness, page, artifacts_dir: Path,
) -> None:
    """The LLM authors its HTML blind — it writes for a light page
    (GitHub's ``background:#f6f8fa`` inline on every ``<pre>``, seen in
    ``llm_history`` row 1789313976387498377). An inline style beats the
    frame's stylesheet, so without an explicit guard the frame's theme ink
    (light) lands on the payload's own light chip and the code is washed
    out — the "why is the UI still bad" screenshot.

    Contract asserted here: every text-carrying surface inside the frame is
    DARK, the ink on it is LIGHT, and the pair clears WCAG AA (>= 4.5:1).
    This fails both before the theme fix (body was #fff) and before this
    guard (the payload's own #f6f8fa chip won).
    """
    h = ui_harness
    session_id = "sess_html_frame_layout_004"
    workspace_id = create_workspace(h)
    _seed_html_session(h, workspace_id, session_id, _LIGHT_AUTHORED_HTML_REPORT)

    open_chatview(page, h, workspace_id, session_id)
    page.wait_for_selector("iframe.chat-html-frame", timeout=15000)
    frame_el = page.locator("iframe.chat-html-frame").first
    frame_el.scroll_into_view_if_needed()
    page.wait_for_timeout(500)
    page.screenshot(path=str(artifacts_dir / "light-authored-payload.png"))

    frame = _srcdoc_frame(page)
    surfaces = frame.evaluate(_SURFACE_SWEEP_JS)
    assert surfaces, "no text surfaces found inside the frame"

    body_bg = frame.evaluate(
        "() => getComputedStyle(document.body).backgroundColor"
    )
    assert _luminance(_rgb(body_bg)) < 0.35, (
        f"frame body background is light ({body_bg!r}) — the payload "
        f"renders as a white slab in the dark transcript."
    )

    light_surfaces = [s for s in surfaces if s["bgLum"] >= 0.35]
    assert not light_surfaces, (
        "the payload's own light page colours survived into the dark frame "
        "(an inline style beat the shell stylesheet): "
        + ", ".join(
            f"<{s['tag']}> bg={s['bg']} on {s['sample']!r}" for s in light_surfaces
        )
    )

    low_contrast = [s for s in surfaces if s["contrast"] < 4.5]
    assert not low_contrast, (
        "washed-out text inside the frame (WCAG AA needs >= 4.5:1): "
        + ", ".join(
            f"<{s['tag']}> {s['fg']} on {s['bg']} = {s['contrast']}:1 "
            f"({s['sample']!r})"
            for s in low_contrast
        )
    )
