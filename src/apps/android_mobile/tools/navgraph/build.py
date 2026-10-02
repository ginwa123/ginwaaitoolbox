"""Regenerate the navigation-graph audit page and its JSON sidecar.

    python3 tools/navgraph/build.py            # write navgraph.html + navgraph.json
    python3 tools/navgraph/build.py --check    # fail if the committed copy is stale
    python3 tools/navgraph/build.py --out DIR  # somewhere else

`--check` is the one that belongs in CI. The audit page is a committed
artifact — a reviewer should be able to open it from a PR without running
anything — and a committed artifact that nobody regenerates is worse than none,
because it is confidently wrong. The check compares the freshly-rendered page
against what is on disk with the git sha masked out, so an unrelated commit does
not fail it while a changed `NalarNavGraph.kt` does.

### Why the sha is masked rather than excluded

The sha is genuinely worth printing on the page: "generated at `0405d4fc`" is
what tells a reader whether the diagram they are looking at predates the change
they just made. But it changes on *every* commit, including commits that touch
no navigation code at all, so an unmasked comparison would fail the build on
every unrelated PR. Masking it keeps the useful half and drops the noise.

### Why the output is byte-stable

`--check` is a byte comparison, so the render has to be deterministic: the
payload is `sort_keys=True` indented JSON, the template is substituted rather
than regenerated, and nothing carries a timestamp. Re-running `build.py` on an
unchanged tree must produce a byte-identical file, or the check is noise.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

if __package__ in (None, ""):  # running the file directly, not as a module
    sys.path.insert(0, str(Path(__file__).resolve().parent))

import navgraph  # noqa: E402

#: The directory the tool lives in, four levels below the Android project and
#: five below the repository root.
_ANDROID_PROJECT = navgraph.ANDROID_PROJECT

#: Committed artifacts. Both live at the top of the Android project so the
#: page is one path in the README rather than a `tools/` detour, and so a
#: reviewer opening the diff sees it change when navigation changes.
DEFAULT_HTML = _ANDROID_PROJECT / "navgraph.html"
DEFAULT_JSON = _ANDROID_PROJECT / "navgraph.json"

TEMPLATE = Path(__file__).resolve().parent / "viewer_template.html"

#: Both artifacts record the commit they were generated from. That is worth
#: printing and worth *ignoring when comparing*: committing a regenerated page
#: moves HEAD, so an unmasked comparison would make every artifact stale the
#: instant it was committed and the check could never pass. Both spellings are
#: covered — the HTML carries it in a meta tag, the JSON as an indented key.
_SHA_JSON = re.compile(r'("gitSha"\s*:\s*")[^"]*(")')
_SHA_META = re.compile(r'(<meta name="navgraph-sha" content=")[^"]*(">)')


def strip_sha(text: str) -> str:
    """The artifact with its git sha masked out, for staleness comparison."""
    return _SHA_JSON.sub(r"\1X\2", _SHA_META.sub(r"\1X\2", text))


def find_root(start: Path | None = None) -> Path:
    """The repository root, found by walking up to a `.git` or `pyproject.toml`.

    Walked rather than counted, so moving the tool between directories does not
    silently make it read the wrong tree.
    """
    here = (start or Path(__file__)).resolve()
    for candidate in [here, *here.parents]:
        if (candidate / ".git").exists() or (candidate / "pyproject.toml").is_file():
            return candidate
    # A tarball or a container image without either marker still has a
    # predictable depth from this file.
    return Path(__file__).resolve().parents[5]


def render_html(payload: dict, title: str, template: str | None = None) -> str:
    """Substitute the payload, sha and title into the viewer template."""
    source = (template or TEMPLATE)
    text = Path(source).read_text(encoding="utf-8") if isinstance(source, Path) else source
    for placeholder in ("__NAVGRAPH_TITLE__", "__NAVGRAPH_PAYLOAD__", "__NAVGRAPH_SHA__"):
        if placeholder not in text:
            raise SystemExit(
                "viewer_template.html is missing the %s placeholder — the template and "
                "build.py disagree about the contract." % placeholder
            )
    compact = json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    # `</script>` inside a JSON string would close the tag early. The only place
    # it can come from is a route pattern or a source snippet, and none today,
    # but a `<` escape is free and removes the class of bug entirely.
    compact = compact.replace("<", "\\u003c")
    return (
        text.replace("__NAVGRAPH_TITLE__", title)
        .replace("__NAVGRAPH_PAYLOAD__", compact)
        .replace("__NAVGRAPH_SHA__", payload["meta"]["gitSha"])
    )


def build(
    root: Path,
    html_out: Path | None = None,
    json_out: Path | None = None,
    template: str | None = None,
) -> tuple[Path, Path]:
    """Extract, audit, render. Returns the two written paths."""
    html_path = html_out or (root / DEFAULT_HTML)
    json_path = json_out or (root / DEFAULT_JSON)

    graph = navgraph.extract_graph(root, generated_by="tools/navgraph/build.py")
    payload = navgraph.render_payload(graph)
    page = render_html(payload, "Nalar Android — navigation graph", template)

    json_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(navgraph.dumps(payload), encoding="utf-8")
    html_path.write_text(page, encoding="utf-8")
    return html_path, json_path


def check(root: Path) -> int:
    """Exit 0 when the committed page matches the source; 1 when it is stale.

    Both halves matter. A missing file is stale. A file whose findings disagree
    with the source is stale. A file that differs *only* in its git sha is up to
    date in substance, and reported as a note rather than a failure so the page
    does not block every commit that touches no navigation code.
    """
    graph = navgraph.extract_graph(root, generated_by="tools/navgraph/build.py")
    payload = navgraph.render_payload(graph)
    fresh = render_html(payload, "Nalar Android — navigation graph", None)

    html_path = root / DEFAULT_HTML
    json_path = root / DEFAULT_JSON

    problems: list[str] = []
    if not html_path.is_file():
        problems.append("%s does not exist — run `python3 tools/navgraph/build.py`" % DEFAULT_HTML)
    elif strip_sha(html_path.read_text(encoding="utf-8")) != strip_sha(fresh):
        problems.append(
            "%s is stale: re-running `python3 tools/navgraph/build.py` changes it. Either "
            "NalarNavGraph.kt moved and nobody regenerated the page, or the template changed."
            % DEFAULT_HTML
        )
    if not json_path.is_file():
        problems.append("%s does not exist — run `python3 tools/navgraph/build.py`" % DEFAULT_JSON)
    elif strip_sha(json_path.read_text(encoding="utf-8")) != strip_sha(
        navgraph.dumps(payload)
    ):
        problems.append("%s is stale" % DEFAULT_JSON)

    if problems:
        for problem in problems:
            print("navgraph: %s" % problem, file=sys.stderr)
        return 1

    errors = payload["errorCount"]
    print(
        "navgraph: up to date — %d destinations, %d edges, %d audit error(s), %d warning(s), "
        "%d note(s) (commit %s)"
        % (
            payload["destinationCount"],
            payload["edgeCount"],
            errors,
            payload["warnCount"],
            payload["infoCount"],
            payload["meta"]["gitSha"],
        )
    )
    for finding in payload["findings"]:
        if finding["severity"] == "error":
            print("  [%s] %s — %s" % (finding["severity"], finding["subject"], finding["title"]))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=None, help="repository root")
    parser.add_argument("--out", type=Path, default=None, help="write the HTML here")
    parser.add_argument("--json-out", type=Path, default=None, help="write the JSON here")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the committed page no longer matches the source",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve() if args.root else find_root()
    if args.check:
        return check(root)

    html_path, json_path = build(root, args.out, args.json_out)
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    print(
        "navgraph: wrote %s and %s — %d destinations, %d edges, %d error(s), %d warning(s)"
        % (
            html_path,
            json_path,
            payload["destinationCount"],
            payload["edgeCount"],
            payload["errorCount"],
            payload["warnCount"],
        )
    )
    for finding in payload["findings"]:
        if finding["severity"] == "error":
            print("  [%s] %s — %s" % (finding["severity"], finding["subject"], finding["title"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())