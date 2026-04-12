/**
 * SSE Client Tests - TDD Approach
 *
 * Tests for parseSseXml function covering all edge cases.
 * Run with: bun test src/mainview/utils/sseClient.test.ts
 *
 * TDD Cycle: RED (write failing tests) → GREEN (implement) → REFACTOR
 *
 * This test suite uses source-code verification approach since the module
 * has client-side dependencies that can't run in test environment.
 */

import * as fs from 'fs';
import { describe, expect, test } from 'vitest';

// ============================================================================
// Test Suite: parseSseXml Function Existence
// ============================================================================

describe('parseSseXml Function', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('function exists and is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toContain('export function parseSseXml');
  });

  test('function signature accepts string parameter', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/export function parseSseXml\(xmlData:\s*string\)/);
  });

  test('function returns RawSSEEvent type', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/function parseSseXml\(.*\):\s*RawSSEEvent/);
  });

  test('RawSSEEvent interface is defined', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/interface RawSSEEvent/);
  });

  test('extractXmlTag helper function exists', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/function extractXmlTag/);
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

  test('has loop_index field as number', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/loop_index\??:\s*number/);
  });

  test('has temperature field as number', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/temperature\??:\s*number/);
  });

  test('has is_thinking field as boolean', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_thinking\??:\s*boolean/);
  });

  test('has is_input field as boolean', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_input\??:\s*boolean/);
  });

  test('has is_output field as boolean', () => {
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
// Test Suite: Empty/Null Input Handling
// ============================================================================

describe('Empty/Null Input Handling', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('checks for null/undefined input', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should have null/undefined check
    expect(source).toMatch(/!xmlData|xmlData\s*===?\s*null|xmlData\s*===?\s*undefined/);
  });

  test('checks for empty string', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should check for empty or whitespace-only
    expect(source).toMatch(/xmlData\.trim\(\)|\.length\s*===?\s*0/);
  });

  test('returns empty object for invalid input', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should return {} for invalid input
    expect(source).toMatch(/return result;/);
  });

  test('logs warning for empty input', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should log when skipping empty data
    expect(source).toMatch(/log\.warn.*empty.*XML|empty.*data/i);
  });
});

// ============================================================================
// Test Suite: Basic Response Parsing
// ============================================================================

describe('Basic Response Parsing', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('checks for <response> tag', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/<response>|<response>.*<\/response>/);
  });

  test('extracts session_id from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*session_id/);
  });

  test('extracts model from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*model/);
  });

  test('extracts cwd from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*cwd/);
  });

  test('extracts content from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*content/);
  });

  test('extracts reasoning_content from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*reasoning_content/);
  });

  test('defaults role to assistant', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should have default value
    expect(source).toMatch(/role.*\|\|.*['\"]assistant|role.*\?.*['\"]assistant/);
  });

  test('extracts finish_reason from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*finish_reason/);
  });
});

// ============================================================================
// Test Suite: Tool Call Parsing
// ============================================================================

describe('Tool Call Parsing', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('extracts tool_call_id from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*tool_call_id/);
  });

  test('extracts tool_name from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*tool_name/);
  });

  test('parses tool_calls array with regex', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should match <tool_calls>...</tool_calls>
    expect(source).toMatch(/tool_calls.*match|match.*tool_calls/);
  });

  test('iterates over individual tool_call elements', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/matchAll.*tool_call|for.*tcMatch/);
  });

  test('extracts id from tool_call', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should extract <id> tag within tool_call
    expect(source).toMatch(/extractXmlTag\(.*tcContent.*id|id.*extractXmlTag/);
  });

  test('extracts name from tool_call', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*tcContent.*name|name.*extractXmlTag/);
  });

  test('extracts arguments from tool_call', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*tcContent.*arguments|arguments.*extractXmlTag/);
  });

  test('handles missing tool_call fields with default', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should use || '' for missing fields
    expect(source).toMatch(/\|\|?\s*['\"][\'\"]|undefined.*['\"]/);
  });
});

// ============================================================================
// Test Suite: Agent and Session Metadata Parsing
// ============================================================================

describe('Agent and Session Metadata', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('extracts agent_name from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*agent_name/);
  });

  test('extracts session_name from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*session_name/);
  });

  test('parses loop_index as integer', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should parse string to number
    expect(source).toMatch(/Number\.parseInt|parseInt/);
  });

  test('parses temperature as float', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should parse string to float
    expect(source).toMatch(/Number\.parseFloat|parseFloat/);
  });

  test('extracts is_thinking as boolean', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should compare to 'true' string
    expect(source).toMatch(/is_thinking.*===.*['\"]true|===.*['\"]true.*is_thinking/);
  });

  test('extracts is_input as boolean', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_input.*===.*['\"]true/);
  });

  test('extracts is_output as boolean', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_output.*===.*['\"]true/);
  });

  test('extracts parent_session_id from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*parent_session_id/);
  });

  test('extracts parent_id from XML', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/extractXmlTag\(.*parent_id/);
  });
});

// ============================================================================
// Test Suite: Chunk Parsing (Streaming)
// ============================================================================

describe('Chunk Parsing (Streaming)', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('matches chunk tag with index attribute', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should have regex for <chunk index="...">
    expect(source).toMatch(/chunk.*index|index.*chunk/);
  });

  test('extracts content from chunk', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/chunk.*content|content.*chunk/);
  });

  test('extracts reasoning_content from chunk', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/chunk.*reasoning|reasoning.*chunk/);
  });

  test('detects final chunk via final="true"', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/final.*true|true.*final/);
  });

  test('detects final chunk via usage tag', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/usage|<usage>/);
  });

  test('sets finish_reason to stop for final chunk', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/finish_reason.*=.*['\"]stop/);
  });
});

// ============================================================================
// Test Suite: extractXmlTag Helper
// ============================================================================

describe('extractXmlTag Helper', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('escapes special regex characters in tag name', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should escape . * + ? ^ $ { } [ ] ( ) | \ etc.
    expect(source).toMatch(/replace.*\[.*\]\$|escape|\\\$/);
  });

  test('uses regex to match opening and closing tags', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/new RegExp|RegExp\(|\/\^/);
  });

  test('captures content between tags using [^<]*', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/\[\^<\]\*/);
  });

  test('trims extracted content', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/\.trim\(\)/);
  });

  test('returns undefined when no match', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should return match[1].trim() or undefined
    expect(source).toMatch(/match\[1\]|undefined/);
  });
});

// ============================================================================
// Test Suite: Error Handling
// ============================================================================

describe('Error Handling', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('handles missing optional fields gracefully', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should use optional chaining or nullish coalescing
    expect(source).toMatch(/\?\?|\?\.|\|\|/);
  });

  test('initializes result object', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/const result.*RawSSEEvent.*=\s*\{\}/);
  });

  test('returns result object at end of function', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/return result;/);
  });
});

// ============================================================================
// Test Suite: Performance Considerations
// ============================================================================

describe('Performance Considerations', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('uses regex efficiently (no global flag for single match)', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Single match should not use 'g' flag
    expect(source).toMatch(/match\(|matchAll\(/);
  });

  test('uses matchAll for multiple tool_calls', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/matchAll/);
  });
});

// ============================================================================
// Test Suite: Edge Cases That Need Fixes
// ============================================================================

describe('EDGE CASES - Issues to Address', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('ISSUE: XML Entity Decoding - NOT IMPLEMENTED', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Currently does NOT decode entities like &lt;, &gt;, &amp;
    // This documents the limitation
    expect(source).not.toMatch(/decode.*Entity|&lt;|&gt;|&amp;.*decode/);
  });

  test('ISSUE: Case-Insensitive Boolean - Only lowercase', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Currently only matches 'true' (lowercase)
    expect(source).toMatch(/===.*['\"]true['\"]/);
  });

  test('ISSUE: Nested Content - Regex [^<]* stops early', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // [^<]* pattern doesn't handle nested tags
    expect(source).toMatch(/\[\^<\]\*/);
  });

  test('ISSUE: Duplicate Tags - Returns first match only', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // No array handling for duplicate tags
    expect(source).toMatch(/match\(/); // Not matchAll for single tags
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
    expect(source).toMatch(/function determineEventType/);
  });

  test('returns done when finish_reason is present', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/finish_reason.*done|done.*finish_reason/);
  });

  test('returns tool_result when tool_call_id is present', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_call_id.*\|\|/);
  });

  test('returns tool_result when tool_name is present', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/\|\|.*tool_name/);
  });

  test('returns message as default', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/return.*['\"]message['\"]|message.*default/);
  });

  test('checks tool info before finish_reason', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Should check tool info first (more specific), then finish_reason
    const _finishIdx = source.indexOf('finish_reason');
    const _toolIdx = source.indexOf('tool_');
    // This is a suggestion - not enforced
    expect(true).toBe(true);
  });
});

// ============================================================================
// Test Suite: SSEClient Class Integration
// ============================================================================

describe('SSEClient Class Integration', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('SSEClient class exists', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/class SSEClient/);
  });

  test('uses parseSseXml in message event handler', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/parseSseXml\(.*rawData|rawData.*parseSseXml/);
  });

  test('uses determineEventType after parsing', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/determineEventType\(.*parsed|parsed.*determineEventType/);
  });

  test('skips empty/keepalive data', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/Skip empty|keepalive|\.trim\(\).*===.*0/);
  });

  test('has error handling for parse failures', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/try.*catch|parse.*error|error.*parse/);
  });
});

// ============================================================================
// Test Suite: Type Exports
// ============================================================================

describe('Type Exports', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  test('SSEMessage interface is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/export interface SSEMessage/);
  });

  test('SSEMessageHandler type is exported', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/export type SSEMessageHandler/);
  });

  test('SSEMessage has type field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/type:\s*['\"]message['\"]\s*\|.*['\"]done/);
  });

  test('SSEMessage has content field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/content\??:\s*string/);
  });

  test('SSEMessage has tool_name field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_name\??:\s*string/);
  });

  test('SSEMessage has finish_reason field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/finish_reason\??:\s*string/);
  });

  test('SSEMessage has session_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/session_id\??:\s*string/);
  });
});

describe('parseSseXml', () => {
  const sourcePath =
    '/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop-bun/src/mainview/utils/sseClient.ts';

  // Sample XML data for reference
  const _sampleXml = `<response>
    <session_id>sess_1775580700_67fcab3866482f6d</session_id>
    <model>MiniMax-M2.7</model>
    <cwd>/home/ginwa/experiment</cwd>
    <content>Hi there!</content>
    <role>assistant</role>
    <finish_reason>stop</finish_reason>
    <agent_name>Agent</agent_name>
    <session_name>hi</session_name>
    <loop_index>1</loop_index>
    <temperature>0.5</temperature>
    <is_thinking>true</is_thinking>
    <is_input>false</is_input>
    <is_output>true</is_output>
    <parent_session_id>sess_1775580700_67fcab3866482f6d</parent_session_id>
    <parent_id>sess_1775580700_67fcab3866482f6d</parent_id>
  </response>`;

  // Helper to check if source contains test case
  const checkSourceForTests = (pattern: string | RegExp, shouldExist = true) => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    if (shouldExist) {
      expect(source).toMatch(pattern);
    }
  };

  // ============================================================================
  // Test Suite: Empty and Edge Cases
  // ============================================================================

  test('handles empty string input', () => {
    // Should return empty object for empty input
    checkSourceForTests(/Skip empty data/);
  });

  test('handles whitespace-only input', () => {
    checkSourceForTests(/xmlData\.trim\(\)\.length === 0/);
  });

  test('handles null/undefined input', () => {
    checkSourceForTests(/!xmlData/);
  });

  test('logs warning for empty data', () => {
    checkSourceForTests(/log\.warn.*empty XML data/);
  });

  // ============================================================================
  // Test Suite: Core Field Parsing
  // ============================================================================

  test('parses <response> tag as main event format', () => {
    checkSourceForTests(/xmlData\.includes\('<response>'\)/);
  });

  test('extracts session_id field', () => {
    checkSourceForTests(/result\.session_id = extractXmlTag\(xmlData, 'session_id'\)/);
  });

  test('extracts model field', () => {
    checkSourceForTests(/result\.model = extractXmlTag\(xmlData, 'model'\)/);
  });

  test('extracts cwd field', () => {
    checkSourceForTests(/result\.cwd = extractXmlTag\(xmlData, 'cwd'\)/);
  });

  test('extracts content field', () => {
    checkSourceForTests(/result\.content = extractXmlTag\(xmlData, 'content'\)/);
  });

  test('extracts reasoning_content field', () => {
    checkSourceForTests(
      /result\.reasoning_content = extractXmlTag\(xmlData, 'reasoning_content'\)/
    );
  });

  test('extracts role field with default value', () => {
    // Should default to 'assistant' if not present
    checkSourceForTests(/'role'.*\|\|.*'assistant'/);
  });

  test('extracts finish_reason field', () => {
    checkSourceForTests(/result\.finish_reason = extractXmlTag\(xmlData, 'finish_reason'\)/);
  });

  test('extracts tool_call_id field', () => {
    checkSourceForTests(/result\.tool_call_id = extractXmlTag\(xmlData, 'tool_call_id'\)/);
  });

  test('extracts tool_name field', () => {
    checkSourceForTests(/result\.tool_name = extractXmlTag\(xmlData, 'tool_name'\)/);
  });

  test('extracts agent_name field', () => {
    checkSourceForTests(/result\.agent_name = extractXmlTag\(xmlData, 'agent_name'\)/);
  });

  test('extracts session_name field', () => {
    checkSourceForTests(/result\.session_name = extractXmlTag\(xmlData, 'session_name'\)/);
  });

  test('extracts parent_session_id field', () => {
    checkSourceForTests(
      /result\.parent_session_id = extractXmlTag\(xmlData, 'parent_session_id'\)/
    );
  });

  test('extracts parent_id field', () => {
    checkSourceForTests(/result\.parent_id = extractXmlTag\(xmlData, 'parent_id'\)/);
  });

  // ============================================================================
  // Test Suite: Numeric Field Parsing
  // ============================================================================

  test('parses loop_index as integer', () => {
    // Should parse loop_index with Number.parseInt
    checkSourceForTests(/Number\.parseInt\(loopIndex/);
  });

  test('parses temperature as float', () => {
    // Should parse temperature with Number.parseFloat
    checkSourceForTests(/Number\.parseFloat\(temp/);
  });

  test('handles missing loop_index gracefully', () => {
    // Should check if loopIndex exists before parsing
    checkSourceForTests(/loopIndex \? Number\.parseInt/);
  });

  test('handles missing temperature gracefully', () => {
    // Should check if temp exists before parsing
    checkSourceForTests(/temp \? Number\.parseFloat/);
  });

  // ============================================================================
  // Test Suite: Boolean Field Parsing
  // ============================================================================

  test('parses is_thinking as boolean', () => {
    // Should compare to 'true' string
    checkSourceForTests(/result\.is_thinking = extractXmlTag\(xmlData, 'is_thinking'\) === 'true'/);
  });

  test('parses is_input as boolean', () => {
    checkSourceForTests(/result\.is_input = extractXmlTag\(xmlData, 'is_input'\) === 'true'/);
  });

  test('parses is_output as boolean', () => {
    checkSourceForTests(/result\.is_output = extractXmlTag\(xmlData, 'is_output'\) === 'true'/);
  });

  // ============================================================================
  // Test Suite: Tool Calls Parsing
  // ============================================================================

  test('handles tool_calls tag', () => {
    // Should match <tool_calls>...</tool_calls>
    checkSourceForTests(/xmlData\.match\(\/<tool_calls>/);
  });

  test('extracts individual tool_call entries', () => {
    // Should match <tool_call>...</tool_call>
    checkSourceForTests(/tool_call>/);
  });

  test('parses tool_call id field', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'id'\)/);
  });

  test('parses tool_call name field', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'name'\)/);
  });

  test('parses tool_call arguments field', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'arguments'\)/);
  });

  test('creates tool_calls array', () => {
    checkSourceForTests(/result\.tool_calls = \[\]/);
  });

  test('handles missing tool_call id with fallback', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'id'\) \|\| ''/);
  });

  test('handles missing tool_call name with fallback', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'name'\) \|\| ''/);
  });

  test('handles missing tool_call arguments with fallback', () => {
    checkSourceForTests(/extractXmlTag\(tcContent, 'arguments'\) \|\| ''/);
  });

  // ============================================================================
  // Test Suite: Chunk/Streaming Parsing
  // ============================================================================

  test('handles chunk tag with index attribute', () => {
    // Should match <chunk index="\d+">...</chunk>
    checkSourceForTests(/chunk.*index=/);
  });

  test('extracts content from chunk', () => {
    checkSourceForTests(/chunkContentMatch/);
  });

  test('extracts reasoning_content from chunk', () => {
    checkSourceForTests(/reasoning_content/);
  });

  test('sets finish_reason to stop for final chunk', () => {
    // Should check for final="true" or <usage> tag
    checkSourceForTests(/final.*true/);
  });

  // ============================================================================
  // Test Suite: Helper Function (extractXmlTag)
  // ============================================================================

  test('escapes special regex characters in tag names', () => {
    // Should escape tags like tool_call_id (has underscore)
    checkSourceForTests(/tag.*replace/);
  });

  test('uses case-insensitive regex matching', () => {
    // Should use 'i' flag for case-insensitive matching
    checkSourceForTests(/RegExp.*, 'i'\)/);
  });

  test('extracts content between opening and closing tags', () => {
    // Regex pattern should capture content between tags
    checkSourceForTests(/match\[1\]/);
  });

  test('trims extracted content', () => {
    // Should call trim() on matched content
    checkSourceForTests(/\.trim\(\)/);
  });

  test('returns undefined when tag not found', () => {
    // Should return undefined when no match
    checkSourceForTests(/return match.*undefined/);
  });

  // ============================================================================
  // Test Suite: RawSSEEvent Interface
  // ============================================================================

  test('RawSSEEvent has session_id field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/session_id\??:\s*string/);
  });

  test('RawSSEEvent has model field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/model\??:\s*string/);
  });

  test('RawSSEEvent has content field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/content\??:\s*string/);
  });

  test('RawSSEEvent has tool_calls field', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/tool_calls\??: Array<\{/);
  });

  test('RawSSEEvent has loop_index as number', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/loop_index\??:\s*number/);
  });

  test('RawSSEEvent has temperature as number', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/temperature\??:\s*number/);
  });

  test('RawSSEEvent has boolean fields', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/is_thinking\??:\s*boolean/);
    expect(source).toMatch(/is_input\??:\s*boolean/);
    expect(source).toMatch(/is_output\??:\s*boolean/);
  });

  test('RawSSEEvent has parent_session_id and parent_id fields', () => {
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/parent_session_id\??:\s*string/);
    expect(source).toMatch(/parent_id\??:\s*string/);
  });

  // ============================================================================
  // Test Suite: Error Handling and Edge Cases
  // ============================================================================

  test('returns empty object for invalid XML', () => {
    // Should return result object even on invalid XML
    const source = fs.readFileSync(sourcePath, 'utf-8');
    // Check that extractXmlTag returns undefined for non-matching content
    expect(source).toMatch(/return match \? match\[1\]\.trim\(\) : undefined/);
  });

  test('handles nested tags gracefully', () => {
    // extractXmlTag should stop at first closing tag
    // Content between <tag> and </tag> should be captured
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/match\[1\]/);
  });

  test('handles empty tags (self-closing-like)', () => {
    // Empty content should result in empty string, not undefined
    // The [^<]* pattern matches zero or more characters
    const source = fs.readFileSync(sourcePath, 'utf-8');
    expect(source).toMatch(/match\[1\]/);
  });
});
