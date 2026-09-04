/**
 * Tests for toolOutputParser.ts — typed XML parsers used by tool-output components.
 *
 * Each parser handles missing tags gracefully. These tests verify the type
 * contracts and edge cases (empty content, missing required fields, multiline
 * values, special chars, both success/error branches).
 */
import { describe, expect, it } from 'vitest'
import {
  extractBool,
  extractInt,
  extractTag,
  parseAddSkill,
  parseBash,
  parseEditSkill,
  parseMcp,
  parsePwsh,
  parseListSkills,
  parseMetadata,
  parseNalarBrowser,
  parseReadFile,
  parseRemoveFile,
  parseRemoveSkill,
  parseSearch,
  parseSetGitWorktree,
  parseTextReplace,
  parseViewSkill,
  parseKanbanList,
  parseKanbanMove,
  parseGenerateImage,
  parseListDirectory,
  parseWriteFile,
} from '../toolOutputParser'

describe('extractTag', () => {
  it('returns inner text for single-line tags', () => {
    expect(extractTag('<path>/foo/bar</path>', 'path')).toBe('/foo/bar')
  })
  it('returns inner text for multiline tags (default)', () => {
    expect(extractTag('<content>\nfoo\nbar\n</content>', 'content')).toBe(
      '\nfoo\nbar\n',
    )
  })
  it('returns null for missing tag', () => {
    expect(extractTag('<path>/x</path>', 'other')).toBeNull()
  })
  it('returns null for unclosed tag', () => {
    expect(extractTag('<path>/x', 'path')).toBeNull()
  })
  it('handles content with HTML-like chars inside the tag', () => {
    expect(
      extractTag('<content>if (a < b && c > d) { x = 1 }</content>', 'content'),
    ).toBe('if (a < b && c > d) { x = 1 }')
  })
  it('decodes XML entities in inner text (&lt;, &gt;, &quot;, &apos;, &amp;)', () => {
    // The backend's `toXmlSuccess` / `xmlError` helpers escape these 5
    // characters on serialization. Without un-escaping, downstream
    // consumers (Vue templates, code-block renderers) would display
    // `&quot;` literally instead of `"` when the underlying text
    // contained those characters (e.g. a quote inside a source-code
    // diff). This test pins the un-escape contract so the
    // `&quot;`-instead-of-`"` rendering bug doesn't regress.
    expect(
      extractTag(
        '<before>const x = &quot;hello &amp; world &lt;3&quot;;</before>',
        'before',
      ),
    ).toBe('const x = "hello & world <3";')
    expect(extractTag('<a>&lt;tag&gt;</a>', 'a')).toBe('<tag>')
    expect(extractTag('<a>it&apos;s fine</a>', 'a')).toBe("it's fine")
  })
  it('decodes &amp; LAST to avoid double-decoding (e.g. &amp;quot; → &quot; not ")', () => {
    // `&amp;quot;` is a 6-byte sequence meaning "the literal entity
    // &quot;". If we decoded `&amp;` first, we'd incorrectly produce
    // `"` (because `&amp;quot;` → `&quot;` → `"` after both passes).
    // The correct decode is: `&amp;quot;` → `&quot;` (the literal 6
    // chars representing the entity). Order of regex passes matters.
    expect(extractTag('<a>&amp;quot;</a>', 'a')).toBe('&quot;')
    expect(extractTag('<a>&amp;amp;</a>', 'a')).toBe('&amp;')
  })
})

describe('extractBool', () => {
  it('returns true for <true>', () => {
    expect(extractBool('<x>true</x>', 'x')).toBe(true)
  })
  it('returns false for <false>', () => {
    expect(extractBool('<x>false</x>', 'x')).toBe(false)
  })
  it('returns defaultValue when tag missing', () => {
    expect(extractBool('<other>1</other>', 'x', false)).toBe(false)
    expect(extractBool('<other>1</other>', 'x', true)).toBe(true)
  })
  it('handles whitespace inside the tag value', () => {
    expect(extractBool('<x>  true  </x>', 'x')).toBe(true)
  })
})

describe('extractInt', () => {
  it('parses a valid integer', () => {
    expect(extractInt('<n>42</n>', 'n')).toBe(42)
  })
  it('returns null on missing tag', () => {
    expect(extractInt('<n>42</n>', 'other')).toBeNull()
  })
  it('returns null on non-numeric value', () => {
    expect(extractInt('<n>foo</n>', 'n')).toBeNull()
  })
  it('returns null on empty tag', () => {
    expect(extractInt('<n></n>', 'n')).toBeNull()
  })
  it('parses 0', () => {
    expect(extractInt('<n>0</n>', 'n')).toBe(0)
  })
})

describe('parseTextReplace', () => {
  it('parses a successful response with diff data', () => {
    const r = parseTextReplace(
      '<success>true</success><path>/foo</path><before>old</before><after>new</after><lines_changed>3</lines_changed>',
    )
    expect(r.path).toBe('/foo')
    expect(r.before).toBe('old')
    expect(r.after).toBe('new')
    expect(r.linesChanged).toBe(3)
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
  it('handles error response with null success', () => {
    const r = parseTextReplace('<success>false</success><error>not found</error>')
    expect(r.success).toBe(false)
    expect(r.error).toBe('not found')
    expect(r.path).toBe('')
    expect(r.linesChanged).toBe(0)
  })
  it('handles missing success tag (defaults to true)', () => {
    const r = parseTextReplace('<path>/foo</path>')
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
  it('extracts the unified diff when present', () => {
    const unified = '--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-old\n+new'
    const r = parseTextReplace(`<success>true</success><path>/x</path><unified>${unified}</unified>`)
    expect(r.unified).toBe(unified)
  })
})

describe('parseReadFile', () => {
  it('parses success with content and pagination', () => {
    const r = parseReadFile(
      '<success>true</success><path>/x</path><content>line1\nline2</content><total_lines>10</total_lines><start_line>1</start_line><end_line>2</end_line>',
    )
    expect(r.path).toBe('/x')
    expect(r.content).toBe('line1\nline2')
    expect(r.totalLines).toBe(10)
    expect(r.startLine).toBe(1)
    expect(r.endLine).toBe(2)
    expect(r.success).toBe(true)
  })
  it('returns null numeric fields when missing', () => {
    const r = parseReadFile('<success>true</success><path>/x</path>')
    expect(r.totalLines).toBeNull()
  })
  it('returns error when not success', () => {
    const r = parseReadFile(
      '<success>false</success><path>/x</path><error>permission denied</error>',
    )
    expect(r.error).toBe('permission denied')
    expect(r.success).toBe(false)
  })
})

describe('parseWriteFile', () => {
  it('parses <file_write>', () => {
    const r = parseWriteFile('<success>true</success><file_write>/x/y</file_write>')
    expect(r.path).toBe('/x/y')
    expect(r.success).toBe(true)
  })
  it('parses error', () => {
    const r = parseWriteFile('<success>false</success><error>disk full</error>')
    expect(r.path).toBe('')
    expect(r.error).toBe('disk full')
  })
})

describe('parseRemoveFile', () => {
  it('parses deleted=true', () => {
    const r = parseRemoveFile(
      '<path>/x</path><deleted>true</deleted>',
    )
    expect(r.deleted).toBe(true)
    expect(r.success).toBe(true)
  })
  it('parses recursive flag', () => {
    const r = parseRemoveFile(
      '<path>/x</path><deleted>true</deleted><recursive>true</recursive>',
    )
    expect(r.recursive).toBe(true)
  })
  it('handles failure', () => {
    const r = parseRemoveFile('<error>not found</error>')
    expect(r.deleted).toBe(false)
    expect(r.error).toBe('not found')
  })
})

describe('parseEditSkill', () => {
  it('parses edited=true', () => {
    const r = parseEditSkill('<name>auth</name><edited>true</edited><path>/skills/auth.md</path>')
    expect(r.skillName).toBe('auth')
    expect(r.edited).toBe(true)
    expect(r.path).toBe('/skills/auth.md')
  })
  it('returns path: null when missing', () => {
    const r = parseEditSkill('<name>x</name><edited>true</edited>')
    expect(r.path).toBeNull()
  })
})

describe('parseAddSkill', () => {
  it('parses created=true', () => {
    const r = parseAddSkill('<name>foo</name><created>true</created><path>/x</path>')
    expect(r.created).toBe(true)
    expect(r.skillName).toBe('foo')
  })
})

describe('parseRemoveSkill', () => {
  it('parses <skill_name> and removed', () => {
    const r = parseRemoveSkill(
      '<skill_name>foo</skill_name><removed>true</removed><path>/x</path>',
    )
    expect(r.skillName).toBe('foo')
    expect(r.removed).toBe(true)
  })
})

describe('parseViewSkill', () => {
  it('parses found=true with description', () => {
    const r = parseViewSkill(
      '<skill_name>foo</skill_name><description>does things</description><found>true</found>',
    )
    expect(r.found).toBe(true)
    expect(r.description).toBe('does things')
  })
  it('parses available_skills when not found', () => {
    const r = parseViewSkill(
      '<skill_name>foo</skill_name><found>false</found><available_skills><skill>a</skill><skill>b</skill></available_skills>',
    )
    expect(r.availableSkills).toEqual(['a', 'b'])
  })
})

describe('parseSetGitWorktree', () => {
  it('parses created=true with path and branch', () => {
    const r = parseSetGitWorktree(
      '<created>true</created><path>/.worktrees/auth</path><branch>worktree/auth</branch>',
    )
    expect(r.created).toBe(true)
    expect(r.path).toBe('/.worktrees/auth')
    expect(r.branch).toBe('worktree/auth')
  })
  it('parses cleared=true', () => {
    const r = parseSetGitWorktree('<cleared>true</cleared>')
    expect(r.cleared).toBe(true)
    expect(r.success).toBe(true)
  })
  it('returns success=false when neither created nor cleared', () => {
    const r = parseSetGitWorktree('<error>missing path</error>')
    expect(r.success).toBe(false)
  })
})

describe('parseBash', () => {
  it('parses a successful command with stdout', () => {
    const r = parseBash(
      '<command>ls</command><stdout>file1\nfile2</stdout><exit_code>0</exit_code><stdout_lines>2</stdout_lines>',
    )
    expect(r.command).toBe('ls')
    expect(r.stdout).toBe('file1\nfile2')
    expect(r.exitCode).toBe(0)
    expect(r.stdoutLines).toBe(2)
    expect(r.timedOut).toBe(false)
  })
  it('parses timeout flag', () => {
    const r = parseBash('<command>sleep 1</command><timeout>true</timeout>')
    expect(r.timedOut).toBe(true)
  })
  it('parses exit_code=null when not present', () => {
    const r = parseBash('<command>x</command>')
    expect(r.exitCode).toBeNull()
  })
})

describe('parseSearch', () => {
  it('parses file results with matches', () => {
    const r = parseSearch(
      '<file path="/foo/bar.ts" total="42" count="3"><match line="10" snippet="hello" /><match line="20" snippet="world" /></file>',
    )
    expect(r.fileResults).toHaveLength(1)
    const fr = r.fileResults[0]!
    expect(fr.path).toBe('/foo/bar.ts')
    expect(fr.total).toBe(42)
    expect(fr.count).toBe(3)
    expect(fr.matches).toEqual([
      { lineNumber: 10, snippet: 'hello' },
      { lineNumber: 20, snippet: 'world' },
    ])
  })
  it('decodes XML entities in snippet attribute', () => {
    const r = parseSearch(
      '<file path="/x" total="1" count="1"><match line="1" snippet="if a &amp;lt; b" /></file>',
    )
    expect(r.fileResults[0]?.matches[0]?.snippet).toBe('if a < b')
  })
  it('returns error when present (success=false)', () => {
    const r = parseSearch('<error>timeout</error>')
    expect(r.success).toBe(false)
    expect(r.error).toBe('timeout')
    expect(r.fileResults).toEqual([])
  })
})

describe('parseListSkills', () => {
  it('parses global + local skill blocks', () => {
    const r = parseListSkills(
      '<global_skills><skill><name>auth</name><description>handles auth</description><path>/g.md</path></skill></global_skills><local_skills><skill><name>x</name></skill></local_skills>',
    )
    expect(r.totalCount).toBe(2)
    expect(r.globalSkills).toHaveLength(1)
    expect(r.globalSkills[0]).toMatchObject({
      name: 'auth',
      description: 'handles auth',
      path: '/g.md',
    })
    expect(r.localSkills).toHaveLength(1)
  })
  it('returns totalCount=0 for empty content', () => {
    expect(parseListSkills('').totalCount).toBe(0)
  })
})

describe('parseNalarBrowser', () => {
  it('parses url and title', () => {
    const r = parseNalarBrowser('<success>true</success><url>https://x</url><title>X</title>')
    expect(r.url).toBe('https://x')
    expect(r.title).toBe('X')
  })
})

describe('parseKanbanList', () => {
  it('parses board label and column array', () => {
    const r = parseKanbanList(
      '<board>Sprint Board</board><column id="c1" name="Todo" task_count="5" /><column id="c2" name="Done" task_count="3" />',
    )
    expect(r.boardLabel).toBe('Sprint Board')
    expect(r.columns).toHaveLength(2)
    expect(r.columns[0]).toMatchObject({ id: 'c1', name: 'Todo', taskCount: 5 })
  })
  it('returns success=false on error', () => {
    const r = parseKanbanList('<error>not found</error>')
    expect(r.success).toBe(false)
    expect(r.columns).toEqual([])
  })
})

describe('parseKanbanMove', () => {
  it('parses move details', () => {
    const r = parseKanbanMove(
      '<board_id>b1</board_id><task_id>t1</task_id><from_column_id>c1</from_column_id><to_column_id>c2</to_column_id>',
    )
    expect(r.success).toBe(true)
    expect(r.fromColumnId).toBe('c1')
    expect(r.toColumnId).toBe('c2')
  })
})

describe('parseGenerateImage', () => {
  it('parses a single-image success envelope', () => {
    const r = parseGenerateImage(
      '<generate_image>' +
        '<status>generated</status>' +
        '<count>1</count>' +
        '<model>dall-e-3</model>' +
        '<size>1024x1024</size>' +
        '<images>' +
        '<image index="0" path="/cwd/img_123.png" bytes="12345" mime="image/png" />' +
        '</images>' +
        '<revised_prompt>A vibrant watercolor of a cat</revised_prompt>' +
        '</generate_image>',
    )
    expect(r.error).toBeNull()
    expect(r.status).toBe('generated')
    expect(r.count).toBe(1)
    expect(r.model).toBe('dall-e-3')
    expect(r.size).toBe('1024x1024')
    expect(r.images).toHaveLength(1)
    expect(r.images[0]).toMatchObject({
      index: 0,
      path: '/cwd/img_123.png',
      bytes: 12345,
      mime: 'image/png',
    })
    expect(r.revisedPrompt).toBe('A vibrant watercolor of a cat')
  })
  it('parses a multi-image (n>1, DALL-E 2) success envelope', () => {
    const r = parseGenerateImage(
      '<generate_image>' +
        '<status>generated</status>' +
        '<count>2</count>' +
        '<model>dall-e-2</model>' +
        '<size>512x512</size>' +
        '<images>' +
        '<image index="0" path="/cwd/img_a.png" bytes="100" mime="image/png" />' +
        '<image index="1" path="/cwd/img_b.png" bytes="200" mime="image/png" />' +
        '</images>' +
        '</generate_image>',
    )
    expect(r.error).toBeNull()
    expect(r.count).toBe(2)
    expect(r.images).toHaveLength(2)
    expect(r.images[0]?.path).toBe('/cwd/img_a.png')
    expect(r.images[1]?.path).toBe('/cwd/img_b.png')
    expect(r.revisedPrompt).toBeNull()
  })
  it('returns the error message and null fields on error', () => {
    const r = parseGenerateImage(
      '<generate_image><error>HTTP 400: size \'512x512\' is not valid for model \'dall-e-3\'.</error></generate_image>',
    )
    expect(r.error).toBe(
      "HTTP 400: size '512x512' is not valid for model 'dall-e-3'.",
    )
    expect(r.status).toBeNull()
    expect(r.images).toEqual([])
    expect(r.count).toBeNull()
  })
  it('handles empty content gracefully', () => {
    const r = parseGenerateImage('')
    expect(r.error).toBeNull()
    expect(r.status).toBeNull()
    expect(r.images).toEqual([])
  })
})

describe('parseMetadata', () => {
  it('flattens a <metadata> block into key/value pairs', () => {
    const r = parseMetadata(
      '<metadata><session_id>s1</session_id><model>m1</model><count>3</count></metadata>',
    )
    expect(r.session_id).toBe('s1')
    expect(r.model).toBe('m1')
    expect(r.count).toBe('3')
  })
  it('returns empty object when no metadata block', () => {
    expect(parseMetadata('<other>foo</other>')).toEqual({})
  })
})

// 2026-08-14 — list_directory tool output (companion to ReadFile/Search/Glob).
// Wire shape (from src/modules/agent/tools/list_directory.zig):
//
//   <directory_listing path="/foo/bar" count="3">
//     <directory name="src" path="/foo/bar/src" is_symlink="false"/>
//     <file name="main.zig" path="/foo/bar/main.zig" is_symlink="false"/>
//   </directory_listing>
//
// On error (innerToolData falls back to the full <tool> envelope, so the
// parser must tolerate the outer wrapper too):
//
//   <tool><name>list_directory</name><parameters>...</parameters>
//   <success>false</success><error>list_directory failed: PathNotFound</error>
//   </tool>
describe('parseListDirectory', () => {
  it('parses a success envelope with directories + files', () => {
    const r = parseListDirectory(
      '<directory_listing path="/proj" count="3">' +
        '<directory name="src" path="/proj/src" is_symlink="false"/>' +
        '<file name="README.md" path="/proj/README.md" is_symlink="false"/>' +
        '<file name="main.zig" path="/proj/main.zig" is_symlink="false"/>' +
        '</directory_listing>',
    )
    expect(r.path).toBe('/proj')
    expect(r.count).toBe(3)
    expect(r.entries).toHaveLength(3)
    expect(r.entries[0]).toMatchObject({
      name: 'src',
      path: '/proj/src',
      isDirectory: true,
      isSymlink: false,
    })
    expect(r.entries[1]).toMatchObject({
      name: 'README.md',
      path: '/proj/README.md',
      isDirectory: false,
      isSymlink: false,
    })
    expect(r.entries[2]?.name).toBe('main.zig')
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })

  it('parses an empty directory listing (count=0)', () => {
    const r = parseListDirectory('<directory_listing path="/empty" count="0"></directory_listing>')
    expect(r.path).toBe('/empty')
    expect(r.count).toBe(0)
    expect(r.entries).toEqual([])
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })

  it('parses a directory-only listing', () => {
    const r = parseListDirectory(
      '<directory_listing path="/only-dirs" count="2">' +
        '<directory name="a" path="/only-dirs/a" is_symlink="false"/>' +
        '<directory name="b" path="/only-dirs/b" is_symlink="false"/>' +
        '</directory_listing>',
    )
    expect(r.count).toBe(2)
    expect(r.entries.every((e) => e.isDirectory)).toBe(true)
  })

  it('flags symlinks via is_symlink="true"', () => {
    const r = parseListDirectory(
      '<directory_listing path="/proj" count="1">' +
        '<file name="link.txt" path="/proj/link.txt" is_symlink="true"/>' +
        '</directory_listing>',
    )
    expect(r.entries[0]?.isSymlink).toBe(true)
    expect(r.entries[0]?.isDirectory).toBe(false)
  })

  it('returns success=false + error message on error envelope', () => {
    // innerToolData falls back to m.content (the full <tool> envelope)
    // when the backend errored out. The parser must still find the
    // <error> tag in the outer envelope.
    const r = parseListDirectory(
      '<tool><name>list_directory</name><parameters>{"path":"/missing"}</parameters>' +
        '<success>false</success>' +
        '<error>list_directory failed: PathNotFound</error>' +
        '</tool>',
    )
    expect(r.success).toBe(false)
    expect(r.error).toBe('list_directory failed: PathNotFound')
    expect(r.entries).toEqual([])
  })

  it('handles empty content gracefully (no envelope at all)', () => {
    const r = parseListDirectory('')
    expect(r.path).toBe('')
    expect(r.count).toBe(0)
    expect(r.entries).toEqual([])
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
})

// 2026-08-14 pwsh-tool: parsePwsh mirrors parseBash (same XML envelope per
// D2 + D10). Wire-contract parity test.
describe('parsePwsh', () => {
  const envelope =
    '<command>Get-ChildItem</command>' +
    '<stdout>file1\nfile2</stdout>' +
    '<stderr></stderr>' +
    '<exit_code>0</exit_code>' +
    '<truncated>false</truncated>' +
    '<timeout>false</timeout>' +
    '<stdout_lines>2</stdout_lines>' +
    '<stderr_lines>0</stderr_lines>' +
    '<is_self>false</is_self>'

  it('parses a PowerShell command result with the same shape as parseBash', () => {
    const r = parsePwsh(envelope)
    expect(r.command).toBe('Get-ChildItem')
    expect(r.stdout).toBe('file1\nfile2')
    expect(r.exitCode).toBe(0)
    expect(r.truncated).toBe(false)
    expect(r.timedOut).toBe(false)
    expect(r.stdoutLines).toBe(2)
    expect(r.stderrLines).toBe(0)
    expect(r.isSelf).toBe(false)
  })

  it('returns the same ParsedBash shape as parseBash for the same input', () => {
    // Lock-down test: pwsh + bash share the wire envelope. If a future
    // refactor diverges them, this assertion fails closed.
    expect(parsePwsh(envelope)).toEqual(parseBash(envelope))
  })
})

describe('parseMcp', () => {
  it('splits mcp_<server>_<tool> into server + subTool', () => {
    const r = parseMcp('mcp_graphify_graph_stats', 'Nodes: 14885')
    expect(r.server).toBe('graphify')
    expect(r.subTool).toBe('graph_stats')
    expect(r.output).toBe('Nodes: 14885')
    expect(r.success).toBe(true)
  })

  it('keeps multi-underscore sub-tools intact (mcp_db_query_v2)', () => {
    const r = parseMcp('mcp_db_query_v2', 'ok')
    expect(r.server).toBe('db')
    expect(r.subTool).toBe('query_v2')
  })

  it('pretty-prints JSON output', () => {
    const r = parseMcp('mcp_db_query', '{"a":1,"b":[1,2]}')
    expect(r.isJson).toBe(true)
    expect(r.prettyOutput).toBe(JSON.stringify({ a: 1, b: [1, 2] }, null, 2))
  })

  it('unwraps the error envelope (backend failure path)', () => {
    const envelope =
      '<tool><name>mcp_graphify_graph_stats</name>' +
      '<parameters>{}</parameters><success>false</success>' +
      '<error>connection refused</error><data></data></tool>'
    const r = parseMcp('mcp_graphify_graph_stats', envelope)
    expect(r.success).toBe(false)
    expect(r.error).toBe('connection refused')
    expect(r.output).toBe('')
  })

  it('unwraps the success <data> envelope (placeholder shape)', () => {
    const envelope =
      '<tool><name>mcp_db_query</name>' +
      '<parameters>{"q":"1"}</parameters><success>true</success>' +
      '<data>row1</data></tool>'
    const r = parseMcp('mcp_db_query', envelope)
    expect(r.success).toBe(true)
    expect(r.output).toBe('row1')
  })
})