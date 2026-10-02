"""The project hook runs zig fmt on edited Zig files.

The hook itself (.nalar/hooks/register_hook.lua) is the deliverable, and it
runs INSIDE nalar's vendored Lua interpreter, on every tool dispatch. There
is no way to reach it over HTTP without driving a whole LLM agent loop, so
these tests execute the real hook file through a Lua interpreter and assert
on what it did to the file on disk.

Vendored Lua is 5.4.9 (vendor/lua/lua.h: LUA_VERSION_RELEASE 9) and the
system lua5.4 here is also 5.4.9, so running the shipped file under the
system interpreter exercises the same semantics nalar gets. The test skips
when no system Lua is present rather than silently passing.

Behaviour under test: a .zig file edited by the agent comes out canonically
formatted, and `zig fmt` rewrites the WHOLE file — pre-existing lines that
were not fmt-clean get reformatted too. That whole-file rewrite is intended,
not a bug: it is what "formatted" means for Zig, and the cleanup is wanted.

Run:
    uv run --with pytest python -m pytest tests/functional/hook_zig_fmt_test.py -v
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
HOOK = REPO_ROOT / ".nalar" / "hooks" / "register_hook.lua"


def _lua() -> str | None:
    return shutil.which("lua5.4") or shutil.which("lua")


@pytest.fixture(scope="module")
def lua() -> str:
    exe = _lua()
    if exe is None:
        pytest.skip("no system lua available to run the project hook")
    return exe


def _run_hook(lua: str, cwd: Path, tool_name: str, arguments: str) -> subprocess.CompletedProcess:
    """Drive the REAL hook: load it, call init("post_tool_use", data)."""
    driver = textwrap.dedent(
        f"""
        local hook = assert(loadfile({str(HOOK)!r}))
        hook()
        local data = {{
          tool_name = {tool_name!r},
          arguments = {arguments!r},
          session_id = "sess_test",
          cwd = {str(cwd)!r},
          model = "test",
        }}
        local ret = init("post_tool_use", data)
        assert(ret == nil, "hook must return nil, got " .. tostring(ret))
        """
    )
    return subprocess.run(
        [lua, "-e", driver],
        capture_output=True,
        text=True,
        timeout=60,
        cwd=str(cwd),
    )


def _fmt_clean(path: Path) -> bool:
    return subprocess.run(
        ["zig", "fmt", "--check", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
    ).returncode == 0


@pytest.fixture
def workdir(tmp_path: Path) -> Path:
    """A scratch dir holding one fmt-clean and one not-fmt-clean .zig file."""
    d = tmp_path / "proj"
    (d / "src").mkdir(parents=True)
    (d / "src" / "clean.zig").write_text(
        "pub fn main() void {\n    const x = 1;\n}\n", encoding="utf-8"
    )
    # Multi-line call args that zig fmt collapses onto one long line.
    (d / "src" / "legacy.zig").write_text(
        "pub fn main() void {\n"
        "    call(veryLongArgumentName,\n"
        "        anotherRatherLongArgument,\n"
        "        &.{});\n"
        "}\n",
        encoding="utf-8",
    )
    return d


def test_hook_file_is_valid_lua(lua: str) -> None:
    """The shipped hook must parse under the same Lua nalar embeds."""
    assert HOOK.exists(), f"project hook missing: {HOOK}"
    r = subprocess.run(
        [lua, "-e", f"assert(loadfile({str(HOOK)!r}))"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert r.returncode == 0, f"hook failed to parse: {r.stderr}"


def test_formats_the_edited_region(lua: str, workdir: Path) -> None:
    """The headline behaviour: an edit lands canonically formatted.

    Without the hook the edit sits in whatever shape the model wrote it and
    the file is left dirty. This is the payoff of the whole change: new Zig
    comes out canonical without the model having to remember.
    """
    target = workdir / "src" / "clean.zig"
    target.write_text(
        "pub fn main() void {\n    const x    =    1;\n    const y = 2;\n}\n",
        encoding="utf-8",
    )
    assert not _fmt_clean(target), "precondition: the edit made the file dirty"

    r = _run_hook(lua, workdir, "text_replace", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert _fmt_clean(target), (
        "hook left an edited file unformatted:\n" + target.read_text()
    )
    assert target.read_text() == "pub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n"


def test_formats_whole_file_not_just_the_edit(lua: str, workdir: Path) -> None:
    """Pre-existing unformatted lines are normalised too — by design.

    `zig fmt` is a whole-file rewriter. Editing a line of a file that was
    already not-fmt-clean sweeps the rest of the file canonical as well.
    That churn is intentional: it is what "this file is formatted" means,
    and it only ever lands in the file the agent just edited.
    """
    target = workdir / "src" / "legacy.zig"
    target.write_text(
        "pub fn main() void {\n"
        "    call(veryLongArgumentName,\n"
        "        anotherRatherLongArgument,\n"
        "        &.{1, 2});\n"
        "}\n",
        encoding="utf-8",
    )
    assert not _fmt_clean(target), "precondition: file starts out not-fmt-clean"

    r = _run_hook(lua, workdir, "text_replace", '{"path": "src/legacy.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert _fmt_clean(target), (
        "hook did not bring the whole file to canonical form:\n"
        + target.read_text()
    )
    # The edit must survive the reformat. Matched with a tolerant pattern
    # because Zig 0.16 renders `.{1, 2}` as `.{ 1, 2 }` — asserting the
    # literal text would be asserting my own spacing, not the behaviour.
    assert re.search(r"&\.\{\s*1,\s*2\s*\}", target.read_text()), (
        "the actual edit did not survive formatting:\n" + target.read_text()
    )
    assert "veryLongArgumentName" in target.read_text(), "existing code was lost"


def test_syntax_broken_file_is_not_corrupted(lua: str, workdir: Path) -> None:
    """A mid-edit file that does not parse must be left byte-for-byte alone.

    zig fmt exits non-zero without writing on a parse error, so a half-typed
    file is never mangled. This asserts the real behaviour rather than
    trusting the manual.
    """
    target = workdir / "src" / "clean.zig"
    broken = "pub fn main() void {\n    const x = ;\n}\n"
    target.write_text(broken, encoding="utf-8")

    r = _run_hook(lua, workdir, "text_replace", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert target.read_text() == broken, "hook corrupted a syntactically broken file"


def test_new_file_is_formatted(lua: str, workdir: Path) -> None:
    """A brand-new .zig file is formatted like any other."""
    target = workdir / "src" / "fresh.zig"
    target.write_text("pub fn f() void {\n    const a    =    1;\n}\n", encoding="utf-8")

    r = _run_hook(lua, workdir, "write_file", '{"path": "src/fresh.zig", "content": "x"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert _fmt_clean(target), "a newly created .zig should come out canonical"


def test_absolute_path_is_handled(lua: str, workdir: Path) -> None:
    """Tool arguments can carry an absolute path."""
    target = workdir / "src" / "clean.zig"
    target.write_text("pub fn main() void {\n    const q    =    3;\n}\n", encoding="utf-8")

    r = _run_hook(lua, workdir, "text_replace", f'{{"path": "{target}"}}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert _fmt_clean(target), "absolute-path edit was not formatted"


def test_non_zig_and_unknown_tools_are_noops(lua: str, workdir: Path) -> None:
    """Only .zig and the prettier set are handled; other paths/tools change nothing."""
    target = workdir / "src" / "notes.txt"
    target.write_text("const    x=1\n", encoding="utf-8")

    r = _run_hook(lua, workdir, "write_file", '{"path": "src/notes.txt", "content": "x"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert target.read_text() == "const    x=1\n", "hook touched a non-.zig file"

    # A read-only tool that happens to carry a .zig path must not format.
    z = workdir / "src" / "clean.zig"
    before = z.read_text()
    r = _run_hook(lua, workdir, "read_file", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert z.read_text() == before, "hook formatted on a non-edit tool"


def test_missing_file_does_not_error(lua: str, workdir: Path) -> None:
    """A deleted or never-written target must fail open, not raise."""
    r = _run_hook(lua, workdir, "text_replace", '{"path": "src/gone.zig"}')
    assert r.returncode == 0, f"hook errored on a missing file: {r.stderr}"