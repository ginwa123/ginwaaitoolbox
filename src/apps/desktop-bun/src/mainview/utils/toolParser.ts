/**
 * Tool Call Parser
 *
 * Parses JSON-formatted tool call output from the backend and extracts
 * structured data based on the tool type.
 *
 * Supports: bash, read_file, write_file, search, glob, web_search,
 * spawn_sub_agent, lsp_* tools, and generic fallback.
 *
 * Request tracking: 1 request = 1 GUID for easy correlation in logs
 */

// ============================================================================
// Types
// ============================================================================

export interface ToolData {
  toolName: string;
  fields: Record<string, string>;
  isParsed: boolean;
  rawContent: string;
  requestId?: string;
  eventIndex?: number;
}

export interface ParseResult {
  tools: ToolData[];
  isComplete: boolean;
}

export interface RequestContext {
  requestId: string;
  eventIndex: number;
}

// ============================================================================
// Request Context Helpers
// ============================================================================

export function generateRequestId(): string {
  const timestamp = Date.now().toString(36);
  const randomPart = Math.random().toString(36).substring(2, 6);
  const randomPart2 = Math.random().toString(36).substring(2, 6);
  return `REQ-${timestamp}-${randomPart}${randomPart2}`.toUpperCase();
}

// ============================================================================
// JSON Field Extraction Helpers
// ============================================================================

function getStringField(obj: Record<string, unknown>, field: string): string {
  const value = obj[field];
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '';
  return String(value);
}

function getObjectField(obj: Record<string, unknown>, field: string): Record<string, unknown> | null {
  const value = obj[field];
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return null;
}

// ============================================================================
// Tool-Specific Parsers
// ============================================================================

function parseBashTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    command: getStringField(obj, 'command'),
    result: getStringField(obj, 'result'),
    exit_code: getStringField(obj, 'exit_code'),
  };
}

function parseReadFileTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    path: getStringField(obj, 'path'),
    content: getStringField(obj, 'content'),
    hash: getStringField(obj, 'hash'),
    show_line_numbers: getStringField(obj, 'show_line_numbers'),
  };
}

function parseWriteFileTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    path: getStringField(obj, 'path'),
    content: getStringField(obj, 'content'),
    hash: getStringField(obj, 'hash'),
  };
}

function parseSearchTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    pattern: getStringField(obj, 'pattern'),
    path: getStringField(obj, 'path'),
    matches: getStringField(obj, 'matches'),
  };
}

function parseGlobTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    pattern: getStringField(obj, 'pattern'),
    results: getStringField(obj, 'results'),
  };
}

function parseWebSearchTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    query: getStringField(obj, 'query'),
    url: getStringField(obj, 'url'),
    results: getStringField(obj, 'results'),
  };
}

function parseLspTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    file_path: getStringField(obj, 'file_path'),
    line: getStringField(obj, 'line'),
    character: getStringField(obj, 'character'),
    symbol: getStringField(obj, 'symbol'),
  };
}

function parseSpawnSubAgentTool(obj: Record<string, unknown>): Record<string, string> {
  return {
    agents: getStringField(obj, 'agents'),
    results: getStringField(obj, 'results'),
  };
}

function parseGenericTool(obj: Record<string, unknown>): Record<string, string> {
  const fields: Record<string, string> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value === 'string') {
      fields[key] = value;
    } else if (typeof value === 'number' || typeof value === 'boolean') {
      fields[key] = String(value);
    } else if (value && typeof value === 'object') {
      fields[key] = JSON.stringify(value);
    }
  }
  return fields;
}

// ============================================================================
// Main Parser Function
// ============================================================================

export function parseToolCallJson(content: string): ParseResult {
  if (!content || typeof content !== 'string') {
    return { tools: [], isComplete: true };
  }

  const tools: ToolData[] = [];

  try {
    // Try to parse as JSON
    let data: unknown;
    try {
      data = JSON.parse(content);
    } catch {
      // Not JSON, return as single generic tool
      return {
        tools: [
          {
            toolName: 'unknown',
            fields: { raw: content },
            isParsed: false,
            rawContent: content,
          },
        ],
        isComplete: true,
      };
    }

    // Handle array of tool calls
    if (Array.isArray(data)) {
      for (const item of data) {
        if (item && typeof item === 'object') {
          const toolData = parseSingleToolCall(item as Record<string, unknown>);
          if (toolData) {
            tools.push(toolData);
          }
        }
      }
      return { tools, isComplete: true };
    }

    // Handle single tool call object
    if (data && typeof data === 'object') {
      const toolData = parseSingleToolCall(data as Record<string, unknown>);
      if (toolData) {
        tools.push(toolData);
      }
    }

    // Unknown format
    if (tools.length === 0) {
      return {
        tools: [
          {
            toolName: 'unknown',
            fields: { raw: content },
            isParsed: false,
            rawContent: content,
          },
        ],
        isComplete: true,
      };
    }

    return { tools, isComplete: true };
  } catch {
    return {
      tools: [
        {
          toolName: 'unknown',
          fields: { raw: content },
          isParsed: false,
          rawContent: content,
        },
      ],
      isComplete: true,
    };
  }
}

function parseSingleToolCall(obj: Record<string, unknown>): ToolData | null {
  // Extract tool_name (try both "name" and "tool_name" for compatibility)
  const toolName = getStringField(obj, 'name') || getStringField(obj, 'tool_name');
  if (!toolName) return null;

  const toolNameLower = toolName.toLowerCase();
  let fields: Record<string, string> = {};
  let isParsed = true;

  // Route to appropriate parser based on tool type
  switch (true) {
    case toolNameLower === 'bash':
      fields = parseBashTool(obj);
      break;

    case toolNameLower === 'read_file':
      fields = parseReadFileTool(obj);
      break;

    case toolNameLower === 'write_file':
      fields = parseWriteFileTool(obj);
      break;

    case toolNameLower === 'search':
      fields = parseSearchTool(obj);
      break;

    case toolNameLower === 'glob':
      fields = parseGlobTool(obj);
      break;

    case toolNameLower.includes('web_search'):
      fields = parseWebSearchTool(obj);
      break;

    case toolNameLower.startsWith('lsp_'):
      fields = parseLspTool(obj);
      break;

    case toolNameLower === 'spawn_sub_agent':
      fields = parseSpawnSubAgentTool(obj);
      break;

    default:
      isParsed = false;
      fields = parseGenericTool(obj);
  }

  return {
    toolName: toolNameLower,
    fields,
    isParsed,
    rawContent: JSON.stringify(obj),
  };
}

// ============================================================================
// Legacy Aliases for backwards compatibility
// ============================================================================

export const parseToolCallXml = parseToolCallJson;
export const isToolCallXml = (_content: string | undefined | null): boolean => false;
export const isToolCallJson = (content: string | undefined | null): boolean => {
  if (!content) return false;
  try {
    const parsed = JSON.parse(content);
    return parsed && typeof parsed === 'object' && ('name' in parsed || 'tool_name' in parsed || Array.isArray(parsed));
  } catch {
    return false;
  }
};

// ============================================================================
// Utility Functions
// ============================================================================

export function getToolSummary(tool: ToolData): string {
  switch (tool.toolName) {
    case 'bash':
      return tool.fields.command?.slice(0, 50) || 'bash command';
    case 'read_file':
      return tool.fields.path || 'read file';
    case 'write_file':
      return `Written: ${tool.fields.path || 'file'}`;
    case 'search':
      return `Search: ${tool.fields.pattern || tool.fields.path || 'pattern'}`;
    case 'glob':
      return `Glob: ${tool.fields.pattern || 'pattern'}`;
    case 'web_search':
      return `Web: ${tool.fields.query || tool.fields.url || 'search'}`;
    default:
      return tool.toolName;
  }
}

export function parseToolCallJsonWithRequest(
  content: string,
  context: RequestContext
): ParseResult & RequestContext {
  const result = parseToolCallJson(content);

  for (const tool of result.tools) {
    tool.requestId = context.requestId;
    tool.eventIndex = context.eventIndex;
  }

  return {
    ...result,
    requestId: context.requestId,
    eventIndex: context.eventIndex,
  };
}

export function formatRequestLog(text: string, context: RequestContext, extra?: string): string {
  return `[REQ:${context.requestId}][E${context.eventIndex}] ${text}${extra ? ` | ${extra}` : ''}`;
}
