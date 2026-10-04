"""Functional UI tests for the native Android client.

This is the phone's counterpart to ``tests/functional_ui/``. Both suites boot a
real ``pabrik`` binary against an isolated tmpdir ``HOME`` and put real rows in
that instance's own ``agent.db``; what differs is the client under test.

``tests/functional_ui/`` drives the web app with Playwright. This suite drives a
real Android emulator: the instrumented class in
``src/apps/android_mobile/app/src/androidTest/java/com/pabrik/mobile/functional/``
is installed and launched by Gradle, opens a seeded session over the app's own
HTTP client, and asserts on the rendered Compose tree.

Two consequences of that difference, both deliberate:

  * No Vite, no pnpm, no Playwright. The harness's whole node half is
    irrelevant here, so this suite's requirements are pytest and nothing else.
  * A device is required. The suite skips with a named reason when none is
    attached rather than failing, and the README says so plainly — an
    emulator-only suite that reports red on a laptop is a suite people learn to
    ignore.

Isolation is inherited whole from ``tests/functional/harness.py``: ``HOME`` is
shadowed to a ``pabrik-func-*`` tmpdir before the binary starts, every delete
goes through ``is_safe_tmp`` (the single source of truth), and teardown
rmtree's only ``harness.temp_dir`` — never the developer's real home.
"""

