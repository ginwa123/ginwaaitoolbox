/**
 * Tool Call XML Parser
 *
 * Parses XML-formatted tool call output from the backend and extracts
 * structured data based on the tool type.
 *
 * Supports: bash, read_file, write_file, search, glob, web_search,
 * spawn_sub_agent, lsp_* tools, and generic fallback.
 */

import { decodeXmlEntities } from './xmlParser';

// ============================================================================
// Types
// ============================================================================

export interface ToolData {
  toolName: string;
  fields: Record<string, string>;
  isParsed: boolean;
  rawContent: string;
}

export interface ParseResult {
  tools: ToolData[];
  isComplete: boolean;
}

// ============================================================================
// XML Entity Decoding (for tool content)
// ============================================================================

/**
 * Decode XML entities in tool output content
 */
const decodeToolContent = (str: string | undefined | null): string => {
  if (!str) return '';
  return decodeXmlEntities(str);
};

// ============================================================================
// Tool-Specific Parsers
// ============================================================================

/**
 * Parse bash tool output
 * Expected fields: command, result, exit_code
 */
const parseBashTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract command
  const commandMatch = content.match(/<command>([\s\S]*?)<\/command>/i);
  if (commandMatch) {
    fields.command = decodeToolContent(commandMatch[1].trim());
  }

  // Extract result
  const resultMatch = content.match(/<result>([\s\S]*?)<\/result>/i);
  if (resultMatch) {
    fields.result = decodeToolContent(resultMatch[1].trim());
  }

  // Extract exit_code
  const exitMatch = content.match(/<exit_code>([\s\S]*?)<\/exit_code>/i);
  if (exitMatch) {
    fields.exit_code = decodeToolContent(exitMatch[1].trim());
  }

  return fields;
};

/**
 * Parse read_file tool output
 * Expected fields: path, content, hash (optional)
 */
const parseReadFileTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract path
  const pathMatch = content.match(/<path>([\s\S]*?)<\/path>/i);
  if (pathMatch) {
    fields.path = decodeToolContent(pathMatch[1].trim());
  }

  // Extract content
  const contentMatch = content.match(/<content>([\s\S]*?)<\/content>/i);
  if (contentMatch) {
    fields.content = decodeToolContent(contentMatch[1].trim());
  }

  // Extract hash (optional)
  const hashMatch = content.match(/<hash>([\s\S]*?)<\/hash>/i);
  if (hashMatch) {
    fields.hash = decodeToolContent(hashMatch[1].trim());
  }

  // Extract show_line_numbers
  const lineNumMatch = content.match(/<show_line_numbers>([\s\S]*?)<\/show_line_numbers>/i);
  if (lineNumMatch) {
    fields.show_line_numbers = decodeToolContent(lineNumMatch[1].trim());
  }

  return fields;
};

/**
 * Parse write_file tool output
 * Expected fields: path, content, hash
 */
const parseWriteFileTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract path
  const pathMatch = content.match(/<path>([\s\S]*?)<\/path>/i);
  if (pathMatch) {
    fields.path = decodeToolContent(pathMatch[1].trim());
  }

  // Extract content
  const contentMatch = content.match(/<content>([\s\S]*?)<\/content>/i);
  if (contentMatch) {
    fields.content = decodeToolContent(contentMatch[1].trim());
  }

  // Extract hash
  const hashMatch = content.match(/<hash>([\s\S]*?)<\/hash>/i);
  if (hashMatch) {
    fields.hash = decodeToolContent(hashMatch[1].trim());
  }

  return fields;
};

/**
 * Parse search tool output
 * Expected fields: pattern, path, matches
 */
const parseSearchTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract pattern
  const patternMatch = content.match(/<pattern>([\s\S]*?)<\/pattern>/i);
  if (patternMatch) {
    fields.pattern = decodeToolContent(patternMatch[1].trim());
  }

  // Extract path
  const pathMatch = content.match(/<path>([\s\S]*?)<\/path>/i);
  if (pathMatch) {
    fields.path = decodeToolContent(pathMatch[1].trim());
  }

  // Extract matches
  const matchesMatch = content.match(/<matches>([\s\S]*?)<\/matches>/i);
  if (matchesMatch) {
    fields.matches = decodeToolContent(matchesMatch[1].trim());
  }

  return fields;
};

/**
 * Parse glob tool output
 * Expected fields: pattern, results
 */
const parseGlobTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract pattern
  const patternMatch = content.match(/<pattern>([\s\S]*?)<\/pattern>/i);
  if (patternMatch) {
    fields.pattern = decodeToolContent(patternMatch[1].trim());
  }

  // Extract results
  const resultsMatch = content.match(/<results>([\s\S]*?)<\/results>/i);
  if (resultsMatch) {
    fields.results = decodeToolContent(resultsMatch[1].trim());
  }

  return fields;
};

/**
 * Parse web_search tool output
 * Expected fields: query, url, results
 */
const parseWebSearchTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract query
  const queryMatch = content.match(/<query>([\s\S]*?)<\/query>/i);
  if (queryMatch) {
    fields.query = decodeToolContent(queryMatch[1].trim());
  }

  // Extract url
  const urlMatch = content.match(/<url>([\s\S]*?)<\/url>/i);
  if (urlMatch) {
    fields.url = decodeToolContent(urlMatch[1].trim());
  }

  // Extract results
  const resultsMatch = content.match(/<results>([\s\S]*?)<\/results>/i);
  if (resultsMatch) {
    fields.results = decodeToolContent(resultsMatch[1].trim());
  }

  return fields;
};

/**
 * Parse LSP tool output (lsp_definition, lsp_hover, lsp_references, etc.)
 * Expected fields: file_path, line, character, symbol
 */
const parseLspTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract file_path
  const filePathMatch = content.match(/<file_path>([\s\S]*?)<\/file_path>/i);
  if (filePathMatch) {
    fields.file_path = decodeToolContent(filePathMatch[1].trim());
  }

  // Extract line
  const lineMatch = content.match(/<line>([\s\S]*?)<\/line>/i);
  if (lineMatch) {
    fields.line = decodeToolContent(lineMatch[1].trim());
  }

  // Extract character
  const charMatch = content.match(/<character>([\s\S]*?)<\/character>/i);
  if (charMatch) {
    fields.character = decodeToolContent(charMatch[1].trim());
  }

  // Extract symbol (optional)
  const symbolMatch = content.match(/<symbol>([\s\S]*?)<\/symbol>/i);
  if (symbolMatch) {
    fields.symbol = decodeToolContent(symbolMatch[1].trim());
  }

  return fields;
};

/**
 * Parse spawn_sub_agent tool output
 * Expected fields: agents, results
 */
const parseSpawnSubAgentTool = (content: string): Record<string, string> => {
  const fields: Record<string, string> = {};

  // Extract agents
  const agentsMatch = content.match(/<agents>([\s\S]*?)<\/agents>/i);
  if (agentsMatch) {
    fields.agents = decodeToolContent(agentsMatch[1].trim());
  }

  // Extract results
  const resultsMatch = content.match(/<results>([\s\S]*?)<\/results>/i);
  if (resultsMatch) {
    fields.results = decodeToolContent(resultsMatch[1].trim());
  }

  return fields;
};

/**
 * Parse tool call formatting XML
 * Expected format:
 * <tool_call>
 *   <tool_name>bash</tool_name>
 *   <command>ls -la</command>
 *   <result>...</result>
 *   <exit_code>0</exit_code>
 * </tool_call>
 */
const parseSingleToolCall = (toolCallXml: string): ToolData | null => {
  try {
    // Extract tool_name
    const toolNameMatch = toolCallXml.match(/<tool_name>([\s\S]*?)<\/tool_name>/i);
    if (!toolNameMatch) return null;

    const toolName = decodeToolContent(toolNameMatch[1].trim()).toLowerCase();
    if (!toolName) return null;

    // Extract content between tool_call tags (everything except tool_name)
    const contentMatch = toolCallXml.match(/<tool_call>([\s\S]*?)<\/tool_call>/i);
    const content = contentMatch ? contentMatch[1] : toolCallXml;

    let fields: Record<string, string> = {};
    let isParsed = true;

    // Route to appropriate parser based on tool type
    switch (true) {
      case toolName === 'bash':
        fields = parseBashTool(content);
        break;

      case toolName === 'read_file':
        fields = parseReadFileTool(content);
        break;

      case toolName === 'write_file':
        fields = parseWriteFileTool(content);
        break;

      case toolName === 'search':
        fields = parseSearchTool(content);
        break;

      case toolName === 'glob':
        fields = parseGlobTool(content);
        break;

      case toolName.includes('web_search'):
        fields = parseWebSearchTool(content);
        break;

      case toolName.startsWith('lsp_'):
        fields = parseLspTool(content);
        break;

      case toolName === 'spawn_sub_agent':
        fields = parseSpawnSubAgentTool(content);
        break;

      default:
        // Generic fallback: extract any fields we can
        isParsed = false;
        fields = { raw: content };
    }

    return {
      toolName,
      fields,
      isParsed,
      rawContent: toolCallXml,
    };
  } catch {
    return null;
  }
};

// ============================================================================
// Main Parser Function
// ============================================================================

/**
 * Parse tool call XML content from a message
 *
 * Handles:
 * - Single tool call: <tool_call>...</tool_call>
 * - Multiple tool calls: <tool_calls><tool_call>...</tool_call>...</tool_calls>
 * - Partial/streaming content (incomplete XML)
 * - Mixed content with raw text
 *
 * @param content - Raw XML content from the message
 * @returns ParseResult with array of ToolData and completeness flag
 */
export const parseToolCallXml = (content: string): ParseResult => {
  if (!content || typeof content !== 'string') {
    return { tools: [], isComplete: true };
  }

  const tools: ToolData[] = [];

  try {
    // Check if content looks like XML tool call format
    if (!content.includes('<tool_call>') && !content.includes('<tool_name>')) {
      // Not tool call XML format, return as single generic tool
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

    // Handle multiple tool calls wrapped in <tool_calls>
    const toolCallsSectionMatch = content.match(/<tool_calls>([\s\S]*?)<\/tool_calls>/i);
    if (toolCallsSectionMatch) {
      const toolCallsSection = toolCallsSectionMatch[1];

      // Extract each <tool_call>...</tool_call>
      const toolCallRegex = /<tool_call>([\s\S]*?)<\/tool_call>/gi;
      let match;

      while ((match = toolCallRegex.exec(toolCallsSection)) !== null) {
        const toolData = parseSingleToolCall(match[0]);
        if (toolData) {
          tools.push(toolData);
        }
      }
    } else {
      // Single tool call (no wrapper)
      const toolData = parseSingleToolCall(content);
      if (toolData) {
        tools.push(toolData);
      }
    }

    // Check if content appears incomplete (streaming)
    const isComplete =
      !(content.includes('<tool_call>') && !content.includes('</tool_call>')) &&
      !(content.includes('<tool_calls>') && !content.includes('</tool_calls>'));

    return { tools, isComplete };
  } catch {
    // On error, return content as generic tool
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
};

/**
 * Detect if content is tool call XML format
 */
export const isToolCallXml = (content: string | undefined | null): boolean => {
  if (!content) return false;
  return content.includes('<tool_call>') || content.includes('<tool_name>');
};

/**
 * Get a summary of the tool call for display in collapsed view
 */
export const getToolSummary = (tool: ToolData): string => {
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
};
