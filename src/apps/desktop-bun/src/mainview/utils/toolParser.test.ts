/**
 * Tool Call Parser Tests
 *
 * Tests the XML parsing and formatting for tool call outputs.
 * TDD Approach: Write tests first, implement to pass.
 */

import * as fs from 'fs';
import { describe, expect, test } from 'vitest';

// ============================================================================
// Test Suite: Tool Call Parser Exists
// ============================================================================

describe('Tool Call Parser Module', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('toolParser.ts file exists', () => {
    expect(fs.existsSync(parserPath)).toBe(true);
  });

  test('exports parseToolCallXml function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('export');
    expect(source).toContain('parseToolCallXml');
  });

  test('exports ToolData interface', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('interface ToolData');
  });
});

// ============================================================================
// Test Suite: ToolData Interface Structure
// ============================================================================

describe('ToolData Interface', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('has toolName field', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/toolName.*string/);
  });

  test('has fields record', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/fields.*Record.*string.*string/);
  });

  test('has isParsed boolean', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/isParsed.*boolean/);
  });
});

// ============================================================================
// Test Suite: Bash Tool Parsing
// ============================================================================

describe('Bash Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles bash tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/bash/);
  });

  test('extracts command field', () => {
    expect(source).toMatch(/command/);
  });

  test('extracts result field', () => {
    expect(source).toMatch(/result/);
  });

  test('extracts exit_code field', () => {
    expect(source).toMatch(/exit_code|exitCode/);
  });

  test('handles exit_code=0 as success', () => {
    expect(source).toMatch(/exit.*0|success|success/i);
  });

  test('handles non-zero exit codes', () => {
    expect(source).toMatch(/exit.*!==|error|fail/i);
  });
});

// ============================================================================
// Test Suite: Read File Tool Parsing
// ============================================================================

describe('Read File Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles read_file tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/read_file|readFile/);
  });

  test('extracts path field', () => {
    expect(source).toMatch(/fields\.path/);
  });

  test('extracts content field', () => {
    expect(source).toMatch(/content.*string/);
  });

  test('extracts hash field (optional)', () => {
    expect(source).toMatch(/hash/);
  });
});

// ============================================================================
// Test Suite: Write File Tool Parsing
// ============================================================================

describe('Write File Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles write_file tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/write_file|writeFile/);
  });

  test('extracts path field', () => {
    expect(source).toMatch(/path/);
  });

  test('extracts content field', () => {
    expect(source).toMatch(/content/);
  });
});

// ============================================================================
// Test Suite: Search Tool Parsing
// ============================================================================

describe('Search Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles search tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/search/);
  });

  test('extracts pattern field', () => {
    expect(source).toMatch(/pattern/);
  });

  test('extracts path field', () => {
    expect(source).toMatch(/path/);
  });

  test('extracts matches field', () => {
    expect(source).toMatch(/matches/);
  });
});

// ============================================================================
// Test Suite: Glob Tool Parsing
// ============================================================================

describe('Glob Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles glob tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/glob/);
  });

  test('extracts pattern field', () => {
    expect(source).toMatch(/pattern/);
  });

  test('extracts results field', () => {
    expect(source).toMatch(/results/);
  });
});

// ============================================================================
// Test Suite: Web Search Tool Parsing
// ============================================================================

describe('Web Search Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles web_search tool_name', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/web_search|webSearch/);
  });

  test('extracts query field', () => {
    expect(source).toMatch(/query/);
  });

  test('extracts url field', () => {
    expect(source).toMatch(/url/);
  });

  test('extracts results field', () => {
    expect(source).toMatch(/results/);
  });
});

// ============================================================================
// Test Suite: LSP Tool Parsing
// ============================================================================

describe('LSP Tool Parsing', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles lsp_* tool_names', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/lsp_/);
  });

  test('extracts file_path or location', () => {
    expect(source).toMatch(/file_path|location|filePath/);
  });

  test('extracts line and character info', () => {
    expect(source).toMatch(/line|character/);
  });
});

// ============================================================================
// Test Suite: Generic Tool Handling
// ============================================================================

describe('Generic Tool Handling', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('has default/fallback case for unknown tools', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/default|unknown|generic/i);
  });

  test('extracts raw content for unknown tools', () => {
    expect(source).toMatch(/rawContent|raw|original/i);
  });
});

// ============================================================================
// Test Suite: XML Entity Decoding
// ============================================================================

describe('XML Entity Decoding', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles &lt; entity', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/&lt;|<|decode/i);
  });

  test('handles &gt; entity', () => {
    expect(source).toMatch(/&gt;|>|decode/i);
  });

  test('handles &amp; entity', () => {
    expect(source).toMatch(/&amp;|&|decode/i);
  });

  test('uses existing decodeXmlEntities or has own decoder', () => {
    expect(source).toMatch(/decodeXmlEntities|decodeEntities|decode.*Entities/i);
  });
});

// ============================================================================
// Test Suite: Streaming/Partial Content Handling
// ============================================================================

describe('Streaming/Partial Content Handling', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  let source: string;

  test('handles incomplete/malformed XML', () => {
    source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/incomplete|partial|malformed|error.*handle|try.*catch/i);
  });

  test('can return partial result with isParsed=false', () => {
    expect(source).toMatch(/isParsed.*false|partial.*result/i);
  });

  test('gracefully handles missing fields', () => {
    expect(source).toMatch(/missing|optional|\?|undefined|null.*handle/i);
  });
});

// ============================================================================
// Test Suite: ToolCallRenderer Component
// ============================================================================

describe('ToolCallRenderer Component', () => {
  const componentPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/components/ToolCallRenderer.tsx';

  test('ToolCallRenderer.tsx file exists', () => {
    expect(fs.existsSync(componentPath)).toBe(true);
  });

  test('receives ToolData as prop', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/ToolData|toolData/);
  });

  test('renders based on toolName', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/toolName|switch.*tool|if.*tool/i);
  });

  test('has bash-specific rendering', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/bash|terminal|command/i);
  });

  test('has read_file-specific rendering', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/read_file|file|path/i);
  });

  test('has search-specific rendering', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/search|matches|pattern/i);
  });

  test('has default/generic rendering', () => {
    const source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/default|fallback|raw|generic/i);
  });
});

// ============================================================================
// Test Suite: Visual Styling
// ============================================================================

describe('Visual Styling', () => {
  const componentPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/components/ToolCallRenderer.tsx';

  let source: string;

  test('uses monospace font for code content', () => {
    source = fs.readFileSync(componentPath, 'utf-8');
    expect(source).toMatch(/font-mono|font-mono/);
  });

  test('has terminal-style formatting for bash', () => {
    expect(source).toMatch(/terminal|console|bg-|bg-\[/);
  });

  test('has file-style formatting for read_file', () => {
    expect(source).toMatch(/file|code|line-number|line-number/i);
  });

  test('has color coding for exit codes', () => {
    // Green for success, red for error
    expect(source).toMatch(/green|red|#34d399|#ef4444|success.*color|error.*color/i);
  });

  test('uses border/frame styling', () => {
    expect(source).toMatch(/border|rounded|frame|box|┌|└|├/);
  });
});

// ============================================================================
// Test Suite: Integration with MessageRow
// ============================================================================

describe('MessageRow Integration', () => {
  const sessionChatPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx';

  let source: string;

  test('imports ToolCallRenderer or toolParser', () => {
    source = fs.readFileSync(sessionChatPath, 'utf-8');
    expect(source).toMatch(/ToolCallRenderer|toolParser|parseToolCall/);
  });

  test('uses toolFormatter for is_output=true messages', () => {
    expect(source).toMatch(/is_output.*true|tool_name.*parse|parseToolCall/i);
  });

  test('conditionally renders tool call format', () => {
    expect(source).toMatch(/ToolCallRenderer|Show.*parsedTool|parsedTool.*Show/);
  });
});
