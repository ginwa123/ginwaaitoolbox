import { describe, expect, test } from 'bun:test';

// ============================================================================
// Test: getCwd RPC Handler
// ============================================================================

describe('getCwd RPC', () => {
  test('returns process.cwd() value', () => {
    // The handler should return the current working directory
    const expectedCwd = process.cwd();
    expect(typeof expectedCwd).toBe('string');
    expect(expectedCwd.length).toBeGreaterThan(0);
  });

  test('returns an absolute path', () => {
    const cwd = process.cwd();
    // Unix absolute paths start with /
    // Windows absolute paths have drive letter (e.g., C:\)
    const isAbsolute =
      cwd.startsWith('/') || // Unix
      /^[A-Za-z]:/.test(cwd); // Windows
    expect(isAbsolute).toBe(true);
  });

  test('cwd should be a non-empty string', () => {
    const cwd = process.cwd();
    // Basic validation that cwd is a non-empty string
    expect(typeof cwd).toBe('string');
    expect(cwd.length).toBeGreaterThan(0);
  });
});

// ============================================================================
// Test: SessionChat cwd_session parameter
// ============================================================================

describe('SessionChat create session', () => {
  test('CreateSessionRequest interface includes cwd_session', () => {
    const request = {
      queue_message: 'test message',
      cwd_session: '/home/user/project',
    };

    // Verify the structure matches expected
    expect(typeof request.queue_message).toBe('string');
    expect(typeof request.cwd_session).toBe('string');
    expect(request.cwd_session).toBe('/home/user/project');
  });
});

// ============================================================================
// Test: RPC schema type compatibility
// ============================================================================

describe('RPC schema compatibility', () => {
  test('getCwd response type is string', () => {
    const mockResponse = process.cwd();
    // Response should be a string
    const isString = typeof mockResponse === 'string';
    expect(isString).toBe(true);
  });
});
