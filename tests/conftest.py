"""Suite-agnostic pytest config for everything under ``tests/``.

Lives here rather than in ``tests/functional/conftest.py`` because
pytest loads a ``conftest.py`` from every directory between the rootdir
and the test file: a hook in ``tests/functional/`` never sees an item
collected from ``tests/functional_ui/``. The two web suites are run by
ONE ``zig build functional-test-all`` invocation, so a sharding hook has
to sit above both of them.

Its only job is the shard split, delegated to ``func_shard`` so the
env-var contract and the modulo rule have exactly one implementation and
can be unit tested without booting a pabrik (see
``tests/functional/func_shard_test.py``).

With neither ``PABRIK_FUNC_SHARD_TOTAL`` nor ``PABRIK_FUNC_SHARD_INDEX``
set — every local run, and the single-shard CI configuration — this file
is inert.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# `tests/` is already on sys.path through pytest.ini's `pythonpath`, but
# that ini option is applied as a plugin AFTER the initial conftests load,
# so the import below cannot rely on it. Prepending the directory here is
# idempotent (pytest's `prepend` import mode puts it there too) and makes
# the module import independent of ini ordering.
_TESTS_DIR = str(Path(__file__).resolve().parent)
if _TESTS_DIR not in sys.path:
    sys.path.insert(0, _TESTS_DIR)

from func_shard import (  # noqa: E402  (path set above)
    ShardConfigError,
    resolve_shard,
    select,
)


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Keep only this shard's items, in place.

    ``tryfirst=True`` so the split is computed over the FULL collected
    list, before the per-suite platform gates mark their skips. Ordering
    the two the other way round would still partition the list correctly
    — the gates mark items, they never remove them — but "index % N over
    the complete suite" is the invariant the unit test asserts, and it is
    easier to keep an invariant true when the hook that implements it runs
    first.

    Mutating ``items`` in place is the documented mechanism (there is no
    public "remove these" API; ``pytest_deselected`` is reported
    automatically off the diff).
    """
    try:
        shard = resolve_shard()
    except ShardConfigError as exc:
        # Re-raised as a usage error rather than allowed to propagate: an
        # exception out of a collection hook is an INTERNALERROR, which
        # prints a traceback and exits 3. `pytest.UsageError` prints the
        # message on its own line and exits 4. Both are red; only one of
        # them reads as a configuration mistake rather than a pytest bug.
        raise pytest.UsageError(f"functional shard config: {exc}") from exc
    if shard is None:
        return
    index, total = shard
    before = len(items)
    items[:] = select(items, index, total)
    print(
        f"\n[func-shard] shard {index + 1}/{total}: "
        f"{len(items)} of {before} collected tests"
    )
