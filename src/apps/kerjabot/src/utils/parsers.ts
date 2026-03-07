/**
 * Pure parsing utility functions
 * Functional programming approach with no side effects
 */

import type { ToolCall, ToolType } from '~/types';

/** Parse SSE (Server-Sent Events) data */
export const parseSSE = (data: string): Array<{ event?: string; data: string }> => {
  const lines = data.split('\n');
  const events: Array<{ event?: string; data: string }> = [];
  let currentEvent: { event?: string; data: string } | null = null;

  for (const line of lines) {
    if (line.startsWith('event: ')) {
      if (currentEvent) events.push(currentEvent);
      currentEvent = { event: line.slice(7), data: '' };
    } else if (line.startsWith('data: ')) {
      if (!currentEvent) currentEvent = { data: '' };
      currentEvent.data = line.slice(6);
    } else if (line === '' && currentEvent) {
      events.push(currentEvent);
      currentEvent = null;
    }
  }

  if (currentEvent) events.push(currentEvent);
  return events;
};

/** Extract code blocks from markdown */
export const extractCodeBlocks = (content: string): Array<{ language?: string; code: string }> => {
  const regex = /```(\w+)?\n([\s\S]*?)```/g;
  const blocks: Array<{ language?: string; code: string }> = [];
  let match;

  while ((match = regex.exec(content)) !== null) {
    blocks.push({
      language: match[1],
      code: match[2].trim(),
    });
  }

  return blocks;
};

/** Extract XML-like tags from content */
export const extractXmlTags = (content: string): Array<{ tag: string; content: string }> => {
  const regex = /<(\w+)>([\s\S]*?)<\/\1>/g;
  const tags: Array<{ tag: string; content: string }> = [];
  let match;

  while ((match = regex.exec(content)) !== null) {
    tags.push({
      tag: match[1],
      content: match[2].trim(),
    });
  }

  return tags;
};

/** Parse tool call from JSON string */
export const parseToolCall = (json: string): ToolCall | null => {
  try {
    const parsed = JSON.parse(json);
    return {
      id: parsed.id || `tool_${Date.now()}`,
      type: parsed.type as ToolType,
      name: parsed.name,
      arguments: parsed.arguments || {},
      timestamp: new Date(parsed.timestamp || Date.now()),
    };
  } catch {
    return null;
  }
};

/** Parse JSON safely */
export const safeJsonParse = <T>(json: string, defaultValue: T): T => {
  try {
    return JSON.parse(json) as T;
  } catch {
    return defaultValue;
  }
};

/** Extract URLs from text */
export const extractUrls = (text: string): string[] => {
  const regex = /https?:\/\/[^\s<>"{}|\\^`[\]]+/g;
  return text.match(regex) || [];
};

/** Parse command line arguments */
export const parseCommandArgs = (command: string): string[] => {
  const args: string[] = [];
  let current = '';
  let inQuotes = false;
  let quoteChar = '';

  for (const char of command) {
    if ((char === '"' || char === "'") && !inQuotes) {
      inQuotes = true;
      quoteChar = char;
    } else if (char === quoteChar && inQuotes) {
      inQuotes = false;
      quoteChar = '';
    } else if (char === ' ' && !inQuotes) {
      if (current) {
        args.push(current);
        current = '';
      }
    } else {
      current += char;
    }
  }

  if (current) args.push(current);
  return args;
};

/** Detect language from file extension */
export const detectLanguage = (filename: string): string | undefined => {
  const ext = filename.split('.').pop()?.toLowerCase();
  const langMap: Record<string, string> = {
    ts: 'typescript',
    tsx: 'tsx',
    js: 'javascript',
    jsx: 'jsx',
    py: 'python',
    rs: 'rust',
    go: 'go',
    java: 'java',
    cpp: 'cpp',
    c: 'c',
    h: 'c',
    hpp: 'cpp',
    zig: 'zig',
    md: 'markdown',
    json: 'json',
    yaml: 'yaml',
    yml: 'yaml',
    html: 'html',
    css: 'css',
    scss: 'scss',
    sql: 'sql',
    sh: 'bash',
    bash: 'bash',
    zsh: 'zsh',
  };
  return ext ? langMap[ext] : undefined;
};

/** Parse session ID from various formats */
export const parseSessionId = (input: string): string | null => {
  // Match session ID patterns like "sess_1234567890_abc123"
  const match = input.match(/sess_\d+_[a-z0-9]+/);
  return match ? match[0] : null;
};

/** Strip HTML tags from text */
export const stripHtml = (html: string): string => {
  return html.replace(/<[^>]*>/g, '');
};

/** Normalize whitespace */
export const normalizeWhitespace = (text: string): string => {
  return text.replace(/\s+/g, ' ').trim();
};
