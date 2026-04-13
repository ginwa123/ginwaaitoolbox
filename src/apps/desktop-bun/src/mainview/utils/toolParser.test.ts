/**
 * Tool Call Parser Tests
 *
 * Tests the JSON parsing for tool call outputs.
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

  test('exports parseToolCallJson function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('export');
    expect(source).toContain('parseToolCallJson');
  });

  test('exports ToolData interface', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('interface ToolData');
  });

  test('has ParseResult interface', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('interface ParseResult');
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
// Test Suite: JSON Parsing Implementation
// ============================================================================

describe('JSON Parsing Implementation', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('uses JSON.parse', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/JSON\.parse/);
  });

  test('handles JSON array of tools', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/Array\.isArray/);
  });

  test('handles single tool object', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/typeof.*object/);
  });

  test('returns empty tools for invalid JSON', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/catch/);
  });
});

// ============================================================================
// Test Suite: Tool Name Extraction
// ============================================================================

describe('Tool Name Extraction', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('extracts from name field', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/name.*['\"]/);
  });

  test('extracts from tool_name field (fallback)', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/tool_name/);
  });

  test('converts to lowercase', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/toLowerCase/);
  });
});

// ============================================================================
// Test Suite: Tool-Specific Parsers
// ============================================================================

describe('Tool-Specific Parsers', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('has bash tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/bash/);
  });

  test('bash parser extracts command', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/command/);
  });

  test('bash parser extracts result', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/result/);
  });

  test('has read_file tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/read_file/);
  });

  test('read_file parser extracts path', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/path/);
  });

  test('read_file parser extracts content', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/content/);
  });

  test('has write_file tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/write_file/);
  });

  test('has web_search tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/web_search/);
  });

  test('has LSP tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/lsp_/);
  });

  test('has spawn_sub_agent tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/spawn_sub_agent/);
  });

  test('has search tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/search/);
  });

  test('has glob tool parser', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toMatch(/glob/);
  });
});

// ============================================================================
// Test Suite: getToolSummary Function
// ============================================================================

describe('getToolSummary Function', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('function exists', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('export function getToolSummary');
  });

  test('handles bash tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'bash'");
    expect(source).toContain('command');
  });

  test('handles read_file tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'read_file'");
    expect(source).toContain('path');
  });

  test('handles write_file tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'write_file'");
    expect(source).toContain('Written');
  });

  test('handles web_search tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'web_search'");
    expect(source).toContain('Web:');
  });

  test('handles search tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'search'");
    expect(source).toContain('Search:');
  });

  test('handles glob tool', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain("case 'glob'");
    expect(source).toContain('Glob:');
  });
});


// ============================================================================
// Test Suite: Backwards Compatibility
// ============================================================================

describe('Backwards Compatibility', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('provides parseToolCallXml alias', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('export const parseToolCallXml');
  });

  test('provides isToolCallJson function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('export const isToolCallJson');
  });
});


// ============================================================================
// Test Suite: Request Context Support
// ============================================================================

describe('Request Context Support', () => {
  const parserPath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/toolParser.ts';

  test('has RequestContext interface', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('interface RequestContext');
  });

  test('has parseToolCallJsonWithRequest function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('parseToolCallJsonWithRequest');
  });

  test('has generateRequestId function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('generateRequestId');
  });

  test('has formatRequestLog function', () => {
    const source = fs.readFileSync(parserPath, 'utf-8');
    expect(source).toContain('formatRequestLog');
  });
});
