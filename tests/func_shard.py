"""Deterministic sharding for the functional suites.

WHY THIS EXISTS
---------------
``functional-test`` was the long pole of the pipeline: one pytest process
per platform, ~50 minutes, and every other job waiting behind the same
3-cell ``strategy.matrix`` that the backend used. Sharding it across N
jobs per platform drops the wall clock to roughly the longest shard,
which is the only knob available — the suite cannot be made faster
internally (see the ``-n auto`` note in the workflow: the port picker
races the child process, so xdist trades a deterministic 15 minutes for
intermittent ``BindFailed`` at boot).

The sharding therefore happens at the *job* level, not the worker level,
and it has two properties worth stating because both are load-bearing:

1. **Every collected test runs exactly once across the whole shard set.**
   The selection is ``index % total == index_of_shard`` over one flat
   ordered list, so the union of all shards is the unsharded run and no
   test is ever duplicated. A "pick some files per shard" scheme has
   neither property: it drops tests when the file count is not a
   multiple of the shard count.

2. **It fails loudly, never silently narrow.** A shard index outside
   ``0 <= index < total``, or a non-integer value, raises rather than
   selecting nothing. An empty shard exits 0 and reports green, so a
   typo in a CI matrix would otherwise delete a third of the suite
   without a single red check.

The module is deliberately free of pytest imports so it can be unit
tested directly (see ``tests/functional/func_shard_test.py``) and so
that the workflow's env-var contract has exactly one implementation.
"""

from __future__ import annotations

import os
from typing import Sequence, TypeVar

TOTAL_ENV = "PABRIK_FUNC_SHARD_TOTAL"
INDEX_ENV = "PABRIK_FUNC_SHARD_INDEX"

T = TypeVar("T")


class ShardConfigError(ValueError):
    """The shard env-var pair is missing half of itself or is nonsense.

    A ``ValueError`` subclass so a caller that wants to degrade can catch
    one type; nothing in CI does, because degrading here means silently
    under-testing.
    """


def resolve_shard(
    env: "os._Environ[str] | dict[str, str] | None" = None,
) -> tuple[int, int] | None:
    """Return ``(index, total)`` from the environment, or ``None``.

    ``None`` means "not sharded" — a local ``pytest`` run, and the whole
    suite in one CI job when someone sets only one of the two variables to
    an empty string. Any *malformed* value raises instead: the difference
    between "I did not ask for shards" and "I asked for shards and got
    them wrong" is exactly the difference between running the suite and
    silently running a third of it.
    """
    source = os.environ if env is None else env
    raw_total = (source.get(TOTAL_ENV) or "").strip()
    raw_index = (source.get(INDEX_ENV) or "").strip()
    if not raw_total and not raw_index:
        return None
    if not raw_total or not raw_index:
        raise ShardConfigError(
            f"{TOTAL_ENV} and {INDEX_ENV} must be set together; "
            f"got {TOTAL_ENV}={raw_total!r} {INDEX_ENV}={raw_index!r}"
        )
    try:
        total = int(raw_total)
        index = int(raw_index)
    except ValueError as exc:  # pragma: no cover - message asserted in tests
        raise ShardConfigError(
            f"{TOTAL_ENV}/{INDEX_ENV} must be integers; "
            f"got {raw_total!r}/{raw_index!r}"
        ) from exc
    if total < 1:
        raise ShardConfigError(f"{TOTAL_ENV} must be >= 1; got {total}")
    if not 0 <= index < total:
        raise ShardConfigError(
            f"{INDEX_ENV}={index} is out of range for {TOTAL_ENV}={total}; "
            f"valid indices are 0..{total - 1}"
        )
    return index, total


def select(items: Sequence[T], index: int, total: int) -> list[T]:
    """The items belonging to shard ``index`` of ``total``.

    Modulo over the *item* list rather than over files: the two suites
    have wildly different per-file durations (a handful of Playwright
    files hold hundreds of tests), so splitting by file would hand one
    shard the entire UI suite and another nothing at all.
    """
    if total < 1:
        raise ShardConfigError(f"total must be >= 1; got {total}")
    if not 0 <= index < total:
        raise ShardConfigError(f"index {index} out of range for total {total}")
    return [item for i, item in enumerate(items) if i % total == index]
