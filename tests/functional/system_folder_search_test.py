"""Functional wire tests for GET /api/system/folder?action=search.

Task 4 of docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md.

Verifies the backend recursive search endpoint over the real HTTP wire
using the functional harness (fresh tmpdir HOME, free port excl 8081):

  1. q=comp&limit=50 returns <=50, contains the components path,
     excludes node_modules paths.
  2. Empty q returns <=50 (top-N, not the whole tree).
  3. limit=5000 clamps to <=200 (hard cap).
  4. action=list single-level contract unchanged (regression guard).
  5. Perf: search on the 300-file fixture completes <5s; actual ms logged.

Fixture cwd (under pytest tmp_path, NOT the harness HOME):
  <cwd>/node_modules/big/      (skip-listed)
  <cwd>/zig-out/               (skip-listed)
  <cwd>/src/components/        (Button.vue, Modal.vue, ... — matches q=comp)
  <cwd>/gen/file_000.txt ... file_299.txt  (300 generated files)
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from harness import FunctionalHarness


def _build_search_fixture(base: Path) -> Path:
    """Build the search fixture cwd. Returns the cwd path."""
    cwd = base / "search-proj"
    # Skip-listed dirs (must never appear in search results).
    (cwd / "node_modules" / "big").mkdir(parents=True)
    for i in range(5):
        (cwd / "node_modules" / "big" / f"comp_shim_{i:02d}.js").write_text(
            f"// node_modules shim {i}\n"
        )
    (cwd / "zig-out").mkdir(parents=True)
    for i in range(3):
        (cwd / "zig-out" / f"comp_artifact_{i:02d}.bin").write_text(f"bin {i}")
    # Real source tree — matches q=comp.
    comp_dir = cwd / "src" / "components"
    comp_dir.mkdir(parents=True)
    for name in ("Button.vue", "Modal.vue", "Composer.ts", "compare_util.ts"):
        (comp_dir / name).write_text(f"// {name}\n")
    (cwd / "src").joinpath("main.ts").write_text("// main\n")
    # 300 generated files for the perf + cap assertions.
    gen = cwd / "gen"
    gen.mkdir(parents=True)
    for i in range(300):
        (gen / f"file_{i:03d}.txt").write_text(f"generated {i}\n")
    return cwd


@pytest.fixture
def search_cwd(tmp_path: Path) -> Path:
    return _build_search_fixture(tmp_path)


def _search(
    harness: FunctionalHarness,
    cwd: Path,
    q: str,
    limit: int,
    timeout_s: float = 15.0,
) -> list[dict]:
    r = harness.http(
        "GET",
        "/api/system/folder",
        params={
            "action": "search",
            "path": str(cwd),
            "q": q,
            "limit": limit,
        },
        expect=200,
        timeout_s=timeout_s,
    )
    body = r.json()
    assert "entries" in body, f"search response missing 'entries': {body!r}"[:500]
    return body["entries"]


def test_search_comp_returns_components_excludes_node_modules(
    harness: FunctionalHarness, search_cwd: Path
) -> None:
    """q=comp&limit=50: <=50 rows, hits components/, no node_modules paths."""
    entries = _search(harness, search_cwd, "comp", 50)
    assert len(entries) <= 50, f"expected <=50 rows, got {len(entries)}"
    paths = [e["path"] for e in entries]
    assert any("components" in p for p in paths), (
        f"expected a components hit in {len(paths)} rows: {paths[:5]!r}"
    )
    bad = [p for p in paths if "node_modules" in p]
    assert not bad, f"skip-list violated, node_modules leaked: {bad[:5]!r}"
    bad_out = [p for p in paths if "zig-out" in p]
    assert not bad_out, f"skip-list violated, zig-out leaked: {bad_out[:5]!r}"
    # Wire shape guard: snake_case fields on every row.
    for e in entries:
        assert "is_directory" in e, f"row missing is_directory: {e!r}"[:300]
        assert "name" in e and "path" in e, f"row missing name/path: {e!r}"[:300]


def test_search_empty_q_returns_top_n_not_whole_tree(
    harness: FunctionalHarness, search_cwd: Path
) -> None:
    """Empty q returns <=50 (top-N), not the whole ~312-file tree."""
    entries = _search(harness, search_cwd, "", 50)
    assert len(entries) <= 50, (
        f"empty q must return top-N (<=50), got {len(entries)} — whole tree leaked"
    )
    assert len(entries) > 0, "empty q returned zero rows, expected top-N"


def test_search_limit_clamps_to_200(
    harness: FunctionalHarness, search_cwd: Path
) -> None:
    """limit=5000 clamps to the hard cap (<=200 rows)."""
    entries = _search(harness, search_cwd, "", 5000)
    assert len(entries) <= 200, (
        f"limit=5000 must clamp to <=200, got {len(entries)}"
    )


def test_list_single_level_contract_unchanged(
    harness: FunctionalHarness, search_cwd: Path
) -> None:
    """action=list still returns the single-level {entries:[...]} contract."""
    r = harness.http(
        "GET",
        "/api/system/folder",
        params={"action": "list", "path": str(search_cwd)},
        expect=200,
    )
    body = r.json()
    assert "entries" in body, f"list response missing 'entries': {body!r}"[:500]
    entries = body["entries"]
    names = {e["name"] for e in entries}
    # Single level: top-level dirs only, no nested gen/file_000.txt rows.
    assert "src" in names, f"expected 'src' in top-level list, got {sorted(names)!r}"
    assert "gen" in names, f"expected 'gen' in top-level list, got {sorted(names)!r}"
    assert "node_modules" in names, (
        f"list must NOT apply the search skip-list, got {sorted(names)!r}"
    )
    assert not any("file_000" in e["name"] for e in entries), (
        "list must be single-level — nested gen/ rows leaked"
    )
    for e in entries:
        assert "is_directory" in e, f"list row missing is_directory: {e!r}"[:300]


def test_search_perf_300_files_under_5s(
    harness: FunctionalHarness,
    search_cwd: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Search over the 300-file fixture completes <5s; actual ms logged."""
    start = time.monotonic()
    entries = _search(harness, search_cwd, "file_", 50)
    elapsed_ms = (time.monotonic() - start) * 1000.0
    print(f"\n[perf] search q=file_ limit=50 over 300-file fixture: "
          f"{elapsed_ms:.1f}ms, {len(entries)} rows")
    # Flush so -v / -s output shows the timing even on pass.
    capsys.readouterr()
    print(f"[perf] search took {elapsed_ms:.1f}ms ({len(entries)} rows)")
    assert elapsed_ms < 5000.0, (
        f"search took {elapsed_ms:.1f}ms, exceeds 5s budget"
    )
    assert len(entries) > 0, "expected hits for q=file_ on the gen/ fixture"
