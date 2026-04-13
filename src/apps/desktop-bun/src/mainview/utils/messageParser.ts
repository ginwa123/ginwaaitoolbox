/**
 * Message Parser Utilities
 *
 * Provides JSON parsing functionality for the desktop app
 * to handle responses from the backend API.
 */

export interface MessageData {
  id: string;
  session_id: string;
  role: string;
  content: string;
  timestamp: string;
  is_input: string;
  is_output: string;
  tool_name: string;
  finish_reason: string;
}

/**
 * Parse messages from JSON response format
 */
export const parseJsonMessages = (data: unknown): MessageData[] => {
  const messages: MessageData[] = [];

  if (!data || typeof data !== 'object') {
    return messages;
  }

  try {
    // Handle array of messages
    if (Array.isArray(data)) {
      for (const msg of data) {
        if (msg && typeof msg === 'object') {
          messages.push(extractMessageData(msg));
        }
      }
    } else {
      // Single message object
      messages.push(extractMessageData(data));
    }
  } catch (err) {
    console.error('Error parsing JSON messages:', err);
  }

  return messages;
};

/**
 * Extract message data from a JSON object
 */
function extractMessageData(obj: Record<string, unknown>): MessageData {
  return {
    id: String(obj.id || ''),
    session_id: String(obj.session_id || ''),
    role: String(obj.role || 'assistant'),
    content: String(obj.content || ''),
    timestamp: String(obj.timestamp || Date.now()),
    is_input: String(obj.is_input || 'false'),
    is_output: String(obj.is_output || 'false'),
    tool_name: String(obj.tool_name || ''),
    finish_reason: String(obj.finish_reason || ''),
  };
}

/**
 * Detect if a string is JSON
 */
export const detectFormat = (text: string): 'xml' | 'json' | 'unknown' => {
  const trimmed = (text || '').trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return 'json';
  }
  if (trimmed.startsWith('<')) {
    return 'xml';
  }
  return 'unknown';
};

/**
 * Parse messages from JSON response
 */
export const parseMessages = (response: string): MessageData[] => {
  const format = detectFormat(response);

  switch (format) {
    case 'json':
      try {
        const data = JSON.parse(response);
        return parseJsonMessages(data);
      } catch {
        return [];
      }
    case 'xml':
      // Legacy XML support for backwards compatibility
      return parseXmlMessages(response);
    default:
      return [];
  }
};

// ============================================================================
// Legacy XML Support (for backwards compatibility)
// ============================================================================

/**
 * Decode XML entities in a string
 */
const decodeXmlEntities = (str: string | undefined | null): string => {
  if (!str) return '';
  return str
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
};

/**
 * Extract tag value using a regex
 */
const getTagValue = (content: string, tag: string): string => {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(
    `<${escapedTag}>([^<]*(?:<(?!/${escapedTag}>)[^<]*)*)<\\/${escapedTag}>`,
    'i'
  );
  const match = content.match(regex);
  return match ? match[1].trim() : '';
};

/**
 * Legacy: Parse messages from XML response format
 */
const parseXmlMessages = (xml: string): MessageData[] => {
  const messages: MessageData[] = [];

  if (!xml || typeof xml !== 'string') {
    return messages;
  }

  try {
    const messageRegex = /<message id="([^"]*)">([\s\S]*?)(?=<\/message>|(?=<message)|$)/g;
    let match;

    while ((match = messageRegex.exec(xml)) !== null) {
      const id = match[1].trim();
      const messageContent = match[2];

      if (!id || !messageContent) continue;

      messages.push({
        id,
        session_id: getTagValue(messageContent, 'session_id'),
        role: getTagValue(messageContent, 'role'),
        content: getTagValue(messageContent, 'content'),
        timestamp: getTagValue(messageContent, 'timestamp'),
        is_input: getTagValue(messageContent, 'is_input'),
        is_output: getTagValue(messageContent, 'is_output'),
        tool_name: getTagValue(messageContent, 'tool_name'),
        finish_reason: getTagValue(messageContent, 'finish_reason'),
      });
    }
  } catch (err) {
    console.error('Error parsing XML messages:', err);
  }

  return messages;
};

// ============================================================================
// Re-exports for backwards compatibility
// ============================================================================

export { decodeXmlEntities as legacyDecodeXmlEntities };
export const getTagValueLegacy = getTagValue;
