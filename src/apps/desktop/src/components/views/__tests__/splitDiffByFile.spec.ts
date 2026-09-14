import { describe, expect, it } from 'vitest'
import { splitDiffByFile } from '../chat_right_sidebar/parseUnifiedDiff'

const MULTI = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1 +1 @@
-old
+new
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index abc1234..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/old.txt b/new2.txt
similarity index 90%
rename from old.txt
rename to new2.txt
index 123..456 100644
--- a/old.txt
+++ b/new2.txt
@@ -1 +1 @@
 x
+y`

describe('splitDiffByFile', () => {
  it('splits multi-file diffs with paths', () => {
    const files = splitDiffByFile(MULTI)
    expect(files.map((f) => f.path)).toEqual(['foo.txt', 'new.txt', 'gone.txt', 'new2.txt'])
  })

  it('derives M/A/D/R status from headers', () => {
    const files = splitDiffByFile(MULTI)
    expect(files.map((f) => f.status)).toEqual(['M', 'A', 'D', 'R'])
  })

  it('keeps each chunk self-contained for parseUnifiedDiff', () => {
    const files = splitDiffByFile(MULTI)
    expect(files[0]!.text).toContain('@@ -1 +1 @@')
    expect(files[1]!.text).toContain('new file mode')
  })

  it('returns [] for empty diff', () => {
    expect(splitDiffByFile('')).toEqual([])
    expect(splitDiffByFile('   \n  ')).toEqual([])
  })
})
