# nalar — `apiFetch` mock helpers need `text()` method + active Pinia

The shared `apiFetch` wrapper in `src/apps/desktop/src/api/index.ts` (added in the API
error notification feature) has two requirements that bare-bones `fetch` mocks miss:

1. **`response.text()` is called on every non-OK response** to extract the body
   for the error notification. Mocks must implement `text: () => Promise.resolve(...)`
   in addition to `json: () => Promise.resolve(...)`.

2. **`useNotificationStore()` is called on every non-OK response** to fire a
   toast. Tests must set up an active Pinia instance via
   `setActivePinia(createPinia())` in `beforeEach`, otherwise the call throws
   `[🍍]: "getActivePinia()" was called but there was no active Pinia`.

## Symptom

After migrating an API function to `apiFetch`, its unit test fails with one of:

```
TypeError: response.text is not a function
```

```
[🍍]: "getActivePinia()" was called but there was no active Pinia.
```

The test was written before the migration and only mocked the parts the
old `fetch + if !ok + throw` code path needed (just `json()`). Once the
function routes through `apiFetch`, the test's mock is missing the two
extra pieces the wrapper requires.

## The two-line fix

Add `text: () => Promise.resolve(JSON.stringify(body))` to the mock helper:

```ts
function mockFetchOnce(status: number, body: unknown) {
  fetchMock.mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),  // ← add
  } as Response)
}
```

Add Pinia setup in `beforeEach`:

```ts
beforeEach(() => {
  setActivePinia(createPinia())  // ← add (apiFetch needs it for toasts)
  // ... existing test setup
})
```

## Why this bites

The bare-bones mock pattern (`{ ok, status, json }`) is sufficient for the
old `fetch` + `if (!response.ok) throw new Error()` pattern because that path
only reads `response.json()`. The `apiFetch` wrapper additionally:

- Calls `await response.text().catch(() => '')` to extract the body for
  error reporting (line 54 in the current `api/index.ts`).
- Calls `useNotificationStore().notifyError(...)` to surface the error as
  a toast (line 60). Pinia throws if no store is registered.

A test that only tests the success path (2xx response) works without
either fix because the `!response.ok` branch is never reached. The bug
surfaces on the FIRST test that triggers a 4xx/5xx response.

## Real example in this repo

`apiRunRoutine.spec.ts` had 6 tests, 1 of which (`throws on non-2xx 409`)
was previously passing on the legacy `fetch`+`throw` implementation. After
migrating `runRoutine` to `apiFetch`, that test failed twice in
succession (first with "response.text is not a function", then with the
Pinia warning). Both were fixed with the two additions above.

The same pattern was needed for `apiMemories.spec.ts` (4 failures) and
`apiDeleteProfile.spec.ts` (1 failure, pre-emptive fix during batch 7).

## When this bites

- Any test that mocks `fetch` for a function that was just migrated to `apiFetch`.
- Adding a new test for an `apiFetch`-using function that exercises 4xx/5xx
  responses.
- Reviewing a PR that migrates a function to `apiFetch` — the test mock
  needs both additions; only fixing one of them causes a confusing
  follow-up error after the first is addressed.

## How to verify

After migrating any function to `apiFetch`, run its test file:

```bash
cd src/apps/desktop && timeout 120 bunx vitest run <test-file>
```

If the test exercises 4xx/5xx and the mock has no `text()` and no
`setActivePinia`, you'll see one of the two errors above. Apply the
two-line fix and re-run.

For new tests, copy the mock helper from `apiMemories.spec.ts` — it's
the canonical pattern (has `text()` + the `setActivePinia` setup).
