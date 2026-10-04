"""Tests for the functional-suite shard selector.

These run WITHOUT a pabrik binary, same as ``harness_safety_test.py``.

The property that matters is not "the numbers come out right for this
input" but the one a CI matrix typo would silently break: **the shards
must partition the suite.** A shard index that selects nothing exits 0
and reports green, so a selector that quietly returns an empty list when
handed a bad index deletes a third of the suite with no red check
anywhere. Hence the explicit failure tests below.
"""

from __future__ import annotations

import pytest

import func_shard
from func_shard import (
    INDEX_ENV,
    TOTAL_ENV,
    ShardConfigError,
    resolve_shard,
    select,
)

ITEMS = list(range(100))


def test_unset_means_not_sharded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(TOTAL_ENV, raising=False)
    monkeypatch.delenv(INDEX_ENV, raising=False)
    assert resolve_shard() is None


def test_empty_string_means_not_sharded(monkeypatch: pytest.MonkeyPatch) -> None:
    # An exported-but-empty variable is what a shell produces from
    # `${VAR:-}`; treating it as "no shards" is right, and treating
    # "" as 0 would silently select a single shard.
    monkeypatch.setenv(TOTAL_ENV, "")
    monkeypatch.setenv(INDEX_ENV, "")
    assert resolve_shard() is None


def test_half_configured_is_an_error_not_a_single_shard(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(TOTAL_ENV, "3")
    monkeypatch.delenv(INDEX_ENV, raising=False)
    with pytest.raises(ShardConfigError, match="must be set together"):
        resolve_shard()


def test_non_integer_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(TOTAL_ENV, "three")
    monkeypatch.setenv(INDEX_ENV, "0")
    with pytest.raises(ShardConfigError, match="must be integers"):
        resolve_shard()


def test_index_out_of_range_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    # The exact CI failure mode: a matrix that runs shard 1..3 while
    # the total is 2 would otherwise report green having run nothing.
    monkeypatch.setenv(TOTAL_ENV, "2")
    monkeypatch.setenv(INDEX_ENV, "2")
    with pytest.raises(ShardConfigError, match="out of range"):
        resolve_shard()


def test_zero_total_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(TOTAL_ENV, "0")
    monkeypatch.setenv(INDEX_ENV, "0")
    with pytest.raises(ShardConfigError, match=">= 1"):
        resolve_shard()


def test_round_trip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(TOTAL_ENV, " 3 ")
    monkeypatch.setenv(INDEX_ENV, " 1 ")
    # Whitespace tolerated: the values arrive through YAML `env:` blocks
    # and a trailing space is an easy, invisible typo.
    assert resolve_shard() == (1, 3)


@pytest.mark.parametrize("total", [1, 2, 3, 4, 7, 100])
def test_shards_partition_the_whole_suite(total: int) -> None:
    """Union == the input, no duplicates, and every shard non-empty.

    The last clause is the one that catches a total larger than the
    suite: shard 60 of 100 selects nothing and would pass.
    """
    seen: list[int] = []
    for index in range(total):
        seen.extend(select(ITEMS, index, total))
    assert sorted(seen) == ITEMS, "a test was dropped or run twice"
    assert len(seen) == len(set(seen)), "a test ran in two shards"


@pytest.mark.parametrize("total", [1, 2, 3, 4, 7])
def test_shard_sizes_differ_by_at_most_one(total: int) -> None:
    sizes = [len(select(ITEMS, i, total)) for i in range(total)]
    assert max(sizes) - min(sizes) <= 1, sizes
    assert sum(sizes) == len(ITEMS)


def test_select_rejects_a_bad_total() -> None:
    with pytest.raises(ShardConfigError, match=">= 1"):
        select(ITEMS, 0, 0)


def test_select_rejects_a_bad_index() -> None:
    with pytest.raises(ShardConfigError, match="out of range"):
        select(ITEMS, 5, 3)


def test_env_var_names_are_the_documented_contract() -> None:
    # The workflow sets these two names; a rename here without a rename
    # there makes every shard silently run the full suite (3x the work,
    # no error) or, worse, run nothing.
    assert func_shard.TOTAL_ENV == "PABRIK_FUNC_SHARD_TOTAL"
    assert func_shard.INDEX_ENV == "PABRIK_FUNC_SHARD_INDEX"
