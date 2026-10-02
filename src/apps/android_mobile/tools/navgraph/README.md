# `tools/navgraph` — the Android navigation audit page

A static analyser for `android_mobile`'s `NavHost`, and an interactive HTML page
it renders. Nothing here is hand-maintained: every destination, route, deep
link, argument and `navigate(...)` call site is read out of
`app/src/main/java/com/nalar/mobile/network/NalarNavGraph.kt`, and every
`nalar://` host is cross-checked against `AndroidManifest.xml`.

```bash
cd src/apps/android_mobile
python3 tools/navgraph/build.py            # regenerate navgraph.html + navgraph.json
python3 tools/navgraph/build.py --check    # exit 1 if either is stale (use in CI)
```

Open `src/apps/android_mobile/navgraph.html` in a browser. It is a single file
with no external requests, so it works off a filesystem over `ssh`, from a
branch download, or straight out of a PR artifact.

## What the page gives you

* **The graph.** Every destination as a node, every `navigate()` as an edge,
  laid out by taps-from-launch. Hover to isolate a destination's neighbourhood;
  click for its arguments, deep links, back affordance, and every inbound and
  outbound navigation with the `file:line` it came from.
* **Findings.** Ten checks over the graph, each naming the Kotlin site it is
  about — see the table below.
* **A destination table.** Sortable, filterable by the search box, with the
  deep-link and back-affordance state inline. This is the view to scan; the
  picture is the view to read.

## Why the extractor reads text instead of running Gradle

The alternative — parse the compiled class files, or ask `navigation-fragment`
via a Gradle task — was rejected deliberately. A static audit page is a static
artifact, and the machines where you want to look at it (a review laptop, a CI
container, a phone-tethered shell) are the machines least likely to have a
working JDK + Gradle + Android SDK. Reading text costs precision, and the
precision is bought back in two places:

* **A masking pass, not raw regexes.** `navgraph.mask_kotlin` blanks comment
  and string bodies in place, preserving every offset and every newline. Every
  structural match in the module runs against that masked text, so a
  `composable(` mentioned in a KDoc cannot become a destination and a
  `}` inside a string cannot end a block early. Offsets are preserved so a
  match found in the mask can be sliced out of the *original* to recover the
  literal value.
* **Template identity instead of a name table.** `NalarRoutes` declares each
  route twice — once as a `const val`, once as a `fun` builder that
  interpolates it. Both are normalised to the same `{placeholder}` template
  (`chat/${UriEncoding.encode(sessionId)}` → `chat/{sessionId}`) and matched
  on that, so `navigate(NalarRoutes.chat(id))` lands on the `chat/{sessionId}`
  destination without a hand-written alias table that could itself go stale.

Both properties are asserted in `tests/functional_android/navgraph_contract_test.py`.

## What the audit checks

| Code | Severity | Meaning |
|---|---|---|
| `deep_link_not_in_manifest` | error | A `navDeepLink` pattern whose host has no `<intent-filter>`. The link resolves to no activity, silently. |
| `manifest_host_without_route` | warn | The manifest claims a host no `navDeepLink` answers — an intent filter outlived its screen. |
| `no_back_affordance` | error | A deep-linkable destination with no `onBack` and no `BackHandler`. `updateOnBackPressedCallbackEnabled` leaves the system Back disabled at that depth, so the only way out is leaving the app. |
| `unreachable_destination` | error | Nothing navigates to it and it declares no deep link. |
| `route_placeholder_undeclared` | error | A `{segment}` in the route with no matching `navArgument`. |
| `raw_back_call` | error | `popBackStack()` / `navigateUp()` outside `goBackToPreviousOrShell`. The bare call is inclusive and empties a one-deep stack. |
| `route_constant_unused` | warn | A `NalarRoutes` const that no `composable(...)` uses. |
| `self_push` | warn | A navigation whose target is the source, popping nothing. |
| `unresolved_target` | error | A `navigate(...)` the extractor could not map to a route. This is the tool reporting on itself: it means an edge is missing from the picture. |
| `cyclic_navigation` | info | How many edges lead back to somewhere they came from, and how many of those already replace rather than push. A number to watch, not a defect. |

A finding's `subject` is a destination template, an `A → B` edge label, or
`graph`. The click handler on a finding resolves that to a node or an edge and
scrolls to it.

## Staying honest

The page is committed, which means it can go stale — and a stale audit page is
worse than none, because it is confidently wrong. Three guards:

1. `build.py --check` compares the committed output against a fresh render. The
   git sha is masked out of the comparison, so an unrelated commit does not
   fail the build while a changed `NalarNavGraph.kt` does.
2. `navgraph_contract_test.py` asserts the committed `navgraph.json` and
   `navgraph.html` are current.
3. The output is byte-stable — sorted keys, no timestamps — so re-running
   `build.py` on an unchanged tree is a no-op and a diff means something moved.

`navgraph.html` must keep making zero network requests. A `<script src>` or a
webfont would make the page fail exactly where you most want it, so there is a
test that greps for them.

## Files

| Path | Role |
|---|---|
| `navgraph.py` | Masking, extraction, the audit checks, the layered layout. Pure stdlib. |
| `build.py` | CLI. Substitutes the payload into the template and writes the two artifacts. |
| `viewer_template.html` | The page. Three placeholders: `__NAVGRAPH_TITLE__`, `__NAVGRAPH_PAYLOAD__`, `__NAVGRAPH_SHA__`. |
| `../../navgraph.html` | Generated. The audit page. |
| `../../navgraph.json` | Generated. The same data, for anything that wants to diff it. |

## Known findings

The audit currently reports two **errors**, both real and both about the
manifest rather than the graph:

`nalar://chats/{workspaceId}` and `nalar://project/{workspaceId}/{itemId}` are
declared as `navDeepLink` patterns in `NalarNavGraph.kt`, but
`AndroidManifest.xml` only claims hosts `network` and `chat`. Both links
therefore resolve to no activity:

```bash
adb shell am start -a android.intent.action.VIEW -d nalar://chats/ws_1
# Error: Activity not started, unable to resolve Intent
```

The fix is two `<intent-filter>` blocks in the manifest. That is a change to
app behaviour and is deliberately **not** part of this tool, so the finding
stays visible until someone decides. `test_audit_acknowledges_the_unreachable_deep_links`
pins both hosts so the gap cannot be forgotten; delete them from that set when
the filters land.