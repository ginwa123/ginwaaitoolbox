"""Every seeded scenario renders on a real device, or the suite says why not.

One Gradle invocation covers all ten scenarios, so these tests are assertions
*about* that one run rather than ten separate runs. That shape is deliberate: a
`connectedDebugAndroidTest` invocation is a build, an install and a device
handshake, and ten of them would turn a three-minute suite into twenty.

Two guards here are worth more than the scenario assertions themselves, because
they are the ones that catch a suite which has quietly stopped testing:

  * `test_the_whole_suite_ran_and_nothing_was_skipped` — a skipped instrumented
    test is a missing gate, not a pass, and an assertion that only checks
    `failures == 0` reads identically whether ten tests ran or none did;
  * `test_no_test_from_another_class_ran` — the class filter is what keeps this
    suite's signal out of `ChatViewTest`'s 14 known-red tests. A typo in that
    filter would run the whole module, go red for unrelated reasons, and look
    like a real failure. Worse, in a *passing* world it would mean these
    assertions were checking somebody else's tests.
"""

from __future__ import annotations

import pytest

from android_gradle import TEST_CLASS
from scenarios import ROWS, SCENARIOS, expected_message_ids

SCENARIO_NAMES = list(SCENARIOS)


@pytest.mark.parametrize("scenario", SCENARIO_NAMES)
def test_each_seeded_scenario_rendered_on_the_device(instrumented_results, scenario: str) -> None:
    """The scenario's instrumented test exists, and passed.

    The name is not a coincidence: the Kotlin `@Test` method for a scenario is
    named after its key in `SCENARIOS`, and `drift_test.py` is what keeps the two
    lists honest. A name missing from the report is a FAILURE, never a skip —
    that is the whole point of asserting on the report rather than on Gradle's
    exit code, which is zero for a run that collected nothing.
    """
    result = instrumented_results

    assert scenario in result.names, (
        f"no instrumented test named {scenario!r} in the report.\n"
        f"  ran: {sorted(result.names)}\n"
        f"  this happens when the class filter did not match, or when the Kotlin "
        f"method was renamed without updating SCENARIOS. Expected class: {TEST_CLASS}"
    )

    assert scenario not in result.failed, (
        f"{scenario} rendered the wrong thing on the device:\n\n"
        f"{result.failed[scenario]}"
    )


def test_the_whole_suite_ran_and_nothing_was_skipped(instrumented_results) -> None:
    result = instrumented_results

    assert result.tests == len(SCENARIOS), (
        f"expected {len(SCENARIOS)} instrumented tests, the report has "
        f"{result.tests}. Counts: failures={result.failures} errors={result.errors} "
        f"skipped={result.skipped}"
    )
    assert result.failures == 0, f"failures: {sorted(result.failed)}"
    assert result.errors == 0, f"errors: {sorted(result.failed)}"
    assert result.skipped == 0, (
        "an instrumented test was skipped, which means a scenario asserted "
        "nothing. A skipped test is a missing gate, not a pass."
    )


def test_no_test_from_another_class_ran(instrumented_results) -> None:
    """The class filter did what it was supposed to.

    Anything outside this suite's own class means the filter was wrong, and the
    run is either red for `ChatViewTest`'s pre-existing reasons or green for
    somebody else's assertions.
    """
    foreign = sorted(instrumented_results.names - set(SCENARIOS))

    assert not foreign, (
        f"the report contains tests that are not this suite's: {foreign}\n"
        f"  expected exactly {sorted(SCENARIOS)}\n"
        f"  the class filter is {TEST_CLASS}"
    )


@pytest.mark.parametrize("scenario", SCENARIO_NAMES)
def test_the_rows_the_app_read_are_the_rows_we_seeded(
    android_harness, seeded: dict, scenario: str
) -> None:
    """The server the app was pointed at serves exactly the seeded rows.

    The suite's one assumption, checked per scenario rather than once: the port
    the APK was built against is the port this harness is on, and that harness
    returns each seeded session's rows in `id` order. The phone sorts by `id`,
    so "in id order" is what "in the right order on screen" means.

    Cheap and device-free, so when a scenario fails on the device this says
    whether the data or the renderer was wrong.
    """
    session_id = SCENARIOS[scenario]

    response = android_harness.http(
        "GET",
        f"/api/llm/session/{session_id}/messages",
        params={"limit": 1000, "sort_by": "id", "direction": "asc"},
    )
    assert response.status == 200, response.body[:400]

    got = [row["id"] for row in response.json()["messages"]]
    want = [i for i in expected_message_ids() if i.startswith(session_id)]

    assert len(want) == ROWS[scenario], (
        f"{scenario}: the convention produces {len(want)} ids for {ROWS[scenario]} rows"
    )
    assert got == want, (
        f"{scenario}: the harness served {got}, expected {want}.\n"
        "A missing row means the seed did not commit; a wrong order means the "
        "ids no longer sort the way they were seeded."
    )


def test_the_app_was_built_against_this_harness(seeded: dict, android_harness) -> None:
    """The base URL the APK was built with names this run's port.

    Guards the one wire between the two halves: a port typo would leave the app
    talking to nothing, and every scenario would fail as though the renderer
    were broken.
    """
    assert seeded["base_url"].endswith(f":{android_harness.port}"), (
        f"base url {seeded['base_url']} does not name the harness port "
        f"{android_harness.port}"
    )
