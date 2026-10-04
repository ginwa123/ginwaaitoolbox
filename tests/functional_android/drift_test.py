"""The Kotlin and Python scenario lists must agree.

The two sides spell the ids out rather than sharing them, which is what makes a
rename fail loudly instead of silently — but only if something actually compares
them. This file is that something.

It reads `FunctionalScenario.kt` as text rather than compiling it, the way
`ToolCardFrameTest` reads `ToolCards.kt`: a Kotlin test cannot see the Python,
a Python test cannot run the Kotlin, and the whole point is to catch the case
where one side was edited and the other was not.

Three properties, which fail for different reasons:

  1. the session ids are the same set, so neither side can add or rename a
     scenario alone;
  2. every message id the Kotlin names is produced by `message_id()` from a
     known session, so the Kotlin cannot invent an id nothing seeds;
  3. the ids sort in seeding order — the property the phone depends on, since
     its transcript is ordered by `id` and an id that sorts out of order renders
     the conversation backwards.
"""

from __future__ import annotations

import re
from pathlib import Path

from scenarios import ROWS, SCENARIOS, expected_message_ids, message_id

#: Where the Kotlin counterpart lives. Both paths are tried so the test works
#: whether pytest is invoked from the repository root or the worktree root.
_KOTLIN_CANDIDATES = (
    "src/apps/android_mobile/app/src/androidTest/java/com/pabrik/mobile/functional/FunctionalScenario.kt",
    "../src/apps/android_mobile/app/src/androidTest/java/com/pabrik/mobile/functional/FunctionalScenario.kt",
)

_SESSION_LITERAL = re.compile(r'"(sess_fn_[a-z]+)"')
_MESSAGE_LITERAL = re.compile(r'"(sess_fn_[a-z]+_\d{4})"')


def _kotlin_source() -> str:
    for candidate in _KOTLIN_CANDIDATES:
        path = Path(candidate)
        if path.is_file():
            return path.read_text()
    raise AssertionError(
        "FunctionalScenario.kt not reachable from "
        f"{Path('.').resolve()} — tried {_KOTLIN_CANDIDATES}"
    )


def test_both_sides_seed_the_same_sessions() -> None:
    declared = set(_SESSION_LITERAL.findall(_kotlin_source()))

    assert declared == set(SCENARIOS.values()), (
        "the Kotlin and Python scenario lists disagree.\n"
        f"  Kotlin only: {sorted(declared - set(SCENARIOS.values()))}\n"
        f"  Python only: {sorted(set(SCENARIOS.values()) - declared)}"
    )


def test_every_message_id_the_kotlin_names_is_one_python_seeds() -> None:
    # Scanned across the whole file, because every id is declared as a string
    # literal in some constant and `messageIds` only *refers* to them. That
    # makes this the complete set of ids the instrumented side can name.
    declared = set(_MESSAGE_LITERAL.findall(_kotlin_source()))

    expected = set(expected_message_ids())

    # A subset, not equality. The Kotlin declares only the ids it *asserts* on;
    # the seeders write every row, including the user turns and the plain
    # replies that only exist to make a transcript look like a conversation.
    # Demanding equality would force the Kotlin to name rows it never looks at.
    assert declared <= expected, (
        "the instrumented assertions name ids the seeders do not write, which "
        "would fail on a device as a missing tag:\n"
        f"  {sorted(declared - expected)}"
    )

    # And the subset must not be empty. A regex that silently stopped matching
    # would make the assertion above pass while checking nothing at all, which
    # is the failure mode a contract test is least able to notice about itself.
    assert len(declared) >= 10, (
        f"only {len(declared)} message ids found in FunctionalScenario.kt — the "
        "extraction has probably stopped matching: " + repr(sorted(declared))
    )


def test_message_ids_sort_in_the_order_they_are_seeded() -> None:
    # The phone renders by `id` ascending, so this is the transcript's order.
    for name, session_id in SCENARIOS.items():
        ids = [message_id(session_id, n) for n in range(1, ROWS[name] + 1)]
        assert ids == sorted(ids), (
            f"{name}: ids are not in seeding order: {ids}"
        )
        # And a scenario's ids must not interleave with another's.
        for other, other_session in SCENARIOS.items():
            if other == name:
                continue
            assert not any(
                id_.startswith(other_session) for id_ in ids
            ), f"{name} and {other} share an id prefix"
