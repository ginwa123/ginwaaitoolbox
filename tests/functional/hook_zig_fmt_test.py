"""The project hook formats edited Zig without churning legacy files.

The hook itself (.nalar/hooks/register_hook.lua) is the deliverable, and it
runs INSIDE nalar's vendored Lua interpreter, on every tool dispatch. There
is no way to reach it over HTTP without driving a whole LLM agent loop, so
these tests execute the real hook file through a Lua interpreter and assert
on what it did to the file on disk.

Vendored Lua is 5.4.9 (vendor/lua/lua.h: LUA_VERSION_RELEASE 9) and the
system lua5.4 here is also 5.4.9, so running the shipped file under the
system interpreter exercises the same semantics nalar gets. The test skips
when no system Lua is present rather than silently passing.

The bug this guards is measured, not hypothetical: `zig fmt` rewrites the
whole file, and 20 of 40 sampled src/**/*.zig files are not fmt-clean
(design_model.zig alone reformats by 1251 lines). An ungated hook turns a
small edit into a diff of unrelated churn, so the HEAD-cleanliness guard is
the behaviour under test — not an implementation detail.

Run:
    python3 -m pytest tests/functional/hook_zig_fmt_test.py -v
"""

from __future__ import annotations

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


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(repo), capture_output=True, text=True, timeout=30
    )


def _fmt_clean(path: Path) -> bool:
    return subprocess.run(
        ["zig", "fmt", "--check", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
    ).returncode == 0


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A throwaway git repo holding one fmt-clean and one legacy-dirty .zig."""
    r = tmp_path / "repo"
    (r / "src").mkdir(parents=True)
    _git(r.parent, "init", "-q", str(r))
    _git(r, "config", "user.email", "t@example.com")
    _git(r, "config", "user.name", "t")

    # Already canonical: the hook must keep it that way through an edit.
    (r / "src" / "clean.zig").write_text(
        "pub fn main() void {\n    const x = 1;\n}\n", encoding="utf-8"
    )
    # Legacy hand-style: multi-line call args that zig fmt would collapse.
    (r / "src" / "legacy.zig").write_text(
        "pub fn main() void {\n"
        "    call(veryLongArgumentName,\n"
        "        anotherRatherLongArgument,\n"
        "        &.{});\n"
        "}\n",
        encoding="utf-8",
    )
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")

    assert _fmt_clean(r / "src" / "clean.zig"), "fixture clean.zig must be fmt-clean"
    assert not _fmt_clean(r / "src" / "legacy.zig"), "fixture legacy.zig must be fmt-dirty"
    return r


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


def test_keeps_fmt_dirty_edit_canonical(lua: str, repo: Path) -> None:
    """A 1-line edit to an already-clean file stays canonically formatted.

    Without the hook the edit lands in whatever shape the model wrote it;
    the file is then no longer fmt-clean. This is the payoff of the whole
    change: new Zig lands canonical without the model having to remember.
    """
    target = repo / "src" / "clean.zig"
    target.write_text(
        "pub fn main() void {\n    const x    =    1;\n    const y = 2;\n}\n",
        encoding="utf-8",
    )
    assert not _fmt_clean(target), "precondition: edit made the file dirty"

    r = _run_hook(lua, repo, "text_replace", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert _fmt_clean(target), (
        "hook left an edited clean file unformatted:\n" + target.read_text()
    )
    assert target.read_text() == "pub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n"


def test_legacy_hand_styled_file_is_untouched(lua: str, repo: Path) -> None:
    """The churn guard: a legacy dirty file keeps its hand style exactly.

    Its HEAD version was not fmt-clean, so formatting it would rewrite the
    whole file. The edit must survive verbatim — this is the failure that
    would otherwise land a 300-line diff on someone's PR.
    """
    target = repo / "src" / "legacy.zig"
    edited = (
        "pub fn main() void {\n"
        "    call(veryLongArgumentName,\n"
        "        anotherRatherLongArgument,\n"
        "        &.{1, 2});\n"
        "}\n"
    )
    target.write_text(edited, encoding="utf-8")

    r = _run_hook(lua, repo, "text_replace", '{"path": "src/legacy.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert target.read_text() == edited, (
        "hook reformatted a legacy hand-styled file it must leave alone:\n"
        + target.read_text()
    )


def test_new_untracked_file_is_formatted(lua: str, repo: Path) -> None:
    """A brand-new file has no committed style to protect, so format it."""
    target = repo / "src" / "fresh.zig"
    target.write_text("pub fn f() void {\n    const a    =    1;\n}\n", encoding="utf-8")

    r = _run_hook(lua, repo, "write_file", '{"path": "src/fresh.zig", "content": "x"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert _fmt_clean(target), "a newly created .zig should come out canonical"


def test_syntax_broken_file_is_not_corrupted(lua: str, repo: Path) -> None:
    """A mid-edit file that does not parse must be left byte-for-byte alone.

    zig fmt exits non-zero without writing on a parse error, so the guard
    never has to second-guess it; this asserts the real behaviour rather
    than trusting the manual.
    """
    target = repo / "src" / "clean.zig"
    broken = "pub fn main() void {\n    const x = ;\n}\n"
    target.write_text(broken, encoding="utf-8")

    r = _run_hook(lua, repo, "text_replace", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"

    assert target.read_text() == broken, "hook corrupted a syntactically broken file"


def test_non_zig_and_unknown_tools_are_noops(lua: str, repo: Path) -> None:
    """Only .zig is gated/handled here; other paths and tools change nothing."""
    target = repo / "src" / "notes.txt"
    target.write_text("const    x=1\n", encoding="utf-8")

    r = _run_hook(lua, repo, "write_file", '{"path": "src/notes.txt", "content": "x"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert target.read_text() == "const    x=1\n", "hook touched a non-.zig file"

    # A read-only tool that happens to carry a .zig path must not format.
    z = repo / "src" / "clean.zig"
    before = z.read_text()
    r = _run_hook(lua, repo, "read_file", '{"path": "src/clean.zig"}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert z.read_text() == before, "hook formatted on a non-edit tool"


def test_absolute_path_is_handled(lua: str, repo: Path) -> None:
    """Tool arguments can carry an absolute path; the guard must still work."""
    target = repo / "src" / "clean.zig"
    target.write_text("pub fn main() void {\n    const q    =    3;\n}\n", encoding="utf-8")

    r = _run_hook(lua, repo, "text_replace", f'{{"path": "{target}"}}')
    assert r.returncode == 0, f"hook errored: {r.stderr}"
    assert _fmt_clean(target), "absolute-path edit was not formatted"


def test_missing_file_does_not_error(lua: str, repo: Path) -> None:
    """A deleted or never-written target must fail open, not raise."""
    r = _run_hook(lua, repo, "text_replace", '{"path": "src/gone.zig"}')
    assert r.returncode == 0, f"hook errored on a missing file: {r.stderr}"