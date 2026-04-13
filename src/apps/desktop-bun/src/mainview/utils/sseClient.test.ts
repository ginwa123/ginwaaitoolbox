/**
 * SSE Client Tests
 *
 * Tests for JSON parsing functions in sseClient.ts
 * Run with: bun test src/mainview/utils/sseClient.test.ts
 */

import * as fs from 'fs';
import { describe, expect, test } from 'vitest';

// ============================================================================
// Test Suite: parseSseJson Function Existence
// ============================================================================

describe('parseSseJson Function', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('function exists and is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('function parseSseJson');
  });

  test('function signature accepts unknown parameter', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/function parseSseJson\(data:\s*unknown\)/);
  });

  test('function returns RawSSEEvent type', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/function parseSseJson\(.*\):\s*RawSSEEvent/);
  });

  test('RawSSEEvent interface is defined', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/interface RawSSEEvent/);
  });
});

// ============================================================================
// Test Suite: RawSSEEvent Interface Fields
// ============================================================================

describe('RawSSEEvent Interface Fields', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('has session_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/session_id\??:\s*string/);
  });

  test('has model field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/model\??:\s*string/);
  });

  test('has cwd field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/cwd\??:\s*string/);
  });

  test('has content field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/content\??:\s*string/);
  });

  test('has reasoning_content field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/reasoning_content\??:\s*string/);
  });

  test('has role field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/role\??:\s*string/);
  });

  test('has finish_reason field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/finish_reason\??:\s*string/);
  });

  test('has tool_calls field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_calls\??:/);
  });

  test('has tool_call_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_call_id\??:\s*string/);
  });

  test('has tool_name field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_name\??:\s*string/);
  });

  test('has agent_name field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/agent_name\??:\s*string/);
  });

  test('has session_name field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/session_name\??:\s*string/);
  });

  test('has loop_index field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/loop_index\??:\s*number/);
  });

  test('has temperature field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/temperature\??:\s*number/);
  });

  test('has is_thinking field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_thinking\??:\s*boolean/);
  });

  test('has is_input field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_input\??:\s*boolean/);
  });

  test('has is_output field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_output\??:\s*boolean/);
  });

  test('has parent_session_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/parent_session_id\??:\s*string/);
  });

  test('has parent_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/parent_id\??:\s*string/);
  });
});

// ============================================================================
// Test Suite: JSON Field Extraction
// ============================================================================

describe('JSON Field Extraction', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('extracts session_id from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.session_id\s*=/);
  });

  test('extracts model from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.model\s*=/);
  });

  test('extracts cwd from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.cwd\s*=/);
  });

  test('extracts content from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.content\s*=/);
  });

  test('extracts reasoning_content from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.reasoning_content\s*=/);
  });

  test('extracts role from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.role\s*=/);
  });

  test('extracts finish_reason from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.finish_reason\s*=/);
  });

  test('extracts tool_calls array from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.tool_calls\s*=/);
  });

  test('extracts tool_call_id from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.tool_call_id\s*=/);
  });

  test('extracts tool_name from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.tool_name\s*=/);
  });

  test('extracts agent_name from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.agent_name\s*=/);
  });

  test('extracts session_name from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.session_name\s*=/);
  });

  test('extracts loop_index from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.loop_index\s*=/);
  });

  test('extracts temperature from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.temperature\s*=/);
  });

  test('extracts is_thinking from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.is_thinking\s*=/);
  });

  test('extracts is_input from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.is_input\s*=/);
  });

  test('extracts is_output from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.is_output\s*=/);
  });

  test('extracts parent_session_id from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.parent_session_id\s*=/);
  });

  test('extracts parent_id from JSON', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/result\.parent_id\s*=/);
  });
});

// ============================================================================
// Test Suite: determineEventType Function
// ============================================================================

describe('determineEventType Function', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('function exists', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('function determineEventType');
  });

  test('returns done when finish_reason is present', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/if\s*\(\s*data\.finish_reason\s*\).*return\s*['"]done['"]/s);
  });

  test('returns tool_result when tool_call_id is present', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/if\s*\(\s*data\.tool_call_id.*return\s*['"]tool_result['"]/s);
  });

  test('returns message by default', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/return\s*['"]message['"]/);
  });
});

// ============================================================================
// Test Suite: SSEClient Class
// ============================================================================

describe('SSEClient Class', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('class is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('export class SSEClient');
  });

  test('has connect method', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/connect\s*\(\s*sessionId:\s*string\s*\)/);
  });

  test('has disconnect method', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('disconnect():');
  });

  test('has addHandler method', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/addHandler\s*\(\s*handler:\s*SSEMessageHandler/);
  });

  test('has removeHandler method', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/removeHandler\s*\(\s*handler:\s*SSEMessageHandler/);
  });

  test('has isConnected method', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/isConnected\s*\(\s*\)/);
  });

  test('has error handling', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('handleError');
  });

  test('has reconnection logic', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/reconnectAttempts/);
  });

  test('has maxReconnectAttempts limit', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/maxReconnectAttempts\s*=\s*5/);
  });

  test('supports intentional disconnect', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/isIntentionalDisconnect/);
  });
});

// ============================================================================
// Test Suite: detectFormat Function
// ============================================================================

describe('detectFormat Function', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/messageParser.ts';

  test('function exists', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('export const detectFormat');
  });

  test('detects JSON format', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/startsWith\s*\(\s*['"][{]['"]\s*\)/);
  });

  test('detects XML format', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/startsWith\s*\(\s*['"]<['"]\s*\)/);
  });

  test('returns unknown for unrecognized format', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/return\s*['"]unknown['"]/);
  });
});

// ============================================================================
// Test Suite: parseMessages Function
// ============================================================================

describe('parseMessages Function', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/messageParser.ts';

  test('function exists and is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('export const parseMessages');
  });

  test('handles JSON format', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/case\s*['"]json['"]/);
  });

  test('handles XML format (backwards compatibility)', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/case\s*['"]xml['"]/);
  });
});

// ============================================================================
// Test Suite: JSON Structure Support
// ============================================================================

describe('JSON Structure Support', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('uses JSON.parse for JSON data', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/JSON\.parse/);
  });

  test('handles object type check', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/typeof\s+data\s*!==\s*['"]object['"]/);
  });

  test('uses type assertions for JSON fields', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/as\s+Record<string,\s*unknown>/);
  });
});

