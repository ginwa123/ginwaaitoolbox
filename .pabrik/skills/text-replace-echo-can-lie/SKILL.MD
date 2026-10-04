---
name: text-replace-echo-can-lie
description: "Use when an edit to a tracked file in this repo must be verified afterwards, because text_replace can echo conflict-marker or dropped-line diffs that were never written."
---
## When to Use
Any time you edit a file in this repo with `text_replace` and then rely on the
tool's own echo of the result to decide whether the edit landed. Twice in one
session the echo showed a change that was not in the file.

## Procedure
After every `text_replace` on a tracked file, confirm the working tree rather
than the tool output:

```bash
git diff --stat <file>          # line count must match what you intended
git diff <file> | head -n 40    # read the actual +/- lines
```

## Pitfalls
- The returned "unified" payload can render a synthetic
  `<<<<<<< BEFORE / ======= / >>>>>>> AFTER` block that was **never** written
  to disk. Treating that echo as file content wastes a turn and, worse, a
  follow-up `write_file` built from it would commit conflict markers.
- A `read_file` right after an edit can show fewer consecutive lines than it
  reports (`start_line`/`end_line` off by one), which reads like a deleted
  neighbour line. `git diff` is the only reliable check.
- Inserting a line echoes the surrounding context twice with a marker between;
  the second copy is not in the file.

