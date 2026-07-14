# cloak_browser snapshot does NOT capture JavaScript-rendered content

`cloak_browser`'s `snapshot` action returns the page's accessibility tree —
essentially the same content a screen reader would see. This includes
**static HTML elements only**. Values that are populated by client-side
JavaScript (currency rates, live prices, server-rendered SPAs, dynamic
charts) appear in the snapshot as empty placeholders or as raw CSS class
names (e.g. `:rr:`, `:r13:`) — never as the actual numbers.

## Symptom

You browse `https://www.xe.com/currencyconverter/...` or
`https://wise.com/id/currency-converter/...` to get a daily exchange rate.
The snapshot returns the entire page navigation, the footer, the FAQs,
the chart controls, and the "X USD" preset links — but the actual
converted-amount value is missing or shows a placeholder like `:rr:`.

The page is fully loaded (status 200, title correct, page structure
present), but the dynamic value just isn't there.

## Why

The accessibility tree is captured from the rendered DOM at the moment
of the snapshot. JavaScript that runs AFTER the initial DOM parse
populates elements with content (often via framework hydration: React,
Vue, Svelte). The accessibility tree does not see post-hydration
content unless the snapshot is taken after hydration completes — and
the snapshot does NOT wait for hydration.

## Fix for live-data needs: use a free API endpoint via curl

For currency rates, weather, stock prices, and any other "live number"
request, skip the browser entirely and `curl` a free API:

```bash
curl -sS "https://open.er-api.com/v6/latest/USD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"1 USD = {d[\"rates\"][\"IDR\"]:,.4f} IDR")
# etc.
'
```

Other free FX APIs:
- `https://api.exchangerate-api.com/v4/latest/USD` (different format)
- `https://open.er-api.com/v6/latest/USD` (used above — returns
  `{"result":"success","base_code":"USD","rates":{...},"time_last_update_utc":...}`)
- `https://api.frankfurter.app/latest?from=USD&to=IDR,EUR,SGD,MYR`
  (European Central Bank reference rates, no API key, free)

## When this bites

- Any "get today's rate / price / weather / score" type request.
- Any site that's a Single Page App (Vue, React, Svelte) — these
  hydrate client-side and the snapshot misses it.
- The Google search results page itself — the "currency converter"
  widget is a JS-injected element; the snapshot shows
  "Pengonversi nilai tukar mata uang" as the section header but the
  actual conversion numbers are not in the tree.

## How to verify

If a `snapshot` returns a page with rich structure but missing the
specific data you went there for, it's almost always a hydration
issue. Switch to a free API or a server-rendered endpoint
(`?output=text`, `?format=json`, `Accept: application/json`).
