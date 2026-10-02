"""Wire tests for GET /api/system/folder against a real per-platform host.

Why this file exists next to the Zig unit tests
-----------------------------------------------
The endpoint's whole job is to hand the client the SERVER's home, so on
Windows every path it puts on the wire is a backslash path
(``C:\\Users\\ginwa\\Documents``). That is the shape that breaks JSON: a
lone backslash is an invalid escape, ``JSON.parse`` throws, and the
folder picker renders empty instead of listing anything.

``src/http_handlers/system_folder.zig`` covers that with synthetic
``C:\\...`` strings -- fast, and enough to pin the escaping. What it
cannot see is that ``std.fs.path`` reads a REAL Windows path differently:
``isAbsolute("C:\\x")`` is true on windows-2022 and false on ubuntu, and
``dirname`` splits on ``\\`` there and on ``/`` here. This file is the
only place those two are exercised against the real thing.

It runs on all three CI cells (ubuntu-24.04 / macos-15 / windows-2022)
with no platform gate, because every assertion is derived from
``harness.temp_dir`` or ``tmp_path`` -- both real ``mkdtemp`` outputs,
absolute on every platform -- and from ``entries[].path``, which is the
value the server itself emitted.

Note on shape: ``path`` / ``parent`` are relative to home ONLY when the
directory is under home. A directory outside home (this fixture's
``tmp_path``) keeps its absolute path, and that is what the tests below
assert.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from harness import FunctionalHarness

# Content chosen to exercise every branch of the handler's `jsonEscape`:
# a quote, a backslash, a tab and a newline. On Windows a file path also
# arrives with backslashes, so a dropped escape shows up here as a
# JSONSyntaxError rather than as a silently wrong string.
TRICKY_CONTENT = 'quote " backslash \\ tab \t newline \nend'


@pytest.fixture
def probe_root(tmp_path: Path) -> Path:
    """A non-empty directory tree to point `path=` at.

    `git init` for the same reason as the Zig fixtures: `listDirectory`
    batches one `git check-ignore` per directory, and a directory that is
    not a work tree makes the call exit 128 -> "nothing ignored", which
    is the same outcome but by accident. Initialising makes the fixture
    deterministic whether or not tmp_path happens to sit inside a repo.
    """
    root = tmp_path / "sf-probe"
    (root / "sub" / "child").mkdir(parents=True)
    # write_bytes, not write_text: `write_text` applies newline
    # translation, so the `\n` above would come back as `\r\n` on Windows
    # and the content assertion would fail on the one cell this file
    # exists to cover. The handler returns the file's bytes verbatim.
    (root / "sub" / "note.txt").write_bytes(TRICKY_CONTENT.encode("utf-8"))
    (root / ".hidden").write_bytes(b"dotfiles are filtered out\n")
    subprocess.run(
        ["git", "-C", str(root), "init", "--initial-branch=main", "--quiet"],
        check=True,
        timeout=30,
    )
    return root


def _list(harness: FunctionalHarness, path: str | None = None) -> dict:
    params: dict[str, str] = {"action": "list"}
    if path is not None:
        params["path"] = path
    return harness.http("GET", "/api/system/folder", params=params, expect=200).json()


def test_action_list_with_no_path_reports_the_server_home(harness: FunctionalHarness) -> None:
    """The call the sidebar, the kanban picker and Android all make first.

    On native Windows (cmd/pwsh) `HOME` is unset — `getHomeDirectory`
    falls back to USERPROFILE then HOMEDRIVE+HOMEPATH. The harness sets
    HOME and USERPROFILE to the same isolated tmpdir, so the answer must
    be that directory either way, and it must be ABSOLUTE or the handler
    rejects the request with 500 before it ever lists anything.
    """
    home = str(harness.temp_dir)
    body = _list(harness)

    assert body["home"] == home
    assert body["absolute"] == home
    assert body["path"] == "/", "home itself is the root of the relative tree"
    # `getParentPath` refuses to go above home, so there is no parent key
    # here. Asserted rather than assumed: a client that renders a "up"
    # button reads this key.
    assert "parent" not in body
    assert isinstance(body["entries"], list)
    assert harness.health(), "server died while listing home"


def test_explicit_home_path_matches_the_implicit_listing(harness: FunctionalHarness) -> None:
    """`?path=<home>` must be indistinguishable from the no-path form.

    This is the round-trip the frontend relies on: it renders `absolute`
    back into the next request. If the two forms disagreed, navigating to
    "home" from anywhere would land somewhere else.
    """
    home = str(harness.temp_dir)
    implicit = _list(harness)
    explicit = _list(harness, home)

    assert explicit["home"] == implicit["home"] == home
    assert explicit["absolute"] == implicit["absolute"] == home
    assert explicit["path"] == implicit["path"] == "/"
    assert harness.health()


def test_home_spelled_with_forward_slashes_has_no_parent_above_it(
    harness: FunctionalHarness,
) -> None:
    """The "do not go above home" guard, on the wire.

    `getParentPath` compares the requested path against home so it can
    refuse to hand out a parent that sits ABOVE home. It used to compare
    raw bytes, so a second spelling of the same directory missed the
    match: on Windows the frontend builds `C:/Users/ginwa` by string
    concatenation while home is `C:\\Users\\ginwa`, and the guard then
    returned `C:/` -- one level too high. The picker renders that value as
    its "up" target. This is the same defect the Zig unit test
    ``getParentPath: a trailing forward slash is only normalized on
    Windows`` failed on in the `backend (Windows X64)` cell; the Zig test
    cannot see the JSON, and this one cannot see the string logic, so
    both are needed.

    ``Path.as_posix()`` is the identity on Linux -- so the assertion is
    vacuous there and only the Windows cell can fail it -- and yields
    ``C:/...`` on Windows. That keeps the file platform-gate-free, which
    is the whole point of this file.
    """
    home = harness.temp_dir
    spelled = home.as_posix()

    body = _list(harness, spelled)

    assert body["home"] == str(home)
    assert body["absolute"] == spelled, "the server echoes the path it was given"
    assert "parent" not in body, (
        f"home has no parent above it; a parent for {spelled!r} means the "
        f"guard failed to match it against home {str(home)!r}"
    )
    assert harness.health()


def test_listing_a_subdirectory_navigates_by_entry_path(
    harness: FunctionalHarness, probe_root: Path
) -> None:
    """The picker's actual walk: list, click an entry, list again.

    `FolderExplorer.vue` expands by sending back `entry.path` verbatim, so
    that value has to be a path the handler accepts on the NEXT call. The
    fixture lives outside home, so `path` / `parent` stay absolute here.
    """
    body = _list(harness, str(probe_root))
    names = {entry["name"] for entry in body["entries"]}

    assert "sub" in names
    assert ".hidden" not in names, "dotfiles are filtered before they reach the wire"

    sub_entry = next(entry for entry in body["entries"] if entry["name"] == "sub")
    assert sub_entry["is_directory"] is True
    assert sub_entry["is_symlink"] is False
    assert sub_entry["path"] == str(probe_root / "sub")

    nested = _list(harness, sub_entry["path"])
    assert {entry["name"] for entry in nested["entries"]} == {"note.txt", "child"}
    assert nested["parent"] == str(probe_root)
    assert harness.health(), f"server died navigating to {sub_entry['path']!r}"


def test_entries_serialize_snake_case_flags(harness: FunctionalHarness, probe_root: Path) -> None:
    """A camelCase `isDirectory` reads as undefined and every row becomes a file."""
    body = _list(harness, str(probe_root))
    for entry in body["entries"]:
        assert set(entry) >= {"name", "path", "is_directory", "is_symlink"}, entry
        assert isinstance(entry["is_directory"], bool)
        assert isinstance(entry["is_symlink"], bool)


def test_read_returns_content_that_survives_json_escaping(
    harness: FunctionalHarness, probe_root: Path
) -> None:
    """`action=read` escapes the body through the same `jsonEscape`.

    On Windows the file is reached through `\\`-joined absolute paths, so
    this is the branch where a missing escape turns into a parse error on
    the client rather than into a wrong character.
    """
    body = harness.http(
        "GET",
        "/api/system/folder",
        params={"path": str(probe_root / "sub"), "action": "read", "file": "note.txt"},
        expect=200,
    ).json()

    assert body["encoding"] == "utf-8"
    assert body["content"] == TRICKY_CONTENT


def test_search_hits_survive_json_escaping(
    harness: FunctionalHarness, probe_root: Path
) -> None:
    """`action=search` serializes entries through the SAME escaping.

    It used to carry a byte-identical copy of the list branch's loop;
    this pins that the two shapes still agree on the wire.
    """
    body = harness.http(
        "GET",
        "/api/system/folder",
        params={
            "path": str(probe_root),
            "action": "search",
            "q": "note",
            "limit": 50,
        },
        expect=200,
    ).json()

    hits = [entry for entry in body["entries"] if entry["name"] == "note.txt"]
    assert len(hits) == 1, body["entries"]
    assert hits[0]["path"] == str(probe_root / "sub" / "note.txt")
    assert hits[0]["is_directory"] is False


def test_request_without_an_action_returns_location_only(harness: FunctionalHarness) -> None:
    """The no-action shape has no `entries` key and that is load-bearing.

    `buildFolderInfoJson` exists to keep this body byte-compatible with
    the pre-refactor response; a client that does `body.entries.length`
    on it is relying on the key being absent.
    """
    listed = harness.http(
        "GET",
        "/api/system/folder",
        params={"path": str(harness.temp_dir), "action": "list"},
        expect=200,
    ).json()
    assert "entries" in listed, "action=list must still return entries"

    no_action = harness.http(
        "GET",
        "/api/system/folder",
        params={"path": str(harness.temp_dir)},
        expect=200,
    ).json()
    assert "entries" not in no_action, no_action
    assert no_action["home"] == str(harness.temp_dir)


def test_drive_relative_and_relative_paths_are_rejected(
    harness: FunctionalHarness, probe_root: Path
) -> None:
    """400, not a crash and not a wrong directory.

    On Windows `C:notes.txt` parses as a path but is drive-RELATIVE, so
    it must not be joined onto a base and opened — that would read the
    wrong file. Same reason a bare relative path is refused.
    """
    for path in ("relative/path", "C:notes.txt", "C|notes.txt"):
        response = harness.http(
            "GET",
            "/api/system/folder",
            params={"path": path, "action": "list"},
            expect=400,
        )
        assert response.json()["error"] == "path must be absolute", path
        assert harness.health(), f"server died on path={path!r}"


def test_a_missing_directory_is_403_not_500(harness: FunctionalHarness, probe_root: Path) -> None:
    """`listDirectory` maps every open failure to InvalidPath -> 403."""
    missing = probe_root / "definitely" / "not" / "here"
    response = harness.http(
        "GET",
        "/api/system/folder",
        params={"path": str(missing), "action": "list"},
        expect=403,
    )
    assert response.json()["error"] == "Directory not found"
    assert harness.health()
