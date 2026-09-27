"""Payloads lifted from real nalar rows, not invented here.

A hand-written approximation of a document turn is exactly the thing that made
the phone render a wall of HTML for a month: the model writes for a page whose
theme it cannot see, and its own inline styles are what beat the transcript's
stylesheet. So the payload the `html` scenario seeds is the real one, copied
byte-for-byte out of `tests/functional_ui/chatview_html_frame_layout_test.py`
where it was captured from `llm_history`.

`_REAL_HTML_DOCUMENT_TURN` is that document. It is generated, not retyped:
`seed_scenarios.py` and this file are checked in together, and the desktop suite
remains the place the payload is captured.
"""

from __future__ import annotations

#: A real assistant turn: prose, then a full `<html>` document, from
#: `llm_history` — the exact shape `HtmlResponse.segments` has to split and
#: `HtmlPreview`'s `WebView` has to size.
REAL_HTML_DOCUMENT_TURN = 'No stray processes, the port-8081 server was never touched. Here\'s the audit result:\n\n<html>\n<div style="font-family:ui-sans-serif,system-ui,sans-serif;line-height:1.5">\n<h2>Audit: <code>nalar-tui</code> memory leak + slow typing/scrolling</h2>\n\n<p><strong>Root cause found and fixed — PR <a href="https://github.com/ginwa123/ginwaaitoolbox/pull/479">#479</a></strong> · card moved to <em>in_review_task</em>. Everything below was measured by driving the real binary inside a pty (RSS from <code>/proc</code>, key→echo latency via <code>select</code>), with a control experiment proving the pty itself adds only 0.07 ms.</p>\n\n<h3>Why it leaked (F1)</h3>\n<p><code>tui_main.zig:39</code> handed the TUI <code>init.arena.allocator()</code> — the <strong>process-lifetime arena</strong>. An arena\'s <code>free()</code> only reclaims its <em>most recent</em> allocation; everything else is silently dropped. So every per-redraw temporary stayed forever: <strong>two whole frame buffers per draw</strong> (the previous-frame free and the <code>next</code> free were never in LIFO order), plus the diff writer\'s growth, <code>wrapText</code>\'s per-chunk dupes and the per-message render arena. The leak scales with <em>terminal area × redraws</em>.</p>\n\n<h3>Why typing/scrolling felt slow (F2 + F3)</h3>\n<p><code>stdin</code> was drained with <code>readSliceShort</code>, which <em>despite its name</em> keeps reading until its destination buffer is completely full — so after each key it kept reading and only gave up when the tty\'s <code>VTIME</code> expired. An in-process trace settled it: <code>poll woke 0.0&nbsp;ms → read returned 108&nbsp;ms later</code>. On top of that, the loop blocked in <code>read()</code> and then slept a fixed 100&nbsp;ms with no <code>poll()</code>.</p>\n\n<h3>Measured, same harness</h3>\n<table style="border-collapse:collapse" border="1" cellpadding="6">\n<tr><th>metric</th><th>before</th><th>after</th></tr>\n<tr><td>RSS while fully idle</td><td>+1 760 KB/s</td><td><b>+4 KB/s</b></td></tr>\n<tr><td>RSS per keystroke (200×50)</td><td>+364 KB</td><td><b>+0.4 KB</b></td></tr>\n<tr><td>RSS per keystroke (400×100)</td><td>+2 785 KB</td><td><b>~0</b></td></tr>\n<tr><td>keystroke latency p50 / p90</td><td>104 ms / 110 ms</td><td><b>1.1 ms / 1.1 ms</b></td></tr>\n<tr><td>wheel-notch latency p50</td><td>104 ms</td><td><b>2.2 ms</b></td></tr>\n<tr><td>typing+scroll soak</td><td>66 MB → 442 MB</td><td><b>15.2 MB → 14.8 MB (flat)</b></td></tr>\n</table>\n\n<h3>Also fixed (same leak/latency family)</h3>\n<p>Per-frame re-wrapping with a dupe per chunk → borrowed subslices + one reused scratch list; row counting without allocation; <code>draw()</code> now transfers frame ownership instead of allocating + <code>memcpy</code>-ing a second frame (~80 KB × 10/s); the 10k-line scrollback cap no longer does a 10 000-entry memmove per appended line.</p>\n\n<h3>Gates</h3>\n<p><code>zig build test:tui</code> 165/165 · <code>zig build test</code> 3272 pass / 8 skip / 0 fail · new pty gate <code>tests/functional/tui_perf_test.py</code> 3 passed <em>and it fails on the pre-fix binary</em> (1 638 KB/s, 103.8 ms) · audit report at <code>docs/superpowers/plans/2026-09-13-audit-nalar-tui-memory-and-latency.md</code>.</p>\n\n<p style="opacity:.8">Documented follow-ups (not in this PR): the 500 ms poll does a <em>blocking</em> HTTP GET on the UI thread (worst case 15 s stall while streaming — move to the already-written-but-dead <code>sse.zig</code> or a worker), <code>onMessages</code> re-parses an unbounded body and double-strips thinking tags, <code>seen_ids</code> is never pruned, and idle ticks still redraw unconditionally.</p>\n</div>\n</html>'


#: The `present_files` tool's result envelope, as its own tool description
#: documents it:
#:   {"status":"presented","count":N,"files":[{"path":...,"bytes":...,"mime":...,"label":...}],"error":null}
#: Two rows rather than one, so the card's list rendering is exercised and a
#: count of 1 cannot pass by accident.
PRESENT_FILES_RESULT = """{"status":"presented","count":2,"files":[{"path":"/home/me/report.md","bytes":2048,"mime":"text/markdown","label":"report.md"},{"path":"/home/me/shot.png","bytes":40960,"mime":"image/png","label":"shot.png"}],"error":null}"""

#: The tool call that produced it, so the assistant row and the tool row link up
#: by `tool_call_id` the way production links them.
PRESENT_FILES_TOOL_NAME = "present_files"
