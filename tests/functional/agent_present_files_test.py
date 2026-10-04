"""Functional tests for the `present_files` download endpoint.

Exercises GET /api/files/download against a REAL pabrik binary + REAL
SQLite, replaying the EXACT query strings the PresentFiles.vue card
emits (see `fileDownloadUrl` in src/apps/desktop/src/api/index.ts).

  Plan: docs/plans/2026-09-14-agent-tool-present-files.md

Why a wire test (not just Zig unit tests): three failure modes only
surface on a real round-trip —
  1. Route-order shadowing — matchRoute walks routes in registration
     order, so a literal registered after a `:param` sibling is
     captured as a param.
  2. Query decoding — the card sends encodeURIComponent(path); the
     handler must see the decoded absolute path.
  3. Sandbox scope — the session-cwd containment check runs against
     the sessions row, which only exists in a real DB.

Setup pattern (replay-frontend-wire-payload rule): sessions are created
via PUT /api/llm/session/:id {"name": ...} (auto-creates, no LLM
profile needed — same precedent as background_processes_api_test.py),
then the sandbox root is pinned via direct sqlite3 UPDATE of
sessions.cwd (WAL-safe short-lived connection, same precedent).
Files live under harness.temp_dir (isolated tmpdir HOME), never /tmp
bare — teardown rmtree's only the validated tempdir.

Covers:
  * REGISTRY    — present_files is in /api/agent-tools/registry
  * TXT_ATTACH  — .txt + disposition=attachment → 200, byte-identical,
    Content-Disposition: attachment; filename="notes.txt"
  * JPG_INLINE  — .jpg + disposition=inline → 200, byte-identical,
    Content-Disposition: inline (thumbnail path)
  * JPG_ATTACH  — .jpg + disposition=attachment → attachment header
  * MISSING     — absent path → 404
  * TRAVERSAL   — a path outside cwd (the harness tempdir's parent) → 403
  * DOTDOT      — path with .. → 403
  * NO_SESSION  — unknown session_id → 404
  * BAD_DISP    — disposition=download → 400
"""

from __future__ import annotations

import sqlite3
import urllib.parse
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

TXT_BODY = b"hello present files\nsecond line\n"
# Minimal JPEG: SOI + JFIF-ish payload. Magic bytes only matter for
# mime-sniffing tools; here the handler maps by extension.
JPG_BODY = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + b"fake-jpeg-payload-1234"


# ─── Helpers ───────────────────────────────────────────────────────────────


def _db_path(harness: FunctionalHarness) -> Path:
    """Agent DB inside the isolated tmpdir HOME (Linux layout)."""
    return Path(harness.temp_dir) / ".config" / "pabrik" / "agent.db"


def _create_session(harness: FunctionalHarness, session_id: str) -> dict[str, Any]:
    """PUT auto-creates the sessions row (ensureSessionExists); no LLM needed."""
    r = harness.http(
        "PUT",
        f"/api/llm/session/{session_id}",
        json_body={"name": f"present-files-{session_id}"},
        expect=200,
    )
    return r.json()


def _set_session_cwd(harness: FunctionalHarness, session_id: str, cwd: str) -> None:
    """Pin the sandbox root via direct sqlite UPDATE (WAL-safe pattern)."""
    conn = sqlite3.connect(f"file:{_db_path(harness)}?mode=rw", uri=True)
    try:
        conn.execute("UPDATE sessions SET cwd = ? WHERE id = ?", (cwd, session_id))
        conn.commit()
    finally:
        conn.close()


def _sandbox(harness: FunctionalHarness) -> Path:
    """Create the sandbox dir + fixture files inside the isolated tempdir."""
    root = Path(harness.temp_dir) / "present-files-ws"
    root.mkdir(parents=True, exist_ok=True)
    (root / "notes.txt").write_bytes(TXT_BODY)
    (root / "photo.jpg").write_bytes(JPG_BODY)
    return root


def _setup(harness: FunctionalHarness, session_id: str = "sess_present_1") -> tuple[str, Path]:
    """Create session + sandbox, pin cwd. Returns (session_id, sandbox)."""
    _create_session(harness, session_id)
    root = _sandbox(harness)
    _set_session_cwd(harness, session_id, str(root))
    return session_id, root


def _download(
    harness: FunctionalHarness,
    session_id: str,
    path: str,
    disposition: str | None = "attachment",
    expect: int = 200,
):
    params: dict[str, Any] = {"session_id": session_id, "path": path}
    if disposition is not None:
        params["disposition"] = disposition
    return harness.http("GET", "/api/files/download", params=params, expect=expect)


def _header(resp, name: str) -> str:
    for k, v in resp.headers.items():
        if k.lower() == name.lower():
            return v
    return ""


# ─── Tests ─────────────────────────────────────────────────────────────────


def test_present_files_in_registry(harness: FunctionalHarness):
    """The tool must be wired into UNIFIED_TOOL_REGISTRY (else enable fails)."""
    r = harness.http("GET", "/api/agent-tools/registry", expect=200)
    names = [t["name"] if isinstance(t, dict) else t for t in r.json().get("tools", r.json())]
    assert "present_files" in names, f"present_files missing from registry: {names!r}"


def test_txt_download_attachment_is_byte_identical(harness: FunctionalHarness):
    """The card's ⬇ click: disposition=attachment → save dialog bytes."""
    sid, root = _setup(harness)
    r = _download(harness, sid, str(root / "notes.txt"), "attachment")
    assert r.body == TXT_BODY, f"body mismatch: {r.body!r}"
    disp = _header(r, "Content-Disposition")
    assert "attachment" in disp, f"want attachment disposition, got {disp!r}"
    assert 'filename="notes.txt"' in disp, f"want original filename, got {disp!r}"
    ctype = _header(r, "Content-Type")
    assert "text/plain" in ctype, f"want text/plain, got {ctype!r}"


def test_jpg_inline_preview_is_byte_identical(harness: FunctionalHarness):
    """The card's <img> path: disposition=inline → browser renders."""
    sid, root = _setup(harness)
    r = _download(harness, sid, str(root / "photo.jpg"), "inline")
    assert r.body == JPG_BODY, "inline body must equal the on-disk bytes"
    disp = _header(r, "Content-Disposition")
    assert disp.startswith("inline"), f"want inline disposition, got {disp!r}"
    assert 'filename="photo.jpg"' in disp, f"want original filename, got {disp!r}"
    ctype = _header(r, "Content-Type")
    assert "image/jpeg" in ctype, f"want image/jpeg, got {ctype!r}"


def test_jpg_attachment_download(harness: FunctionalHarness):
    """Same jpg via the ⬇ button: attachment, identical bytes."""
    sid, root = _setup(harness)
    r = _download(harness, sid, str(root / "photo.jpg"), "attachment")
    assert r.body == JPG_BODY
    assert "attachment" in _header(r, "Content-Disposition")


def test_missing_file_404(harness: FunctionalHarness):
    sid, root = _setup(harness)
    _download(harness, sid, str(root / "nope.txt"), "attachment", expect=404)


def test_traversal_outside_cwd_403(harness: FunctionalHarness):
    """A real file that canonicalizes outside the sandbox → 403, never bytes.

    The probe used to be the literal ``/etc/passwd``. That is only
    absolute (and only outside the sandbox) on POSIX: on windows-2022 it
    resolves against the current drive, so the request 404s as a missing
    file instead of 403ing as a traversal, and the guard this test exists
    for goes unexercised. Worse, a path that does not exist proves
    nothing on ANY platform — the handler answers 404 before it reaches
    the sandbox check (which is exactly what the first attempt at this
    fix did).

    So the fixture is a file we CREATE, under the harness tempdir but
    beside the session sandbox rather than inside it: absolute on every
    platform, guaranteed to exist, and provably outside the root — the
    same shape ``test_sibling_dir_sharing_the_root_prefix_is_403`` uses.
    """
    sid, _root = _setup(harness)
    outside = harness.temp_dir / "beside-the-sandbox"
    outside.mkdir(parents=True, exist_ok=True)
    secret = outside / "secret.txt"
    secret.write_text("OUTSIDE_THE_SANDBOX_MARKER", encoding="utf-8")

    r = _download(harness, sid, str(secret), "attachment", expect=403)
    assert b"OUTSIDE_THE_SANDBOX_MARKER" not in r.body, "must not leak file contents on 403"


def test_dotdot_rejected_403(harness: FunctionalHarness):
    sid, root = _setup(harness)
    _download(harness, sid, str(root) + "/../notes.txt", "attachment", expect=403)


def test_unknown_session_404(harness: FunctionalHarness):
    _setup(harness, "sess_present_1")
    r = harness.http(
        "GET",
        "/api/files/download",
        params={"session_id": "sess_does_not_exist", "path": "/tmp/x.txt"},
        expect=404,
    )
    assert r.body, "error envelope should carry a body"


def test_invalid_disposition_400(harness: FunctionalHarness):
    sid, root = _setup(harness)
    _download(harness, sid, str(root / "notes.txt"), "download", expect=400)


# ─── Android client's exact query string ────────────────────────────────────
#
# The Kotlin client (src/apps/android_mobile/.../chat/PresentFiles.kt,
# downloadUrl) builds the query itself with java.net.URLEncoder and then
# rewrites `+` back to `%20`, so its wire bytes differ from everything above —
# which is precisely the case a unit test on the URL string cannot catch. The
# server's query parser has to decode `%20` as a space for a presented file
# with a space in its name to open at all, and a space is the single most
# common character in a file the agent chooses to show you.

SPACED_BODY = b"a file whose name has a space in it\n"


def _spaced_sandbox(harness: FunctionalHarness) -> Path:
    root = Path(harness.temp_dir) / "present-files-spaced"
    root.mkdir(parents=True, exist_ok=True)
    (root / "my notes.md").write_bytes(SPACED_BODY)
    return root


def test_android_percent_twenty_path_decodes_to_a_space(harness: FunctionalHarness):
    """The Android card's exact wire form: `my%20notes.md`, not `my+notes.md`."""
    _create_session(harness, "sess_present_android")
    root = _spaced_sandbox(harness)
    _set_session_cwd(harness, "sess_present_android", str(root))

    encoded_path = urllib.parse.quote(str(root / "my notes.md"), safe="")
    assert "%20" in encoded_path, "the Android client percent-encodes spaces as %20"
    assert "+" not in encoded_path, "the Android client never emits a form-style plus"

    query = (
        "?session_id=sess_present_android"
        f"&path={encoded_path}"
        "&disposition=inline"
    )
    r = harness.http("GET", f"/api/files/download{query}", expect=200)
    assert r.body == SPACED_BODY, (
        "the server did not decode %20 into a space, so the Android client's "
        "preview of any file with a space in its name would 404"
    )
    assert 'filename="my notes.md"' in _header(r, "Content-Disposition"), (
        "the decoded name must survive into Content-Disposition so a viewer "
        "app and the Open action agree on what the file is called"
    )


# ─── The boundary cases only a real directory can prove ───────────────────
#
# `isInsideRoot`'s prefix rule ("the character after the root must be a
# separator") is a pure-string test in Zig and it passes — but a real sibling
# directory that shares the sandbox's name prefix (`present-files-ws` vs
# `present-files-ws-evil`) is the shape that actually leaks a file if the rule
# is wrong. The reverse matters just as much: refusing the sibling must not
# refuse the sandbox's own subdirectories. Plan:
# docs/plans/2026-09-29-present-files-sandbox-parity.md — the same shared rule
# the `present_files` tool applies, so anything the tool accepts is servable
# here and the card is never dead.

SECRET_BODY = b"a sibling directory must never be served\n"


def _sandbox_with_sibling(harness: FunctionalHarness) -> tuple[str, Path]:
    """Sandbox `<tmp>/present-files-ws` plus sibling `<tmp>/present-files-ws-evil`."""
    _create_session(harness, "sess_present_boundary")
    root = Path(harness.temp_dir) / "present-files-ws"
    root.mkdir(parents=True, exist_ok=True)
    (root / "notes.txt").write_bytes(b"inside\n")
    (root / "nested").mkdir(parents=True, exist_ok=True)
    (root / "nested" / "deep.txt").write_bytes(b"nested inside\n")

    sibling = Path(str(root) + "-evil")
    sibling.mkdir(parents=True, exist_ok=True)
    (sibling / "secret.txt").write_bytes(SECRET_BODY)
    _set_session_cwd(harness, "sess_present_boundary", str(root))
    return "sess_present_boundary", root


def test_sibling_dir_sharing_the_root_prefix_is_403(harness: FunctionalHarness):
    """`present-files-ws-evil` is NOT inside `present-files-ws`."""
    sid, root = _sandbox_with_sibling(harness)
    sibling = Path(str(root) + "-evil") / "secret.txt"
    assert sibling.exists(), "fixture must exist, else the test proves nothing"
    r = harness.http(
        "GET",
        "/api/files/download",
        params={"session_id": sid, "path": str(sibling)},
        expect=403,
    )
    assert SECRET_BODY not in r.body, "a sibling directory must never be served"


def test_nested_file_inside_the_root_is_still_200(harness: FunctionalHarness):
    """The other half of the same rule — refusing the sibling must not
    refuse the sandbox's own subdirectories."""
    sid, root = _sandbox_with_sibling(harness)
    r = harness.http(
        "GET",
        "/api/files/download",
        params={"session_id": sid, "path": str(root / "nested" / "deep.txt")},
        expect=200,
    )
    assert r.body == b"nested inside\n"


def test_a_dotted_filename_is_not_treated_as_traversal(harness: FunctionalHarness):
    """`report..html` is one filename, not a `..` segment. The endpoint and
    the `present_files` tool share one rule now, and a filename with two
    dots in it is a thing the agent presents."""
    _create_session(harness, "sess_present_dots")
    root = Path(harness.temp_dir) / "present-files-dots"
    root.mkdir(parents=True, exist_ok=True)
    (root / "IRON-11463 SB-02 .. final.html").write_bytes(b"<h1>dots</h1>")
    _set_session_cwd(harness, "sess_present_dots", str(root))

    r = harness.http(
        "GET",
        "/api/files/download",
        params={"session_id": "sess_present_dots", "path": str(root / "IRON-11463 SB-02 .. final.html")},
        expect=200,
    )
    assert r.body == b"<h1>dots</h1>"
