# Fix plan — multiple chat attachments render a broken "Attached image" placeholder

- **Date:** 2026-10-05
- **Task:** `task_1791187783311_2` — "fix when input multiple image" (scope: find the root cause)
- **Branch:** `worktree/fix-when-input-multiple-image-1791187781448`
- **Status:** root cause PROVEN. Fix NOT implemented — awaiting human review of this plan.

---

## 1. The symptom

Attach two images to one chat message. The bubble renders **three** thumbnail
slots: image 1, a broken-image glyph with the literal words *"Attached
image"*, then image 2. The assistant's answer is correct, so the model
received both images.

```
[img 1 ok] [ 🖼 "Attached image" ] [img 2 ok]
```

## 2. Root cause — a delimiter mismatch, not a lost upload

**`llm_history.image_url` is stored `||`-delimited. The desktop Vue client
splits on a SINGLE `'|'`.**

`"A||B".split('|')` yields `["A", "", "B"]` — the two-character `||` separator
contains a `|` that the client mistakes for a second delimiter, so it produces
one **spurious empty string per image gap**. `ChatView.vue:4823` renders every
element with `<img :src="imgUrl" alt="Attached image">`, and `src=""` is a
broken image, which the browser draws with its `alt` text.

N images → `2N − 1` thumbnails, of which `N − 1` are broken placeholders.

### 2.1 The wire trace for one 2-image turn

| # | Site | Delimiter | Value / result |
|---|------|-----------|----------------|
| 1 | `src/apps/desktop/src/api/index.ts:1662` — `images.join('\|')` | `\|` | request body `A\|B` |
| 2 | `src/agentic_loop/insert_queue_message.zig:39` — INSERT, verbatim | — | `session_queue_messages.image_url = A\|B` |
| 3 | `src/agentic_loop/workflow.zig:958` — drain, `splitScalar('\|')` **+ drops empty** | `\|` | `[A, B]` → **LLM gets both images ✅** |
| 4 | `src/agentic_loop/insert_llm_histories.zig:191` — `appendSlice("\|\|")` | **`\|\|`** | `llm_history.image_url = A\|\|B` |
| 5 | `insert_llm_histories.zig:250` — `.image_url = copy_image_urls` → SSE `llm_full` | **`\|\|`** | frame carries `A\|\|B` |
| 6 | **`ChatView.vue:3887`** (SSE push) — `event.image_url.split('\|')`, **no empty-filter** | `\|` | `["A", "", "B"]` → **3 `<img>`, middle broken 💥** |
| 6b | **`ChatView.vue:3799`** (SSE in-place update) — identical bug | `\|` | same |
| 6c | **`ChatView.vue:2151`** (REST hydrate) — identical bug | `\|` | same |
| 6d | `ChatView.vue:2152 / 3800 / 3888` — the identical bug for **video** | `\|` | same class |
| 7 | `ChatView.vue:4823-4832` — `v-for` over `userMsg.image_urls` | — | `""` → `<img src="">` → broken + `alt="Attached image"` |

Step 3 is why the model behaves correctly. **Do not investigate the model path** —
it is not the defect.

### 2.2 Why it is only broken *live*, not after a refresh

`GET /api/llm/session/:id/messages` (`src/http_handlers/session_messages_get.zig:110`)
**re-joins the already-split array with a single `'|'`**, and the backend's own
read paths (`src/agentic_loop/llm_history.zig:1001 / 1827 / 2702 / 2825`) split
the DB's `||` string on `'|'` **while dropping empty segments**. So REST returns
`A|B` → the correct 2 thumbnails.

⇒ **Falsifiable prediction: hit F5 on the session and the broken placeholder
disappears.** (It stays broken until then because `liveMessageIds` suppresses
the REST repair for rows SSE already delivered.)

### 2.3 Empirical proof from the user's own production DB

`~/.config/pabrik/agent.db` — the only DB of the three that has `llm_history`
(`db.sqlite` and `pabrik.db` do not):

```
llm_history rows with image_url                  : 908
  containing `||`   (multi-image)                : 114   (105× 2-image, 9× 3-image)
  single-pipe-only                               : 0     ← contract is unambiguously `||`
  no pipe (single image)                         : 794
broken <img src=""> already in the transcript     : 123
session_queue_messages rows with image_url       : 1     (never `||` — the queue row is single-|)
```

Reproduce:

```bash
sqlite3 ~/.config/pabrik/agent.db "
SELECT (length(image_url) - length(replace(image_url,'||',''))) / 2 + 1 AS n_images,
       COUNT(*) AS rows
FROM llm_history WHERE COALESCE(image_url,'') LIKE '%||%'
GROUP BY n_images ORDER BY n_images;"
```

**Zero rows are single-pipe-only.** Every multi-image row in the database is
`||`-joined. The wire contract is not in doubt.

### 2.4 Observable witness of the render

```js
const sseFrame = "data:image/png;base64,AAA" + "||" + "data:image/jpeg;base64,BBB"
sseFrame.split("|")
// → ["data:image/png;base64,AAA", "", "data:image/jpeg;base64,BBB"]   // 3 <img>
sseFrame.split("|").filter(s => s.length > 0)
// → ["data:image/png;base64,AAA", "data:image/jpeg;base64,BBB"]       // 2 <img>
```

Three slots, the middle broken — a pixel-for-pixel match with the screenshot.

## 3. Everyone else already got it right — desktop chat is the sole outlier

| Site | Behaviour |
|------|-----------|
| `api/index.ts:973 / 1087 / 1179` | kanban task create/update **joins `\|\|`** |
| `api/index.ts:824` | `v.split('\|').filter(seg => seg.length > 0)` ← **the pattern to copy** |
| `stores/workspaces.ts:379 / 402` | split `'\|'` **+ filter empties** |
| `http_handlers/image_urls_validation.zig:64` | split `'\|'` + `continue` on empty |
| `http_handlers/video_urls_validation.zig:43` | split `'\|'` + `continue` on empty |
| `http_response.zig:208 / 217` | **documents `\|\|` as the wire format** |
| Android `chat/ChatApi.kt:366-372` `splitPipeDelimited` | split `'\|'` + `filter { it.isNotEmpty() }` |

**Android renders the identical payload correctly.** The desktop's missing
`.filter(len > 0)` is the entire delta.

## 4. Why no test caught it

`src/apps/desktop/src/__tests__/sseImageUrls.spec.ts:51` defines its **own**
`splitImageUrls` that mirrors the production one-liner, then asserts on the
**mirror** using a hand-written **single-pipe** fixture (`'a|b|c'`):

```ts
const splitImageUrls = (event: SseEvent): string[] | undefined =>
  event.image_url ? event.image_url.split('|') : undefined
```

It can never observe the backend's `||` re-join, so it is a **tautological
spec** — the banned "assert the mirror" pattern. Its own comment even states the
empty-string case "should not produce `[""]`", while testing only the mirror
that allows it.

## 5. History — latent, not a regression

| Change | PR | Date |
|--------|----|------|
| `insert_llm_histories.zig` `\|\|` join | #87 | 2026-07-11 |
| desktop single-pipe split | #527 | 2026-09-15 |
| `sendChatMessage` single-`\|` join | #557 | 2026-09-18 |

## 6. Proposed fix

### Step 1 — one shared tolerant splitter

```ts
// src/apps/desktop/src/helpers/mediaUrls.ts
export const splitMediaUrlsWire = (v?: string): string[] | undefined =>
  v ? v.split('|').filter((s) => s.length > 0) || undefined : undefined
```

Mirrors Android's `splitPipeDelimited` and `api/index.ts:824`. Tolerates `A|B`,
`A||B`, `A||B||C`, trailing `||`, and leading/trailing whitespace.

### Step 2 — use it at all six ChatView sites

`2151`, `2152`, `3799`, `3800`, `3887`, `3888` — `image_urls` **and** `video_urls`.

### Step 3 — canonicalise the send side to `||`

`api/index.ts:1662-1663` (`images.join('|')` → `images.join('||')`), plus Android
`ChatApi.kt:233` and `ChatViewModel.kt:1451` (`joinToString("|")` →
`joinToString("||")`). This makes the queue row and the `queue_queued` SSE frame
match the `||` contract the rest of the codebase already documents and validates
(`image_urls_validation.zig`, Migration 069 / 090, `create_kanban_task`).

### Step 4 — guard the renderer

Skip an empty `imgUrl` in the `v-for` so no future wire shape can produce
`<img src="">` again. Belt-and-braces on top of step 1.

### Step 5 — replace the tautological spec

Delete `src/apps/desktop/src/__tests__/sseImageUrls.spec.ts` and replace it with
a **behavioural** spec that feeds the payload the **real** backend encoder
produces (captured from step 6's Zig test) into the **real** production
splitter, asserting 2 entries and 0 empty.

### Step 6 — verification

1. **Zig test** — drive the real `insertLLMHistories` against an in-memory SQLite
   DB with a real `EventBus`, pass two image URLs, capture the emitted
   `llm_full` frame, assert `image_url` contains `||`. This pins the wire
   contract at its source.
2. **vitest** — feed that captured payload into the real `splitMediaUrlsWire`;
   assert `2` entries and `every(s => s.length > 0)`.
3. **Vue render test** — mount a user group with a 2-image message and assert
   `wrapper.findAll('img.chat-attached-image-img')` has length 2 and no
   `src=""`. This is the assertion that would have failed before the fix.
4. **Regression guard** — same for `video_urls`.

### Explicitly out of scope

Do **not** change `insert_llm_histories.zig:191` to join on a single `'|'`.
114 existing `llm_history` rows plus every `workspace_item_tasks.image_urls` row
are `||`-joined, and the backend read paths, the kanban wire format, the agent
tool schema and `http_response.zig` all assume `||`. The frontend is the outlier.