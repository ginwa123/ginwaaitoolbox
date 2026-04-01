import { describe, expect, test, beforeEach, afterEach } from 'bun:test';
import { SSEClient, type SSEMessage } from './sseClient';

describe('SSEClient', () => {
  const baseUrl = 'http://127.0.0.1:8082';
  let client: SSEClient;

  beforeEach(() => {
    client = new SSEClient(baseUrl);
  });

  afterEach(() => {
    client.disconnect();
  });

  test('creates SSEClient with baseUrl', () => {
    expect(client).toBeDefined();
  });

  test('addHandler registers a handler and returns unsubscribe function', () => {
    const handler = (event: SSEMessage) => {
      console.log('Handler called:', event);
    };

    const unsubscribe = client.addHandler(handler);
    expect(typeof unsubscribe).toBe('function');

    // Call unsubscribe
    unsubscribe();
  });

  test('disconnect cleans up without errors', () => {
    // Should not throw
    client.disconnect();
    expect(true).toBe(true);
  });

  test('multiple disconnect calls are safe', () => {
    client.disconnect();
    client.disconnect();
    expect(true).toBe(true);
  });
});

describe('SSEMessage types', () => {
  test('message event has required fields', () => {
    const event: SSEMessage = {
      type: 'message',
      content: 'Hello',
      role: 'assistant',
      message_id: 'msg_123',
      timestamp: '1234567890',
    };

    expect(event.type).toBe('message');
    expect(event.content).toBe('Hello');
  });

  test('tool_result event has required fields', () => {
    const event: SSEMessage = {
      type: 'tool_result',
      content: 'Tool output',
      tool_name: 'bash',
      message_id: 'tool_123',
      timestamp: '1234567890',
    };

    expect(event.type).toBe('tool_result');
    expect(event.tool_name).toBe('bash');
  });

  test('done event', () => {
    const event: SSEMessage = {
      type: 'done',
      session_id: 'session_123',
    };

    expect(event.type).toBe('done');
  });
});
