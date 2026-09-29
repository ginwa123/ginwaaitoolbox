# The type scale

There is exactly one list of font sizes and one list of font weights in
this app. Both live in the `@theme` block of
`src/apps/desktop/src/style.css` and nowhere else.

That is the whole point. Before this existed the app carried **nine**
hand-rolled font sizes — `9px`, `10px`, `0.6rem`, `0.65rem`, `11px`,
`0.7rem`, `0.72rem`, `0.8rem`, `13px` — which is four different spellings
of "about 10px" and two of "about 11px", mixed with Tailwind's own
`xs/sm/base/...` ladder. Nothing asserted a measurement, so every new
component was free to invent a tenth. Two components sitting side by side
rounded differently and nothing failed.

## The scale

| Class | px | Use it for |
| --- | --- | --- |
| `text-micro` | 10 | counts, badges, timestamps, section titles |
| `text-meta` | 11 | secondary metadata, icon/glyph size |
| `text-dense` | 12 | **the default UI text** — tool output, table cells, sidebar rows |
| `text-body` | 14 | dialog copy, prose, form fields |
| `text-lead` | 16 | one step up from body: emphasis, pull-quotes |
| `text-title-sm` | 18 | |
| `text-title` | 20 | card and panel headings |
| `text-title-lg` | 24 | page headings, empty-state headlines |
| `text-display` | 30 | hero, big numerals |
| `text-display-lg` | 36 | |

Weights: `font-normal` 400 · `font-medium` 500 (the default for anything
interactive) · `font-semibold` 600 (a label that has to win against its
neighbours) · `font-bold` 700 (a number read at a glance).

## The rules

1. **Pick a step by role, not by pixel.** `text-dense` means "a cell in a
   tool output table" the same way `text-title` means "a panel heading".
   The role survives a retune; the pixel value does not. That is why the
   steps are named micro/meta/dense/body/lead instead of xs/sm/base.
2. **Never write a raw length in a class.** `text-[11px]`, `text-[0.65rem]`
   and friends are all banned. Pick the step.
3. **Never use a bare Tailwind size.** `text-xs` and friends still exist
   (Tailwind ships them) but they are off-scale: change the ramp and those
   elements silently keep the old pixel value. That is the failure the
   numeric ladder was hiding.
4. **The left sidebar has no private scale.** It used to keep its own four
   `--sb-fs-*` tokens. Two lists of font sizes drift — that is the bug this
   page documents. The sidebar now picks steps off this table like
   everything else; `--sb-*` is left holding geometry only (gutter, row
   height, indent, hit box).

## How it is enforced

`src/__tests__/type-scale.spec.ts` fails the build when a component grows
a raw font size, reaches for a bare Tailwind size, or uses a weight that
is not on the ladder — with the file and line in the failure message.
`src/__tests__/Sidebar.spacing.spec.ts` adds the narrower rule that no
sidebar row may be larger than the step the rows use.

Both are source-contract tests on purpose. A screenshot pixel-diff fails
on a 1px antialiasing change and passes on a 14px indent regression.

## Retuning the whole app

Change the value in `style.css` and the matching line in `type-scale.spec.ts`
(which is the spec — it is the list of steps *and* their pixel values).
One edit, every component follows. Note that some values on the scale were
collapsed during the migration (`0.65rem` 10.4px → `text-micro` 10px,
`0.72rem` 11.5px → `text-meta` 11px, `13px` → `text-dense` 12px), so a
retune will move those elements slightly the first time.
