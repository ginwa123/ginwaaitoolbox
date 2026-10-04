"""The one place this suite shells out to Gradle, and the XML it reads back.

Kept apart from the fixtures so the two things that are easy to get wrong live
somewhere small enough to read in one sitting:

  * the argument list, which has to build the APK against *this run's* port and
    filter to *this suite's* class — the module's instrumented suite is 14 tests
    red on `main` (`ChatViewTest`), so an unfiltered run buries the signal;
  * the result parse, which has to treat a *missing* testcase as a failure. A
    typo'd class filter produces a JUnit report with zero testcases and a green
    Gradle exit code, which is exactly the shape of a suite that has quietly
    stopped testing anything.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

#: `connectedDebugAndroidTest` writes one file per device here.
_RESULTS_DIR = Path("app/build/outputs/androidTest-results/connected/debug")

#: A build + install + device handshake, then ten scenarios on a cold app.
DEFAULT_TIMEOUT_S = 1200

#: The class this suite runs. Everything else in `androidTest` is excluded on
#: purpose — see the module docstring.
TEST_CLASS = "com.pabrik.mobile.functional.ChatFunctionalTest"


@dataclass(frozen=True)
class SuiteResult:
    """One JUnit suite's counts, plus every testcase that failed."""

    tests: int
    failures: int
    errors: int
    skipped: int
    #: testcase name -> failure text, for the cases that failed.
    failed: dict[str, str] = field(default_factory=dict)
    #: Every testcase name the report contains.
    names: frozenset[str] = frozenset()

    @property
    def clean(self) -> bool:
        return self.failures == 0 and self.errors == 0 and self.skipped == 0


def run_instrumented(
    *,
    base_url: str,
    project_dir: Path,
    env: dict[str, str],
    test_class: str = TEST_CLASS,
    timeout_s: int = DEFAULT_TIMEOUT_S,
) -> SuiteResult:
    """Build, install and run the suite; return the parsed report.

    `--offline` is deliberately absent: the UTP reporting artifact
    (`com.android.tools.utp:android-test-plugin-host-additional-test-output`) is
    not in the Gradle cache, so an offline run fails *after* the tests have
    passed — which reads as a build failure that is not one.

    Raises `AssertionError` when Gradle itself fails or produces no report, with
    the tail of its output attached. That is the difference between "the app did
    not render the row" and "the build did not happen", and they are worth
    telling apart.
    """
    gradle = project_dir / "gradlew"
    if not gradle.exists():
        raise AssertionError(f"no Gradle wrapper at {gradle}")

    results_dir = project_dir / _RESULTS_DIR
    _clear_old_reports(results_dir)

    argv = [
        str(gradle),
        ":app:connectedDebugAndroidTest",
        "--console=plain",
        f"-PpabrikBaseUrl={base_url}",
        f"-Pandroid.testInstrumentationRunnerArguments.class={test_class}",
    ]

    completed = subprocess.run(
        argv,
        cwd=str(project_dir),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout_s,
        check=False,
    )
    output = completed.stdout.decode("utf-8", errors="replace")

    reports = sorted(results_dir.glob("TEST-*.xml")) if results_dir.is_dir() else []
    if completed.returncode != 0 and not reports:
        raise AssertionError(
            "gradle failed before writing a report, so nothing was tested.\n"
            "--- last 4000 chars ---\n" + output[-4000:]
        )

    result = parse_suite(reports[-1]) if reports else SuiteResult(0, 0, 0, 0)

    # A non-zero exit with a clean report means Gradle failed on something other
    # than an assertion (a flaky install, a device that went away). Reporting it
    # as a suite failure would blame the app for the harness's problem.
    assert completed.returncode == 0 or not result.clean, (
        "gradle exited non-zero but the report is clean, which means the failure "
        "was not a test failure (install, device, or reporting):\n" + output[-2000:]
    )

    return result


def parse_suite(xml_path: Path) -> SuiteResult:
    """Read one JUnit XML file into counts and failures.

    Attribute names come from AGP's own writer: `<testsuite tests= failures=
    errors= skipped=>` with one `<testcase name=>` per test and a `<failure>`
    child on the ones that failed.
    """
    root = ET.parse(xml_path).getroot()

    failed: dict[str, str] = {}
    names: set[str] = set()
    for case in root.iter("testcase"):
        name = case.get("name") or ""
        names.add(name)
        for bad in list(case.iter("failure")) + list(case.iter("error")):
            failed[name] = (bad.get("message") or "") + "\n" + (bad.text or "")

    return SuiteResult(
        tests=int(root.get("tests") or 0),
        failures=int(root.get("failures") or 0),
        errors=int(root.get("errors") or 0),
        skipped=int(root.get("skipped") or 0),
        failed=failed,
        names=frozenset(names),
    )


def _clear_old_reports(results_dir: Path) -> None:
    """Drop the previous run's XML.

    Without this, a run that produced no report at all would silently be read as
    the *previous* run's result — the most flattering possible failure mode.
    """
    if results_dir.is_dir():
        shutil.rmtree(results_dir, ignore_errors=True)


def resolve_gradle_env(repo_root: Path) -> dict[str, str]:
    """The environment `connectedDebugAndroidTest` needs, or a reason it cannot.

    Returns a dict that either contains `JAVA_HOME`/`ANDROID_HOME` or raises with
    a message naming what is missing. The JDK pin is load-bearing: AGP 8.7.3
    rejects a newer JDK and aborts with a bare version number and no stack trace.
    """
    env = dict(os.environ)

    java_home = env.get("JAVA_HOME") or _first_dir(
        Path("/tmp/jdk17"), Path.home() / ".local" / "jdk17"
    )
    if not java_home:
        raise AssertionError(
            "no JDK 17 found. AGP 8.7.3 aborts on a newer JDK with a bare '27' and "
            "no stack trace, so this suite needs one: set JAVA_HOME, or install "
            "Temurin 17 at /tmp/jdk17 or ~/.local/jdk17."
        )
    env["JAVA_HOME"] = str(java_home)

    android_home = env.get("ANDROID_HOME") or _first_dir(Path.home() / "Android" / "Sdk")
    if not android_home:
        raise AssertionError(
            "no Android SDK found. Set ANDROID_HOME, or install an SDK containing "
            "platform 35 (compileSdk) and build-tools."
        )
    env["ANDROID_HOME"] = str(android_home)
    env["ANDROID_SDK_ROOT"] = str(android_home)

    # `local.properties` is gitignored, so a fresh worktree has none and AGP
    # cannot locate the SDK from the file. Written only when absent, and it is
    # gitignored so this cannot dirty the tree.
    local_properties = repo_root / "src" / "apps" / "android_mobile" / "local.properties"
    if not local_properties.exists():
        local_properties.write_text(f"sdk.dir={android_home}\n")

    return env


def _first_dir(*candidates: Path) -> Path | None:
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return None
