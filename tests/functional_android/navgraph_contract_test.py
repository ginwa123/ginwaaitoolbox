"""The navigation-graph extractor must keep agreeing with `PabrikNavGraph.kt`.

`tools/navgraph/` reads the Android client's `NavHost` as text and draws a
committed HTML audit page from it. Nothing about that is enforced by the Kotlin
compiler: a route added, renamed or removed silently changes what the page
claims, and the page is what a reviewer reads. These tests are the seam.

They live here rather than in a Kotlin test suite because the thing under test
is *Python reading Kotlin*, and a JVM test cannot see the Python. They need no
emulator, no Gradle and no running backend — which is the same reason the
extractor itself does not invoke Gradle (see `tools/navgraph/navgraph.py`).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
_TOOL_DIR = _REPO_ROOT / "src" / "apps" / "android_mobile" / "tools" / "navgraph"

if str(_TOOL_DIR) not in sys.path:
    sys.path.insert(0, str(_TOOL_DIR))

import build as navbuild  # noqa: E402
import navgraph  # noqa: E402


@pytest.fixture(scope="module")
def graph() -> object:
    """One extraction shared by every test that reads the real Kotlin."""
    return navgraph.extract_graph(_REPO_ROOT)


# --------------------------------------------------------------------------
# The masking contract everything else depends on
# --------------------------------------------------------------------------


def test_mask_preserves_offsets_and_line_count() -> None:
    """A masked file must be the same length, so every offset still resolves."""
    source = 'val a = "x" // note\n/* block\n more */\nval b = 2\n'
    masked = navgraph.mask_kotlin(source)

    assert len(masked) == len(source)
    assert masked.count("\n") == source.count("\n")


def test_mask_blanks_bodies_but_keeps_delimiters() -> None:
    masked = navgraph.mask_kotlin('val route = "chat/{id}" // "composable(" is not a call\n')

    assert 'composable(' not in masked
    assert masked.count('"') == 2  # the delimiters survive so the value can be read back


def test_mask_handles_nested_block_comments() -> None:
    """Kotlin block comments nest; a regex that did not would swallow the file."""
    masked = navgraph.mask_kotlin('/* outer /* inner */ still comment */ val real = 1\n')

    assert "comment" not in masked
    assert "val real = 1" in masked


def test_mask_does_not_treat_escaped_quote_as_a_string_end() -> None:
    """`"a\\"b"` is one string; a `\"` must not close it early.

    Without the escape handling the masker resumes scanning inside what is
    still a literal, and a `composable(` sitting in a string or a KDoc would
    become a real destination.
    """
    masked = navgraph.mask_kotlin('val s = "a\\" composable( still a string"\nval t = 1\n')

    assert "composable(" not in masked
    assert "val t = 1" in masked, "masking ran past the end of the string"


def test_normalise_template_collapses_both_interpolation_spellings() -> None:
    """`$name` and `${receiver.encode(name)}` must land on the same template."""
    assert (
        navgraph.normalise_template("chat/${UriEncoding.encode(sessionId)}")
        == navgraph.normalise_template("chat/$sessionId")
        == "chat/{sessionId}"
    )


# --------------------------------------------------------------------------
# The real graph
# --------------------------------------------------------------------------


def test_start_destination_is_the_shell(graph) -> None:
    assert graph.start_destination == "app"


def test_every_destination_declares_at_least_one_screen(graph) -> None:
    """A destination with no composable is a parsing failure, not an empty screen.

    The root screens are `UpperCamelCase` calls at the top nesting level of the
    `composable` body; anything else (`getString(`, `navigate(`, a named argument)
    leaking in means the depth counter has drifted.
    """
    assert graph.destinations, "no destinations extracted at all"
    for destination in graph.destinations:
        assert destination.screens, f"{destination.template} rendered nothing"
        for screen in destination.screens:
            assert screen[0].isupper(), f"{screen!r} is not a type name"


def test_deep_links_and_manifest_hosts_are_both_read(graph) -> None:
    declared = {host for host in graph.manifest_hosts}
    linked = set()
    for destination in graph.destinations:
        for pattern in destination.deep_links:
            match = re.match(r"pabrik://([^/]+)", pattern)
            assert match, f"unrecognised deep link {pattern!r}"
            linked.add(match.group(1))

    assert linked, "no deep links extracted"
    assert declared, "manifest hosts not read"
    # Every host the manifest claims must have a route behind it, or the intent
    # filter outlived the screen it was added for.
    assert declared <= linked, f"manifest hosts with no route: {sorted(declared - linked)}"


def test_every_navigation_resolves_to_a_known_destination(graph) -> None:
    """`navigate(PabrikRoutes.x(...))` must map onto a real `composable` route.

    An unresolved target is a route constant the builder table does not know, and
    it means the diagram is quietly missing an edge.
    """
    known = set(graph.templates()) | {"__back__", "__deeplink__", "graph"}
    unresolved = [
        edge.via for edge in graph.edges if edge.target and edge.target not in known
    ]
    assert not unresolved, f"navigation targets no destination: {unresolved}"


def test_the_graph_is_reachable_from_the_launch(graph) -> None:
    """Every destination must be reachable from the shell or from outside it.

    An unreachable destination is a screen the user cannot get to, which is
    exactly the class of defect the audit page exists to surface — so the
    extractor reporting one is a bug in the extractor, not a finding. A deep
    link counts as an entry point, because the link enters the app from the
    launcher rather than from the shell.
    """
    adjacency: dict[str, set[str]] = {t: set() for t in graph.templates()}
    entered_from_outside: set[str] = set()

    for edge in graph.edges:
        if edge.kind not in ("push", "replace", "deep-link"):
            continue
        if edge.kind == "deep-link":
            entered_from_outside.add(edge.target)
            continue
        if edge.source != "graph":
            adjacency[edge.source].add(edge.target)

    seen = {graph.start_destination} | entered_from_outside
    frontier = [graph.start_destination, *entered_from_outside]
    while frontier:
        node = frontier.pop()
        for nxt in adjacency.get(node, ()):
            if nxt not in seen:
                seen.add(nxt)
                frontier.append(nxt)

    unreachable = set(adjacency) - seen
    assert not unreachable, f"unreachable from the launch: {sorted(unreachable)}"


# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------


def test_layout_places_every_destination_without_overlap(graph) -> None:
    positions = navgraph.layout(graph)

    assert set(positions) == set(graph.templates())

    boxes = [
        (name, box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"])
        for name, box in positions.items()
    ]
    for i, (name, ax0, ay0, ax1, ay1) in enumerate(boxes):
        for other, bx0, by0, bx1, by1 in boxes[i + 1 :]:
            overlap = ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1
            assert not overlap, f"{name} overlaps {other}"


def test_layout_ranks_by_depth_so_the_shell_is_first(graph) -> None:
    """Row order must follow taps-from-launch, not declaration order.

    The graph has cycles (a chat reaches the chats list, the list reaches a
    chat), so a longest-path layering never settles — it pushed the chat row to
    2048 before this became breadth-first.
    """
    positions = navgraph.layout(graph)
    shell_y = positions[graph.start_destination]["y"]
    ranks = sorted({box["y"] for box in positions.values()})

    assert shell_y == ranks[0], "the launch destination is not on the first row"
    assert len(ranks) <= len(positions)
    assert max(ranks) - min(ranks) < 10_000, "ranks diverged — a cycle is being followed"


# --------------------------------------------------------------------------
# The audit checks themselves
# --------------------------------------------------------------------------


def test_audit_flags_a_deep_link_the_manifest_does_not_claim() -> None:
    """The detector must fire on a *synthetic* graph, independent of the real one.

    Asserting it against the live source would only prove today's manifest is
    whatever it is; building a graph that is wrong on purpose proves the check
    still recognises wrong.
    """
    broken = navgraph.NavGraph(
        destinations=[
            navgraph.Destination(
                route="CHAT",
                template="chat/{id}",
                arguments=("ARG_ID",),
                deep_links=("pabrik://chat/{id}",),
                screens=("ChatScreen",),
                composables=("ChatScreen",),
                back_affordances=("onBack = goBack",),
                line=1,
            )
        ],
        edges=[
            navgraph.Edge(
                source="chat/{id}",
                target="__back__",
                kind="back",
                via="goBackToPreviousOrShell",
                trigger="onBack = goBack",
            )
        ],
        route_constants=[
            navgraph.RouteConstant("CHAT", "chat/{id}", "chat/{id}", 1, "route"),
            navgraph.RouteConstant("ARG_ID", "id", "id", 2, "argument"),
        ],
        start_destination="chat/{id}",
        manifest_hosts={"network": 40},  # claims `network`, not `chat`
        manifest_file="AndroidManifest.xml",
        nav_file="PabrikNavGraph.kt",
        git_sha="test",
        generated_by="test",
    )

    findings = navgraph.audit(broken)
    deep_link = [f for f in findings if f.code == "deep_link_not_in_manifest"]

    assert len(deep_link) == 1
    assert deep_link[0].subject == "chat/{id}"
    assert "chat" in deep_link[0].detail


def test_audit_reports_no_stale_manifest_host_on_the_real_graph(graph) -> None:
    """No host may be claimed without a route behind it."""
    stale = [f for f in navgraph.audit(graph) if f.code == "manifest_host_without_route"]

    assert not stale, f"manifest claims hosts with no route: {[f.title for f in stale]}"


def test_audit_has_no_raw_back_call_in_the_real_graph(graph) -> None:
    """Every back affordance must go through `goBackToPreviousOrShell`.

    A bare `popBackStack()` is inclusive and empties a one-deep back stack, which
    leaves `NavHost` rendering nothing. The README states the rule; this asserts
    the app still follows it.
    """
    raw = [f for f in navgraph.audit(graph) if f.code == "raw_back_call"]

    assert not raw, f"raw back call(s): {[f.title for f in raw]}"


def test_audit_acknowledges_the_unreachable_deep_links(graph) -> None:
    """Record what the audit currently reports about the manifest.

    `pabrik://chats/…` and `pabrik://project/…` are declared as `navDeepLink`
    patterns with no matching `<intent-filter>` in `AndroidManifest.xml`, so
    `adb shell am start -d pabrik://chats/…` resolves to no activity and nothing
    in the app reports it.

    This test pins the *known* gap so it cannot be forgotten. When the manifest
    gains those two filters, delete them from this set — the assertions below
    then hold with an empty `unclaimed`, and the audit page goes clean.
    """
    known_unclaimed = {"chats", "project"}
    host_of = {
        destination.template: re.match(r"pabrik://([^/]+)", pattern).group(1)
        for destination in graph.destinations
        for pattern in destination.deep_links
    }

    unclaimed = {
        host_of[f.subject]
        for f in navgraph.audit(graph)
        if f.code == "deep_link_not_in_manifest"
    }

    claimed = {
        match.group(1)
        for destination in graph.destinations
        for pattern in destination.deep_links
        if (match := re.match(r"pabrik://([^/]+)", pattern))
    }

    assert unclaimed <= known_unclaimed, (
        "a deep link lost its manifest intent filter, or a new one was added "
        f"without one: {sorted(unclaimed)}"
    )
    assert known_unclaimed - claimed == set(), (
        "a host in KNOWN_UNCLAIMED no longer has a route — remove it from the set"
    )


# --------------------------------------------------------------------------
# The committed artifact
# --------------------------------------------------------------------------


def test_committed_navgraph_json_matches_the_source() -> None:
    """`--check` by another name, so CI fails on a stale audit page.

    A committed page that nobody regenerates is worse than no page: it is
    confidently wrong. Comparing the JSON rather than the HTML keeps the
    failure message about the data, not about template whitespace.

    `meta.gitSha` is dropped on both sides. Committing a regenerated artifact
    moves HEAD, so an unmasked comparison would make every artifact stale the
    instant it was committed — which is a check that can never pass, and is
    therefore a check nobody would believe.
    """
    committed = _REPO_ROOT / "src" / "apps" / "android_mobile" / "navgraph.json"

    assert committed.is_file(), "navgraph.json missing — run tools/navgraph/build.py"

    fresh = navgraph.extract_graph(_REPO_ROOT, generated_by="tools/navgraph/build.py")
    expected = json.loads(navgraph.dumps(navgraph.render_payload(fresh)))

    on_disk = json.loads(committed.read_text(encoding="utf-8"))
    on_disk["meta"].pop("gitSha", None)
    expected["meta"].pop("gitSha", None)

    assert on_disk == expected, (
        "navgraph.json is stale — run "
        "`python3 src/apps/android_mobile/tools/navgraph/build.py` and commit the result"
    )


def test_committed_navgraph_html_is_current() -> None:
    """The HTML must be the current render of the current template."""
    committed = _REPO_ROOT / "src" / "apps" / "android_mobile" / "navgraph.html"

    assert committed.is_file(), "navgraph.html missing — run tools/navgraph/build.py"

    payload = navgraph.render_payload(
        navgraph.extract_graph(_REPO_ROOT, generated_by="tools/navgraph/build.py")
    )
    expected = navbuild.render_html(payload, "Pabrik Android — navigation graph", None)

    assert navbuild.strip_sha(committed.read_text(encoding="utf-8")) == navbuild.strip_sha(
        expected
    ), "navgraph.html is stale — run tools/navgraph/build.py and commit the result"


def test_generated_html_makes_no_network_requests() -> None:
    """The audit page must open from a bare filesystem with nothing else.

    A `<script src>` or a webfont would make the page silently fail on a
    machine with no network — which is most machines where you would want to
    read a nav diagram.
    """
    html = (_REPO_ROOT / "src" / "apps" / "android_mobile" / "navgraph.html").read_text(
        encoding="utf-8"
    )

    for pattern in (r'<script[^>]+\bsrc\s*=', r'<link[^>]+\bhref\s*=', r"@import", r"\bfetch\s*\(", r"XMLHttpRequest"):
        assert not re.search(pattern, html, re.IGNORECASE), f"{pattern} loads something remote"


def test_template_placeholders_are_all_substituted() -> None:
    """An unsubstituted placeholder means the template and build.py disagree."""
    html = (_REPO_ROOT / "src" / "apps" / "android_mobile" / "navgraph.html").read_text(
        encoding="utf-8"
    )

    assert "__NAVGRAPH_" not in html