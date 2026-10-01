"""Derive the Android app's navigation graph from its Kotlin source.

The point of this module is that **nothing here is hand-maintained**. Every
destination, route, deep link, argument and navigation edge is read out of
`NalarNavGraph.kt` and `AndroidManifest.xml`, so the audit cannot drift away
from the app the way a hand-written diagram does. A destination added to the
`NavHost` shows up in the rendered graph whether or not anyone remembers to
update a spec, and a route constant deleted from `NalarRoutes` disappears on
the next run.

### Why the source is *read as text* rather than compiled

The extractor never invokes Gradle or the Kotlin compiler. That is a
deliberate trade, taken for the same reason `tests/functional_android/
drift_test.py` reads `FunctionalScenario.kt` as text: a static graph is a
static artifact, and making it depend on a working JDK + Gradle + Android SDK
would mean the audit stops working on the machines — CI containers, review
laptops — where someone actually wants to look at it. The price is that the
parser has to be careful, which is why everything below runs against a
*masked* copy of the source (see `mask_kotlin`) rather than the raw bytes.

### The masking contract

`mask_kotlin` replaces the body of every comment and every string literal with
spaces, preserving both length and newline positions. Two properties follow,
and every other function here depends on them:

* **Offsets are preserved**, so a match on the masked text can be sliced out of
  the *original* text to recover the literal value, and its offset converts to
  a line number by counting newlines.
* **Structural text is all that is left**, so the brace/paren matching below
  cannot be fooled by a `}` inside a KDoc comment or a `chat/{sessionId}`
  string, and a regex for `composable(` cannot match a word that only appears
  inside a comment saying "there is no `composable(` here".

String *bodies* are blanked but their delimiters are kept, because the parser
wants to know a string was there when it re-reads the raw bytes — including
Kotlin's triple-quoted raw string, whose body has no escapes at all.

### What "derived" still cannot decide

Two things are a property of the *run*, not of the source, and are reported as
such rather than guessed: which back edge actually fires (it depends on what
is under the current destination), and whether a navigation happens at all.
Every finding below is therefore a statement about a *shape* — reachable,
deep-linkable, push-without-pop, declared-but-uncomposed — never a statement
about a behaviour the source alone cannot settle.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------

#: The Gradle project the graph describes.
ANDROID_PROJECT = Path("src") / "apps" / "android_mobile"

#: Where every navigation decision is made: the routes, the `NavHost`, every
#: `navigate()` call site, and the one back helper they all go through.
NAV_GRAPH_SOURCE = (
    ANDROID_PROJECT / "app" / "src" / "main" / "java" / "com" / "nalar" / "mobile"
    / "network" / "NalarNavGraph.kt"
)

#: Deep links are declared twice — once in the nav graph and once as an intent
#: filter — and the two can drift apart silently. This is the file that says
#: which of the two is load-bearing.
MANIFEST_SOURCE = ANDROID_PROJECT / "app" / "src" / "main" / "AndroidManifest.xml"


# --------------------------------------------------------------------------------------
# Source masking
# --------------------------------------------------------------------------------------


def mask_kotlin(source: str) -> str:
    """Blank out comments and string bodies, preserving every offset.

    Kotlin nests block comments, and an unterminated `/*` is a compile error
    rather than something to recover from — but a *masking* pass that mishandled
    one would silently swallow the rest of the file, so the nesting is tracked
    properly rather than regexed away.

    Returns a string of exactly `len(source)` characters.
    """
    out = list(source)
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]

        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                out[i] = " "
                i += 1
            continue

        if ch == "/" and i + 1 < n and source[i + 1] == "*":
            depth = 0
            while i < n:
                if source.startswith("/*", i):
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if source.startswith("*/", i):
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    if depth == 0:
                        break
                    continue
                if source[i] != "\n":
                    out[i] = " "
                i += 1
            continue

        if ch == '"':
            triple = '"' * 3
            if source.startswith(triple, i):
                out[i] = out[i + 1] = out[i + 2] = '"'
                i += 3
                while i < n and not source.startswith(triple, i):
                    if source[i] != "\n":
                        out[i] = " "
                    i += 1
                if i < n:
                    out[i] = out[i + 1] = out[i + 2] = '"'
                    i += 3
                continue
            out[i] = '"'
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\" and i + 1 < n:
                    out[i] = " "
                    if source[i + 1] != "\n":
                        out[i + 1] = " "
                    i += 2
                    continue
                if source[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = '"'
                i += 1
            continue

        i += 1

    return "".join(out)


def line_of(source: str, offset: int) -> int:
    """1-based line number of `offset` within `source`."""
    return source.count("\n", 0, offset) + 1


def _match_bracket(masked: str, start: int, open_ch: str, close_ch: str) -> int:
    """Index of the bracket closing the one at `start`, or -1.

    A missing close returns -1 rather than raising: a truncated file should
    still produce a graph with one obviously-broken node in it, which is what
    an audit wants to show.
    """
    depth = 0
    for i in range(start, len(masked)):
        if masked[i] == open_ch:
            depth += 1
        elif masked[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return -1


def _string_literal_at(source: str, offset: int) -> str | None:
    """Read the string literal whose opening quote is at `offset`."""
    triple = '"' * 3
    if source[offset : offset + 3] == triple:
        end = source.find(triple, offset + 3)
        return None if end < 0 else source[offset + 3 : end]
    if source[offset] != '"':
        return None
    escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "$": "$"}
    i = offset + 1
    buf: list[str] = []
    while i < len(source) and source[i] != '"':
        if source[i] == "\\" and i + 1 < len(source):
            buf.append(escapes.get(source[i + 1], source[i + 1]))
            i += 2
            continue
        buf.append(source[i])
        i += 1
    return "".join(buf)


def _first_quote_from(masked: str, offset: int, limit: int = 400) -> int:
    """Index of the next `"` in `[offset, offset + limit]`, or -1."""
    found = masked.find('"', offset, offset + limit)
    return found


# --------------------------------------------------------------------------------------
# Route templates
# --------------------------------------------------------------------------------------

#: `chat/${UriEncoding.encode(sessionId)}` and `network/record/$recordId` both
#: collapse to one `{name}` form. Both spellings appear in `NalarRoutes` — one
#: builder per route — and both have to land on the same template as the
#: `const val` they produce, which is what lets the extractor match
#: `navigate(NalarRoutes.chat(id))` to the `chat/{sessionId}` destination with
#: no hand-written alias table that could itself go stale.
_TEMPLATE_INTERPOLATION = re.compile(r"\$\{([^}]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def normalise_template(text: str) -> str:
    """Collapse both Kotlin interpolation spellings to one `{name}` form."""

    def replace(match: re.Match[str]) -> str:
        expr = match.group(1) or match.group(2)
        # Splitting `UriEncoding.encode(sessionId)` on the separators leaves a
        # trailing empty part for the closing paren, so the last *named* segment
        # is the one that names the argument.
        parts = [p for p in re.split(r"[.()\[\]]", expr) if p]
        return "{%s}" % (parts[-1].strip() if parts else "")

    return _TEMPLATE_INTERPOLATION.sub(replace, text)


# --------------------------------------------------------------------------------------
# Patterns
# --------------------------------------------------------------------------------------

_CONST_VAL = re.compile(r"const\s+val\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*String\s*)?=\s*")
_ROUTE_FUN = re.compile(r"fun\s+([a-z][A-Za-z0-9_]*)\s*\([^)]*\)\s*:\s*String\s*=\s*")
_ROUTES_OBJECT = re.compile(r"object\s+NalarRoutes\s*\{")

_COMPOSABLE = re.compile(r"(?<![\w.])composable\s*\(")
_NAVIGATE = re.compile(r"(?<![\w])navigate\s*\(")
_NAV_ARGUMENT = re.compile(r"navArgument\s*\(\s*NalarRoutes\.([A-Za-z_][A-Za-z0-9_]*)")
_NAV_DEEP_LINK = re.compile(r"navDeepLink\s*\{\s*uriPattern\s*=\s*")
_POP_UP_TO = re.compile(r"popUpTo\s*\(\s*NalarRoutes\.([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\{([^}]*)\}")
_LAUNCH_SINGLE_TOP = re.compile(r"launchSingleTop\s*=\s*true")
_BACK_HANDLER = re.compile(r"(?<![\w.])BackHandler\s*[\({]")
_RAW_POP = re.compile(r"(?<![\w.])(popBackStack|navigateUp)\s*\(")
_NAV_HOST = re.compile(r"NavHost\s*\(")
_NAV_HOST_START_DEST = re.compile(r"startDestination\s*=\s*NalarRoutes\.([A-Za-z_][A-Za-z0-9_]*)")

_VAL_DECL = re.compile(
    r"(?m)^[ \t]*(?:private\s+|internal\s+|public\s+)?val\s+([A-Za-z_][A-Za-z0-9_]*)"
)
#: Group 2 captures the `(` itself so bracket matching starts in the right
#: place — the key that follows it is not a position.
_EFFECT = re.compile(r"(?<![\w.])(LaunchedEffect|DisposableEffect)(\s*\()")
#: An extension function reads `fun NavHostController.goBackToPreviousOrShell()`,
#: so the receiver has to be part of the pattern — without it the one function
#: the whole back rule turns on reads as an ordinary body.
_TOP_LEVEL_FUN = re.compile(
    r"(?m)^(?:@[A-Za-z_][A-Za-z0-9_.]*\s*\n\s*)*"
    r"(?:private\s+|internal\s+|public\s+)?fun\s+"
    r"(?:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\("
)
_TARGET_EXPR = re.compile(
    r"\s*(NalarRoutes\.[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^)]*\))?)"
)
_SCREEN_CALL = re.compile(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\s*\(")
_ON_BACK = re.compile(r"\bonBack\s*=\s*(goBack\b|\{\s*goBack\(\))")

#: The back helper every back affordance is routed through. Named rather than
#: pattern-matched, because it is the *exception* the rule makes and a broad
#: "looks like a back call" match would swallow the rule.
BACK_HELPER = "goBackToPreviousOrShell"

#: Capitalised call names that are framework plumbing rather than screens.
#: Whatever survives this subtraction is a composable the destination renders,
#: which is the thing the audit actually reports.
_NON_SCREENS = frozenset(
    """
    BackHandler Column Row Box Spacer LazyColumn LazyRow LazyVerticalGrid Text Button
    IconButton Icon Image TextField OutlinedTextField Checkbox Switch RadioButton
    AlertDialog Dialog Card Scaffold Surface TopAppBar BottomAppBar ModalDrawer
    ModalNavigationDrawer DockedSearchBar HorizontalDivider VerticalDivider
    LaunchedEffect DisposableEffect remember rememberSaveable rememberCoroutineScope
    NavHost composable navDeepLink navArgument createTask projectActions
    NavigationLostScreen LaunchGateScreen CreateTaskHost NewChatProjectSheet
    """.split()
)


# --------------------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class RouteConstant:
    """One `const val` — or one builder `fun` — in `object NalarRoutes`."""

    name: str
    value: str
    template: str
    line: int
    kind: str  # "route" | "argument"
    synthetic: bool = False  # True for a builder function, not a real const


@dataclass(frozen=True)
class Site:
    """A place in the source worth clicking through to."""

    file: str
    line: int
    note: str = ""


@dataclass(frozen=True)
class Edge:
    """One navigation, from wherever it can be triggered to a destination."""

    source: str  # a destination template, or the `graph` rail
    target: str  # a destination template, `""` when unresolved, `__back__` for back
    kind: str  # "push" | "replace" | "deep-link" | "back"
    via: str  # the expression naming the target
    trigger: str  # the user action behind the call, from the enclosing scope
    pop_up_to: str | None = None
    pop_inclusive: bool | None = None
    launch_single_top: bool = False
    hoisted_from: str | None = None  # lambda / effect the navigate lives in
    resolved: bool = True  # False when the target could not be mapped
    sites: tuple[Site, ...] = ()

    @property
    def label(self) -> str:
        return "%s → %s" % (self.source, self.target or "?")


@dataclass(frozen=True)
class Destination:
    """One `composable(...)` block inside the `NavHost`."""

    route: str  # route-constant name, e.g. "CHAT"
    template: str  # the pattern it matches, e.g. "chat/{sessionId}"
    arguments: tuple[str, ...]  # declared `navArgument` constants
    deep_links: tuple[str, ...]  # `nalar://…` patterns
    screens: tuple[str, ...]  # the composables this destination *is*
    composables: tuple[str, ...]  # everything the body references
    back_affordances: tuple[str, ...]  # how a back leaves this destination
    line: int

    @property
    def placeholders(self) -> tuple[str, ...]:
        return tuple(re.findall(r"\{([^}]+)\}", self.template))


@dataclass
class NavGraph:
    """The whole extracted graph, plus the manifest facts that qualify it."""

    destinations: list[Destination]
    edges: list[Edge]
    route_constants: list[RouteConstant]
    start_destination: str
    manifest_hosts: dict[str, int]
    manifest_file: str
    nav_file: str
    git_sha: str
    generated_by: str
    #: `popBackStack()` / `navigateUp()` call sites outside `BACK_HELPER`, as
    #: `(enclosing destination or "", Site)`. Collected while reading the
    #: source, so the audit works off the same read the graph was built from.
    raw_back_calls: list[tuple[str, Site]] = field(default_factory=list)

    def templates(self) -> list[str]:
        return [d.template for d in self.destinations]

    def to_json(self) -> dict:
        return {
            "meta": {
                "generatedBy": self.generated_by,
                "gitSha": self.git_sha,
                "navFile": self.nav_file,
                "manifestFile": self.manifest_file,
                "startDestination": self.start_destination,
                "manifestHosts": self.manifest_hosts,
            },
            "rawBackCalls": [
                {"destination": d, "file": s.file, "line": s.line, "note": s.note}
                for d, s in self.raw_back_calls
            ],
            "routeConstants": [
                {
                    "name": c.name,
                    "value": c.value,
                    "template": c.template,
                    "kind": c.kind,
                    "synthetic": c.synthetic,
                    "line": c.line,
                }
                for c in self.route_constants
            ],
            "destinations": [
                {
                    "route": d.route,
                    "template": d.template,
                    "arguments": list(d.arguments),
                    "placeholders": list(d.placeholders),
                    "deepLinks": list(d.deep_links),
                    "screens": list(d.screens),
                    "composables": list(d.composables),
                    "backAffordances": list(d.back_affordances),
                    "line": d.line,
                    "isStart": d.template == self.start_destination,
                }
                for d in self.destinations
            ],
            "edges": [
                {
                    "source": e.source,
                    "target": e.target,
                    "kind": e.kind,
                    "via": e.via,
                    "trigger": e.trigger,
                    "popUpTo": e.pop_up_to,
                    "popInclusive": e.pop_inclusive,
                    "launchSingleTop": e.launch_single_top,
                    "hoistedFrom": e.hoisted_from,
                    "resolved": e.resolved,
                    "label": e.label,
                    "sites": [{"file": s.file, "line": s.line, "note": s.note} for s in e.sites],
                }
                for e in self.edges
            ],
        }


# --------------------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------------------


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _relative(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def _git_sha(root: Path) -> str:
    """Best-effort short sha; `unknown` outside a checkout rather than failing."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return out.stdout.strip() or "unknown"


def _routes_object_span(masked: str) -> tuple[int, int] | None:
    match = _ROUTES_OBJECT.search(masked)
    if not match:
        return None
    close = _match_bracket(masked, match.end() - 1, "{", "}")
    if close < 0:
        return None
    return match.end(), close


def _extract_routes(
    source: str, masked: str
) -> list[RouteConstant]:
    """Every `const val` and builder `fun` in `object NalarRoutes`.

    Constrained to the object body so a `const val` elsewhere in the file cannot
    become a phantom route.
    """
    span = _routes_object_span(masked)
    if span is None:
        return []
    start, end = span

    constants: list[RouteConstant] = []
    for match in _CONST_VAL.finditer(masked, start, end):
        quote = _first_quote_from(masked, match.end())
        if quote < 0:
            continue
        value = _string_literal_at(source, quote)
        if value is None:
            continue
        name = match.group(1)
        constants.append(
            RouteConstant(
                name=name,
                value=value,
                template=normalise_template(value),
                line=line_of(source, match.start()),
                # `ARG_*` names the value a `navArgument` declares; everything
                # else is a route pattern. Both are useful to the audit.
                kind="argument" if name.startswith("ARG_") else "route",
            )
        )

    for match in _ROUTE_FUN.finditer(masked, start, end):
        quote = _first_quote_from(masked, match.end())
        if quote < 0:
            continue
        value = _string_literal_at(source, quote)
        if value is None:
            continue
        constants.append(
            RouteConstant(
                name=match.group(1),
                value=value,
                template=normalise_template(value),
                line=line_of(source, match.start()),
                kind="route",
                # A builder is a second *spelling* of a route the constants
                # already declare, not a route of its own. It is kept because
                # `navigate(NalarRoutes.recordDetail(id))` names its target
                # through the builder, and dropping it would leave that edge
                # unresolvable.
                synthetic=True,
            )
        )

    return constants


def _route_index(constants: Sequence[RouteConstant]) -> dict[str, RouteConstant]:
    """Both spellings of every route: the `const` name and the builder name."""
    index: dict[str, RouteConstant] = {}
    for constant in constants:
        if constant.kind != "route":
            continue
        index.setdefault(constant.name, constant)
        index.setdefault(constant.name.lower(), constant)
    # A builder is found by its template even when its name differs.
    for constant in constants:
        if constant.synthetic:
            index.setdefault(constant.template, constant)
    return index


def _destination_spans(masked: str) -> list[tuple[int, int, int]]:
    """`(args_open, args_close, body_close)` for each `composable(...)`."""
    spans: list[tuple[int, int, int]] = []
    for match in _COMPOSABLE.finditer(masked):
        args_close = _match_bracket(masked, match.end() - 1, "(", ")")
        if args_close < 0:
            continue
        brace = masked.find("{", args_close)
        if brace < 0 or masked[args_close + 1 : brace].strip() != "":
            continue
        body_close = _match_bracket(masked, brace, "{", "}")
        if body_close < 0:
            continue
        spans.append((match.end() - 1, args_close, body_close))
    return spans


def _composable_calls(body: str) -> list[tuple[str, int]]:
    """`(name, brace_depth)` for every capitalised call in a composable body.

    The depth is what separates the screen a destination *is* from a value it
    happens to build: `ProjectChatsScreen(...)` sits at the top of the body and
    `ProjectSummary(...)` sits two levels down inside a `+` callback.
    """
    depth = 0
    found: list[tuple[str, int]] = []
    for index, ch in enumerate(body):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == "(":
            before = body[:index].rstrip()
            if not before:
                continue
            name = re.search(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)$", before)
            if name is None:
                continue
            head = before[: len(before) - len(name.group(1))]
            # A qualified or labelled call (`x.getString(`, `type = Foo(`) is
            # not a composable the destination renders.
            if head and head[-1] in ".?:":
                continue
            if not name.group(1)[0].isupper() or name.group(1) in _NON_SCREENS:
                continue
            found.append((name.group(1), depth))
    return found


def _root_screens(body: str) -> list[str]:
    """The composables a destination is: its top-level calls, in source order.

    A shell that renders a different screen per auth phase has no top-level
    call at all — the three screens sit inside a `when`. Falling back to every
    composable keeps that case honest rather than reporting an empty node.
    """
    tops: list[str] = []
    for name, depth in _composable_calls(body):
        if depth == 0 and name not in tops:
            tops.append(name)
    return tops or _all_composables(body)


def _all_composables(body: str) -> list[str]:
    """Every capitalised call in the body, in source order, deduplicated."""
    names: list[str] = []
    for name, _depth in _composable_calls(body):
        if name not in names:
            names.append(name)
    return names


def _extract_destinations(
    source: str, masked: str, constants: Sequence[RouteConstant]
) -> tuple[list[Destination], str, dict[int, Destination]]:
    """The `composable` blocks, the start destination, and a span→destination map.

    The map exists because a `composable(...)` whose route constant cannot be
    resolved is skipped — and if the two lists were then walked in parallel they
    would silently disagree about which body belongs to which destination. The
    map keeps the index honest instead.
    """
    spans = _destination_spans(masked)
    by_name = {c.name: c for c in constants}

    start = ""
    host = _NAV_HOST.search(masked)
    if host:
        close = _match_bracket(masked, host.end() - 1, "(", ")")
        if close > 0:
            declared = _NAV_HOST_START_DEST.search(masked, host.end(), close)
            if declared:
                start = declared.group(1)

    destinations: list[Destination] = []
    by_span: dict[int, Destination] = {}

    for index, (args_open, args_close, body_close) in enumerate(spans):
        args_text = masked[args_open : args_close + 1]
        named = re.search(r"\broute\s*=\s*NalarRoutes\.([A-Za-z_][A-Za-z0-9_]*)", args_text)
        positional = re.search(r"NalarRoutes\.([A-Za-z_][A-Za-z0-9_]*)", args_text)
        route_name = (named or positional).group(1) if (named or positional) else None
        if route_name is None or route_name not in by_name:
            continue

        constant = by_name[route_name]
        args = masked[args_open : args_close + 1]
        body = masked[args_close + 1 : body_close]

        deep_links: list[str] = []
        for link in _NAV_DEEP_LINK.finditer(args):
            quote = _first_quote_from(masked, args_open + link.end())
            if quote < 0:
                continue
            value = _string_literal_at(source, quote)
            if value:
                deep_links.append(value)

        back: list[str] = []
        for handler in _BACK_HANDLER.finditer(body):
            close = _match_bracket(body, handler.end() - 1, "{", "}")
            span = body[handler.end() : close if close > 0 else len(body)]
            if "goBack" in span:
                back.append("BackHandler { goBack() }")
        for match in _ON_BACK.finditer(body):
            back.append("onBack = %s" % match.group(1).strip())

        screens = _root_screens(body)
        composables = _all_composables(body)

        destination = Destination(
            route=route_name,
            template=constant.template,
            arguments=tuple(_NAV_ARGUMENT.findall(args)),
            deep_links=tuple(deep_links),
            screens=tuple(screens),
            composables=tuple(composables),
            back_affordances=tuple(dict.fromkeys(back)),
            line=line_of(source, args_open),
        )
        destinations.append(destination)
        by_span[index] = destination

    start_template = by_name[start].template if start in by_name else ""
    return destinations, start_template, by_span


def _resolve_target(
    args_text: str, constants: Sequence[RouteConstant]
) -> tuple[str, str, bool]:
    """`NalarRoutes.chat(id)` → `("chat/{sessionId}", via, True)`.

    Resolution goes through the route table, never a hand-written alias, so a
    builder renamed to build something else surfaces as an *unresolved* target
    the audit reports rather than as a missing edge nobody notices.
    """
    match = _TARGET_EXPR.match(args_text)
    if match is None:
        return "", args_text.strip(), False
    via = " ".join(match.group(1).split())
    name = via[len("NalarRoutes.") :].split("(", 1)[0]
    constant = _route_index(constants).get(name)
    if constant is None:
        return "", via, False
    return constant.template, via, True


def _trigger_for(window: str) -> str:
    """Best-effort human name for the user action behind a navigate call.

    Derived from the enclosing scope, because a navigation's *trigger* is what
    the audit has to reason about: "a chat this app just created" and "the
    drawer's row" are different edges even when both land on `chat/{sessionId}`.
    """
    rules = (
        (r"createdChats", "a chat this app just created"),
        (r"onOpenRecord", "opening a captured network record"),
        (r"openChats", "the drawer's “See all chats” row"),
        (r"onOpenAllChats", "a project's “See all chats” row"),
        (r"onOpenNetworkInspector|openInspector", "the network inspector button"),
        (r"onCreateTask|createTask", "creating a task"),
        (r"sessionToResume|ResumeLastPosition", "the launch resume"),
        (r"switchChat", "switching chat from the sidebar"),
        (r"onOpenChat", "opening a chat from a list"),
        (r"onChatSelected", "picking a chat in the sidebar"),
        (r"onBack|goBack", "back"),
    )
    for pattern, label in rules:
        if re.search(pattern, window):
            return label
    return "navigating"


def _enclosing_composable(
    spans: Sequence[tuple[int, int, int]], offset: int
) -> int | None:
    for index, (_, args_close, body_close) in enumerate(spans):
        if args_close < offset < body_close:
            return index
    return None


def _top_level_fun(masked: str, offset: int) -> str:
    """Name of the `fun` declaration `offset` sits inside, or `""`."""
    matches = [m for m in _TOP_LEVEL_FUN.finditer(masked) if m.start() < offset]
    if not matches:
        return ""
    head = matches[-1]
    brace = masked.find("{", head.end())
    if brace < 0 or brace > offset:
        return ""
    close = _match_bracket(masked, brace, "{", "}")
    if close < 0 or offset > close:
        return ""
    return head.group(1)


def _enclosing_effect(masked: str, offset: int) -> str | None:
    """Label of the innermost enclosing `LaunchedEffect(…)` / `DisposableEffect(…)`.

    The whole key list is the label rather than the first key, because the keys
    *are* the condition the effect re-runs on — and the enclosing function's
    name, because `LaunchedEffect(authState.phase, …)` on its own does not say
    which piece of the app decided to navigate.
    """
    best: str | None = None
    best_size: int | None = None
    for match in _EFFECT.finditer(masked):
        open_paren = masked.index("(", match.start(2) + len(match.group(2)) - 1)
        close_paren = _match_bracket(masked, open_paren, "(", ")")
        if close_paren < 0:
            continue
        brace = masked.find("{", close_paren)
        if brace < 0:
            continue
        close = _match_bracket(masked, brace, "{", "}")
        if not brace < offset < close:
            continue
        size = close - brace
        if best_size is not None and size >= best_size:
            continue
        keys = " ".join(masked[open_paren + 1 : close_paren].split())
        if len(keys) > 72:
            keys = keys[:69].rstrip() + "…"
        function = _top_level_fun(masked, match.start())
        best = "%s → %s(%s)" % (function, match.group(1), keys) if function else "%s(%s)" % (
            match.group(1),
            keys,
        )
        best_size = size
    return best


def _val_declaration_spans(masked: str) -> list[tuple[str, int, int]]:
    """`(name, start, end)` for every `val`.

    A navigation is rarely written where it happens. `val openInspector: () ->
    Unit = { navController.navigate(NalarRoutes.NETWORK) }` sits above the
    `NavHost` and is *triggered* from whichever screen receives it, so the
    lambda's span is what lets the edge be re-sourced to that screen instead of
    to an anonymous "graph".
    """
    spans: list[tuple[str, int, int]] = []
    for match in _VAL_DECL.finditer(masked):
        end = _statement_end(masked, match.end())
        if end < 0:
            continue
        spans.append((match.group(1), match.start(), end))
    return spans


def _statement_end(masked: str, start: int, limit: int = 8000) -> int:
    """End of the declaration beginning at `start`, brackets balanced.

    A `val`'s initialiser can be a multi-line call
    (`val projectActions = ProjectsActions(\n    onOpenAllChats = { … }\n)`),
    so cutting the span at the first newline would orphan every navigation
    inside it. Brackets are balanced instead.

    The `seen_eq` gate is what makes that work on a *typed* declaration:
    `val openInspector: () -> Unit = { … }` opens and closes a bracket in its
    type annotation long before the initialiser starts, and a plain depth count
    would end the span there — losing the navigate it contains. The span only
    ends once brackets have closed *after* the `=`.
    """
    depth = 0
    opened = False
    seen_eq = False
    end = min(len(masked), start + limit)
    for i in range(start, end):
        ch = masked[i]
        previous = masked[i - 1] if i > start else ""
        if (
            ch == "="
            and masked[i + 1 : i + 2] != "="
            and previous not in ("=", "!", "<", ">")
        ):
            seen_eq = True
            continue
        if ch in "({[":
            depth += 1
            opened = True
            continue
        if ch in ")}]":
            if not opened:
                return i
            depth -= 1
            if depth == 0:
                if seen_eq:
                    return i
                continue
            continue
        if ch == "\n" and opened and depth == 0:
            return i
    return -1


def _is_composable_declaration(masked: str, name: str, offset: int) -> bool:
    """Whether `name` is the `@Composable fun` the whole graph lives inside.

    Every navigation in this file is lexically inside `NalarNavGraph`, so
    using it as a scope label would label all of them the same useless thing.
    """
    for match in _TOP_LEVEL_FUN.finditer(masked):
        if match.group(1) != name or match.start() >= offset:
            continue
        preceding = masked[max(0, match.start() - 200) : match.start()]
        if "@Composable" in preceding.rsplit("}", 1)[-1]:
            return True
    return False


def _innermost(spans: Sequence[tuple[str, int, int]], offset: int) -> str | None:
    best: str | None = None
    best_size: int | None = None
    for name, start, end in spans:
        if start < offset < end and (best_size is None or end - start < best_size):
            best, best_size = name, end - start
    return best


def _callers_of(
    name: str,
    spans: Sequence[tuple[int, int, int]],
    by_span: dict[int, Destination],
    masked: str,
) -> list[str]:
    """Destinations whose `composable` body mentions `name`.

    A hoisted lambda reaches a screen by being handed to it
    (`onOpenNetworkInspector = openInspector`), so a word-boundary hit inside a
    destination body is exactly the set of screens that can trigger it.
    """
    pattern = re.compile(r"\b%s\b" % re.escape(name))
    return [
        by_span[index].template
        for index in sorted(by_span)
        if pattern.search(masked[spans[index][1] : spans[index][2]])
    ]


def _extract_edges(
    source: str,
    masked: str,
    spans: Sequence[tuple[int, int, int]],
    by_span: dict[int, Destination],
    constants: Sequence[RouteConstant],
    nav_file: str,
) -> list[Edge]:
    """One `Edge` per `navigate(...)` call site, re-sourced to its trigger.

    A call inside a `composable` belongs to that destination. A call in a
    hoisted lambda belongs to whichever destinations receive the lambda; a call
    in an effect that no screen receives stays on the `graph` rail, which is a
    claim the diagram shows rather than one it invents.
    """
    by_name = {c.name: c for c in constants}
    val_spans = _val_declaration_spans(masked)
    edges: list[Edge] = []

    for match in _NAVIGATE.finditer(masked):
        args_open = match.end() - 1
        args_close = _match_bracket(masked, args_open, "(", ")")
        if args_close < 0:
            continue

        options = masked[args_close + 1 : args_close + 600]
        template, via, resolved = _resolve_target(masked[args_open + 1 : args_close], constants)

        fun_name = _top_level_fun(masked, match.start())
        kind = "back" if fun_name == BACK_HELPER else "push"

        pop_to = None
        pop_inclusive = None
        pop = _POP_UP_TO.search(options)
        if pop:
            pop_to = by_name[pop.group(1)].template if pop.group(1) in by_name else pop.group(1)
            pop_inclusive = bool(re.search(r"inclusive\s*=\s*true", pop.group(2)))
        if pop_to is not None:
            kind = "replace"
        single_top = bool(_LAUNCH_SINGLE_TOP.search(options))

        enclosing = _enclosing_composable(spans, match.start())
        holder: str | None = None
        if enclosing is not None and enclosing in by_span:
            sources = [by_span[enclosing].template]
        else:
            # Most specific scope first: a `val` that hands its lambda to a
            # screen is the only scope whose *receivers* are knowable, so it
            # wins. Then a plain function (`ResumeLastPosition`), which names
            # the decision. Then the effect, which names its condition. The
            # `NavHost` composable itself names nothing — every navigation in
            # the app sits inside it — so it is never used as the label.
            val_name = _innermost(val_spans, match.start())
            if val_name:
                holder = val_name
                sources = _callers_of(val_name, spans, by_span, masked) or ["graph"]
            elif fun_name and not _is_composable_declaration(masked, fun_name, match.start()):
                holder = fun_name
                sources = ["graph"]
            else:
                holder = _enclosing_effect(masked, match.start()) or fun_name or None
                sources = ["graph"]

        trigger = _trigger_for(masked[max(0, match.start() - 900) : args_close + 1])
        site = Site(file=nav_file, line=line_of(source, match.start()), note=via)

        for source_route in sources:
            edges.append(
                Edge(
                    source=source_route,
                    target=template,
                    kind=kind,
                    via=via,
                    trigger=trigger,
                    pop_up_to=pop_to,
                    pop_inclusive=pop_inclusive,
                    launch_single_top=single_top,
                    hoisted_from=holder,
                    resolved=resolved,
                    sites=(site,),
                )
            )

    return edges


def _extract_back_edges(
    by_span: dict[int, Destination], nav_file: str
) -> list[Edge]:
    """One back edge per destination that offers a way out.

    The app has no `popBackStack()` call sites outside the one helper — that is
    the invariant the README states and the audit has to be able to *see*. So
    back edges come from each destination's own `onBack` / `BackHandler` rather
    than from a navigate call, and any raw pop found elsewhere is reported by
    the `raw_back_call` check instead of being quietly folded into the graph.
    """
    return [
        Edge(
            source=destination.template,
            target="__back__",
            kind="back",
            via=BACK_HELPER,
            trigger=affordance,
            hoisted_from=BACK_HELPER,
            sites=(Site(file=nav_file, line=destination.line, note=affordance),),
        )
        for destination in by_span.values()
        for affordance in destination.back_affordances
    ]


def _extract_deep_link_edges(destinations: Sequence[Destination], nav_file: str) -> list[Edge]:
    """One `deep-link` edge per `nalar://…` pattern, from a synthetic entry node."""
    return [
        Edge(
            source="__deeplink__",
            target=destination.template,
            kind="deep-link",
            via=pattern,
            trigger="`adb shell am start -a android.intent.action.VIEW -d %s`" % pattern,
            sites=(Site(file=nav_file, line=destination.line, note=pattern),),
        )
        for destination in destinations
        for pattern in destination.deep_links
    ]


def _extract_raw_back_calls(
    source: str,
    masked: str,
    spans: Sequence[tuple[int, int, int]],
    by_span: dict[int, Destination],
    nav_file: str,
) -> list[tuple[str, Site]]:
    """`popBackStack()` / `navigateUp()` call sites, minus the helper's own."""
    calls: list[tuple[str, Site]] = []
    for match in _RAW_POP.finditer(masked):
        if _top_level_fun(masked, match.start()) == BACK_HELPER:
            continue
        enclosing = _enclosing_composable(spans, match.start())
        if enclosing is not None and enclosing in by_span:
            subject = by_span[enclosing].template
        else:
            subject = _top_level_fun(masked, match.start()) or "graph"
        calls.append(
            (subject, Site(file=nav_file, line=line_of(source, match.start()), note=match.group(1)))
        )
    return calls


def _extract_manifest(path: Path) -> dict[str, int]:
    """`nalar://<host>` hosts the manifest actually claims, with their lines.

    A `navDeepLink` with no matching `<data>` is the failure mode this tool
    exists to make visible: the graph looks deep-linkable, `adb shell am start`
    resolves nothing, and no code path in the app reports an error.
    """
    text = _read(path)
    hosts: dict[str, int] = {}
    for match in re.finditer(
        r"<data\b[^>]*android:scheme\s*=\s*\"([^\"]+)\"[^>]*android:host\s*=\s*\"([^\"]+)\"",
        text,
    ):
        if match.group(1) == "nalar":
            hosts[match.group(2)] = line_of(text, match.start())
    return hosts


def extract_graph(
    root: Path,
    nav_file: Path | None = None,
    manifest_file: Path | None = None,
    generated_by: str = "navgraph",
) -> NavGraph:
    """Read the nav graph out of the Kotlin source under `root`."""
    nav_path = nav_file or (root / NAV_GRAPH_SOURCE)
    manifest_path = manifest_file or (root / MANIFEST_SOURCE)

    source = _read(nav_path)
    masked = mask_kotlin(source)

    constants = _extract_routes(source, masked)
    destinations, start, by_span = _extract_destinations(source, masked, constants)
    spans = _destination_spans(masked)
    nav_label = _relative(nav_path, root)

    edges = _extract_edges(source, masked, spans, by_span, constants, nav_label)
    edges.extend(_extract_deep_link_edges(destinations, nav_label))
    edges.extend(_extract_back_edges(by_span, nav_label))

    return NavGraph(
        destinations=destinations,
        edges=edges,
        route_constants=constants,
        start_destination=start,
        manifest_hosts=_extract_manifest(manifest_path),
        manifest_file=_relative(manifest_path, root),
        nav_file=nav_label,
        git_sha=_git_sha(root),
        generated_by=generated_by,
        raw_back_calls=_extract_raw_back_calls(source, masked, spans, by_span, nav_label),
    )


# --------------------------------------------------------------------------------------
# Audit
# --------------------------------------------------------------------------------------

SEVERITY_ORDER = {"error": 0, "warn": 1, "info": 2}


@dataclass(frozen=True)
class Finding:
    """One audit result, addressed at a destination, an edge, or the graph."""

    code: str
    severity: str  # "error" | "warn" | "info"
    title: str
    detail: str
    subject: str
    site: Site | None = None

    def to_json(self) -> dict:
        return {
            "code": self.code,
            "severity": self.severity,
            "title": self.title,
            "detail": self.detail,
            "subject": self.subject,
            "site": None
            if self.site is None
            else {"file": self.site.file, "line": self.site.line, "note": self.site.note},
        }


def _host_of(pattern: str) -> str | None:
    match = re.match(r"nalar://([^/]+)", pattern)
    return match.group(1) if match else None


def _cyclic_edges(graph: NavGraph, templates: set[str]) -> list[Edge]:
    """Every push/replace edge whose target can navigate back to its source.

    An edge is in a cycle when its source is reachable from its target, so
    `shell → chat → chats → shell` counts three edges, not one.
    """
    outgoing: dict[str, list[Edge]] = {}
    for edge in graph.edges:
        if edge.kind not in ("push", "replace"):
            continue
        if edge.source in templates and edge.target in templates:
            outgoing.setdefault(edge.source, []).append(edge)

    def reaches(source: str, target: str) -> bool:
        seen = {source}
        frontier = [source]
        while frontier:
            node = frontier.pop()
            for edge in outgoing.get(node, []):
                if edge.target == target:
                    return True
                if edge.target not in seen:
                    seen.add(edge.target)
                    frontier.append(edge.target)
        return False

    return [
        edge
        for edge in graph.edges
        if edge.source in outgoing and reaches(edge.target, edge.source)
    ]


def audit(graph: NavGraph) -> list[Finding]:
    """Every check, in one pass, so the report is a single consistent snapshot."""
    findings: list[Finding] = []
    destinations = graph.destinations
    templates = set(graph.templates())

    def site(destination: Destination) -> Site:
        return Site(file=graph.nav_file, line=destination.line, note=destination.route)

    navigations = [e for e in graph.edges if e.kind in ("push", "replace")]
    inbound: dict[str, list[Edge]] = {t: [] for t in templates}
    outbound: dict[str, list[Edge]] = {t: [] for t in templates}
    for edge in navigations:
        if edge.target in inbound:
            inbound[edge.target].append(edge)
        if edge.source in outbound:
            outbound[edge.source].append(edge)

    # 1. A deep link the manifest does not claim. `navDeepLink` looks like it
    #    works; without the `<data>` element nothing resolves the intent, and
    #    nothing in the app reports the failure.
    for destination in destinations:
        for pattern in destination.deep_links:
            host = _host_of(pattern)
            if host is None or host in graph.manifest_hosts:
                continue
            findings.append(
                Finding(
                    "deep_link_not_in_manifest",
                    "error",
                    "`%s` is not claimed by the manifest" % pattern,
                    "`navDeepLink` declares %s, but AndroidManifest.xml has no "
                    "<data android:scheme=\"nalar\" android:host=\"%s\">. "
                    "`adb shell am start -a android.intent.action.VIEW -d %s` resolves to no "
                    "activity, and it does so silently." % (pattern, host, pattern),
                    destination.template,
                    site(destination),
                )
            )

    # 2. The reverse: a host the manifest claims that no route answers. Usually
    #    a route that was deleted, or a renamed host the filter outlived.
    declared = {
        host
        for destination in destinations
        for pattern in destination.deep_links
        if (host := _host_of(pattern)) is not None
    }
    for host, line in sorted(graph.manifest_hosts.items()):
        if host in declared:
            continue
        findings.append(
            Finding(
                "manifest_host_without_route",
                "warn",
                "manifest claims `nalar://%s` with no route behind it" % host,
                "%s:%d registers an intent filter for host `%s`, but no `composable(...)` "
                "declares a `navDeepLink` for it. The link opens the app and then lands on "
                "whatever the graph does with an unmatched destination." % (graph.manifest_file, line, host),
                "graph",
                Site(file=graph.manifest_file, line=line, note='android:host="%s"' % host),
            )
        )

    # 3. A destination that is only ever reachable by deep link, with no back
    #    affordance of its own. `updateOnBackPressedCallbackEnabled` keeps the
    #    system callback disabled while `destinationCountOnBackStack <= 1`, so
    #    a reader who arrived by link has no way out except leaving the app.
    for destination in destinations:
        if destination.template == graph.start_destination:
            continue
        if destination.back_affordances:
            continue
        if destination.deep_links:
            findings.append(
                Finding(
                    "no_back_affordance",
                    "error",
                    "`%s` is deep-linkable with no way back" % destination.template,
                    "A destination reached only by `nalar://` sits alone on the back stack, "
                    "and `updateOnBackPressedCallbackEnabled` leaves the system Back callback "
                    "disabled at that depth. Without an `onBack = goBack` or a `BackHandler`, "
                    "the reader's only way out is leaving the app.",
                    destination.template,
                    site(destination),
                )
            )
        elif not inbound.get(destination.template):
            findings.append(
                Finding(
                    "unreachable_destination",
                    "error",
                    "`%s` cannot be reached" % destination.template,
                    "No `navigate(...)` targets it, it declares no deep link, and it is not the "
                    "start destination — so nothing in the app can ever put it on screen.",
                    destination.template,
                    site(destination),
                )
            )

    # 4. A route placeholder with no `navArgument`. The argument reads back as
    #    null, and the screen's own blank-check becomes the only defence.
    argument_values = {c.name: c.value for c in graph.route_constants if c.kind == "argument"}
    for destination in destinations:
        declared_args = {argument_values.get(name, name) for name in destination.arguments}
        for placeholder in destination.placeholders:
            if placeholder in declared_args:
                continue
            findings.append(
                Finding(
                    "route_placeholder_undeclared",
                    "error",
                    "`%s` reads `{%s}` but declares no navArgument" % (destination.template, placeholder),
                    "The route pattern has a `{%s}` segment and the destination declares %s, so "
                    "`backStackEntry.arguments` yields null for it."
                    % (placeholder, list(destination.arguments) or "no arguments"),
                    destination.template,
                    site(destination),
                )
            )

    # 5. A route constant nothing composes — usually a leftover from a screen
    #    that was deleted and left the constant behind.
    composed = {d.route for d in destinations}
    for constant in graph.route_constants:
        if constant.kind != "route" or constant.synthetic or constant.name in composed:
            continue
        findings.append(
            Finding(
                "route_constant_unused",
                "warn",
                "`NalarRoutes.%s` is never a destination" % constant.name,
                "`%s` is declared but no `composable(...)` uses it. Either the screen is gone "
                "and the constant outlived it, or the screen was never wired." % constant.value,
                "graph",
                Site(file=graph.nav_file, line=constant.line, note=constant.name),
            )
        )

    # 6. Back that does not go through the helper. The README's rule is that
    #    every back affordance goes through `goBackToPreviousOrShell`; a bare
    #    `popBackStack()` behind an arrow is the documented defect.
    findings.extend(_raw_back_findings(graph))

    # 7. A navigation the extractor could not map to a destination. This is the
    #    tool telling the truth about its own coverage rather than quietly
    #    drawing a smaller graph than the app actually has.
    for edge in graph.edges:
        if edge.resolved or not edge.sites:
            continue
        findings.append(
            Finding(
                "unresolved_target",
                "error",
                "a `navigate` target could not be resolved: `%s`" % edge.via,
                "The extractor read this call site but could not map it to a declared route. "
                "Either the route constant was removed or the target is built dynamically; "
                "until it resolves, the audit cannot see this edge.",
                edge.label,
                edge.sites[0],
            )
        )

    # 8. An edge whose target is already reachable from its own source. Not
    #    "far from the start" — a list → detail push is two hops and is exactly
    #    what Back exists for. The unbounded shape is pressing the *same*
    #    navigation again: each press adds another copy, and nothing pops.
    for edge in navigations:
        if edge.kind == "replace" or edge.pop_up_to is not None:
            continue
        if edge.source == "graph" or edge.target != edge.source:
            continue
        findings.append(
            Finding(
                "self_push",
                "warn",
                "%s pushes onto itself" % edge.source,
                "The navigation target is the destination it is triggered from, and nothing "
                "is popped — so repeating %s stacks another copy of the same screen every "
                "time. The app's own precedent for switching is "
                "`popUpTo(NalarRoutes.SHELL) { inclusive = false }` with `launchSingleTop`."
                % edge.trigger,
                edge.label,
                edge.sites[0] if edge.sites else None,
            )
        )

    # 9. Cyclic pushes. Reported once, not once per edge: in a hub-and-spoke
    #    app nearly every push closes a loop back to the hub, so a per-edge
    #    finding here is noise. What matters is the *total* — how long the
    #    back stack can get — and whether any cycle member already replaces
    #    instead of pushing.
    cyclic = _cyclic_edges(graph, templates)
    if cyclic:
        replaces = sum(1 for edge in cyclic if edge.kind == "replace")
        findings.append(
            Finding(
                "cyclic_navigation",
                "info",
                "%d navigation edges close a loop" % len(cyclic),
                "%d of the %d navigations lead back to somewhere they came from, so the "
                "back stack can grow past the number of destinations the reader has visited. "
                "%d of those %d already replace rather than push (`popUpTo` + "
                "`launchSingleTop`); the rest are drill-downs and deliberate switches, so "
                "this is a number to watch rather than a defect."
                % (len(cyclic), len(navigations), replaces, len(cyclic)),
                "graph",
            )
        )

    # 9. Terminal destinations — worth knowing, not worth failing over.
    for destination in destinations:
        if destination.template == graph.start_destination:
            continue
        if outbound.get(destination.template):
            continue
        findings.append(
            Finding(
                "terminal_destination",
                "info",
                "`%s` navigates nowhere" % destination.template,
                "Every screen it renders is a leaf of the navigation graph: there is no "
                "`navigate` call inside it. Expected for a detail screen, wrong for anything "
                "meant to be a hub.",
                destination.template,
                site(destination),
            )
        )

    findings.sort(key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code, f.subject))
    return findings


def _raw_back_findings(graph: NavGraph) -> list[Finding]:
    """A `popBackStack()` or `navigateUp()` anywhere outside the one helper.

    This is the invariant the README states in prose and that no test can hold
    across a file edit, so the audit reads it straight off the source. The
    helper's own internal `popBackStack()` is excluded by name — the helper *is*
    the sanctioned place for one, and flagging it would train the reader to
    ignore the finding.
    """
    return [
        Finding(
            "raw_back_call",
            "error",
            "`%s()` outside `%s`" % (back_site.note, BACK_HELPER),
            "`NavController.popBackStack()` with no argument is inclusive: at a "
            "one-destination depth it empties the back stack and `NavHost` renders nothing. "
            "Every back affordance in this app is routed through one helper for that reason, "
            "so a direct call is the defect itself.",
            destination or "graph",
            back_site,
        )
        for destination, back_site in graph.raw_back_calls
    ]


# --------------------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------------------

NODE_W = 214
NODE_H = 64
H_GAP = 120
V_GAP = 104
MARGIN_X = 40
MARGIN_Y = 32


def _layer_ranks(
    templates: Sequence[str], edges: Sequence[Edge], start: str
) -> dict[str, int]:
    """Minimum taps from the launch, breadth-first.

    Not longest-path. This graph has real cycles — a chat reaches the chats
    list, and the list reaches a chat — so a longest-path rank does not settle:
    `app → chats → chat → chats → chat …` pushed the chat row to 2048. Breaking
    each cycle to make it settle *also* lies, because which edge gets dropped
    decides the answer, and it reported `project/{workspaceId}/{itemId}` as
    three taps from the shell when it is one.

    Breadth-first is what the row axis claims to mean anyway: "how many taps
    from the launch". It is well-defined on a cyclic graph, and it is the
    number an audit is asking about.
    """
    outgoing: dict[str, list[str]] = {t: [] for t in templates}
    for edge in edges:
        if edge.kind not in ("push", "replace"):
            continue
        if edge.source in outgoing and edge.target in outgoing and edge.source != edge.target:
            outgoing[edge.source].append(edge.target)

    root = start if start in templates else (templates[0] if templates else "app")
    depth = {root: 0}
    frontier = [root]
    while frontier:
        nxt: list[str] = []
        for node in frontier:
            for target in outgoing.get(node, []):
                if target in depth:
                    continue
                depth[target] = depth[node] + 1
                nxt.append(target)
        frontier = nxt

    # Whatever is left is unreachable from the start inside the app; it keeps a
    # row of its own rather than being stacked on the launch's row.
    for template in templates:
        depth.setdefault(template, 0)
    return depth


def layout(graph: NavGraph) -> dict[str, dict[str, float]]:
    """Deterministic layered positions: rank by depth, order by barycentre.

    A force simulation would look livelier and be useless here. An audit page
    has to redraw to the same picture every time — so a finding can be
    discussed by pointing at a location — and "which screen is how many taps
    from home" is a *rank* question, so the ranking is the layout.
    """
    templates = graph.templates()
    rank_of = _layer_ranks(templates, graph.edges, graph.start_destination)

    rows: dict[int, list[str]] = {}
    for template in templates:
        rows.setdefault(rank_of.get(template, 0), []).append(template)

    predecessors: dict[str, list[str]] = {t: [] for t in templates}
    for edge in graph.edges:
        if (
            edge.kind in ("push", "replace")
            and edge.target in predecessors
            and edge.source in rank_of
            and edge.source != edge.target
        ):
            predecessors[edge.target].append(edge.source)

    order_index = {t: i for i, t in enumerate(templates)}

    # Two barycentre sweeps, one per direction. Two is enough at this size and
    # keeps the result reproducible without a convergence loop whose tie
    # breaking could drift between runs.
    for sweep in range(2):
        for rank in sorted(rows, reverse=bool(sweep % 2)):
            scored: list[tuple[float, int, str]] = []
            for template in rows[rank]:
                above = [
                    p
                    for p in predecessors[template]
                    if rank_of.get(p, 0) < rank
                ]
                if above:
                    centre = sum(order_index[p] for p in above) / len(above)
                else:
                    centre = float(order_index[template])
                scored.append((centre, order_index[template], template))
            rows[rank] = [name for _, _, name in sorted(scored)]

    widest = max((len(row) for row in rows.values()), default=1)
    span = widest * NODE_W + (widest - 1) * H_GAP
    positions: dict[str, dict[str, float]] = {}
    for rank in sorted(rows):
        row = rows[rank]
        row_span = len(row) * NODE_W + (len(row) - 1) * H_GAP
        start_x = MARGIN_X + (span - row_span) / 2
        y = MARGIN_Y + rank * (NODE_H + V_GAP)
        for column, template in enumerate(row):
            positions[template] = {
                "x": start_x + column * (NODE_W + H_GAP),
                "y": y,
                "w": NODE_W,
                "h": NODE_H,
            }

    return positions


# --------------------------------------------------------------------------------------
# Payload
# --------------------------------------------------------------------------------------


def render_payload(graph: NavGraph) -> dict:
    """The single JSON object the HTML viewer embeds."""
    findings = audit(graph)
    payload = graph.to_json()
    payload["layout"] = layout(graph)
    payload["findings"] = [f.to_json() for f in findings]
    payload["destinationCount"] = len(graph.destinations)
    payload["edgeCount"] = len(graph.edges)
    payload["errorCount"] = sum(1 for f in findings if f.severity == "error")
    payload["warnCount"] = sum(1 for f in findings if f.severity == "warn")
    payload["infoCount"] = sum(1 for f in findings if f.severity == "info")
    return payload


def dumps(payload: dict) -> str:
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"