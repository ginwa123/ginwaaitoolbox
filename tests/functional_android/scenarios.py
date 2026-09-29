"""The python mirror of the Kotlin `FunctionalScenario`.

Both sides spell the ids out rather than sharing them, because a contract that
cannot drift cannot fail. `drift_test.py` compares the two files, so a rename on
either side is a red test rather than a scenario whose assertions quietly stop
naming anything.

`message_id` is the single rule that turns a session id into the nth message id.
It exists as a function rather than as a literal list so both sides can agree
without a third artefact, and `drift_test.py` asserts the property the phone
depends on: the ids sort in the order they were seeded, because the transcript
is ordered by `id`.
"""

from __future__ import annotations

#: Scenario name -> the session row it seeds. Keys match the `@Test` names on
#: the instrumented side one-for-one.
SCENARIOS: dict[str, str] = {
    "empty": "sess_fn_empty",
    "exchange": "sess_fn_exchange",
    "multiturn": "sess_fn_multiturn",
    "toolcalls": "sess_fn_toolcalls",
    "toolresult": "sess_fn_toolresult",
    "markdown": "sess_fn_markdown",
    "images": "sess_fn_images",
    "reasoning": "sess_fn_reasoning",
    "html": "sess_fn_html",
    "presentfiles": "sess_fn_presentfiles",
}

#: How many `llm_history` rows each scenario writes, so `drift_test.py` can
#: rebuild the id list without running the seeders.
ROWS: dict[str, int] = {
    "empty": 0,
    "exchange": 2,
    "multiturn": 8,
    "toolcalls": 2,
    "toolresult": 3,
    "markdown": 2,
    "images": 2,
    "reasoning": 2,
    "html": 2,
    "presentfiles": 3,
}

def message_id(session_id: str, ordinal: int) -> str:
    """The id of the ``ordinal``-th message in ``session_id`` (1-based).

    Zero-padded to four digits so that string order is numeric order. The phone
    asks for ``sort_by=id&direction=asc``, so an unpadded scheme would render the
    tenth turn of a scenario before the second.
    """
    if not 1 <= ordinal <= 9999:
        raise ValueError(f"ordinal out of range: {ordinal}")
    return f"{session_id}_{ordinal:04d}"


def expected_message_ids() -> list[str]:
    """Every id the seeders will write, in seeding order.

    Derived from [SCENARIOS] + [ROWS] + [message_id], which is the same rule
    `seed_scenarios.py` uses — so this is a statement of the convention rather
    than a second copy of the data.
    """
    ids: list[str] = []
    for name, session_id in SCENARIOS.items():
        ids.extend(message_id(session_id, n) for n in range(1, ROWS[name] + 1))
    return ids
