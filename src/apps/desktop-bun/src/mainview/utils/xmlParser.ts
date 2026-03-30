/**
 * XML Parser Utilities
 *
 * Provides XML parsing and decoding functionality for the desktop app
 * to handle responses from the backend API with format=xml parameter.
 */

export interface XmlMessage {
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
 * Safely decode XML entities in a string
 */
export const decodeXmlEntities = (str: string | undefined | null): string => {
  if (!str) return '';
  return str
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
};

/**
 * Extract tag value using a regex that handles nested tags properly
 * by matching from opening tag to the CORRECT closing tag (not the first one found)
 */
const getTagValue = (content: string, tag: string): string => {
  // Match opening tag, then any content until we find the exact closing tag
  // This handles nested content better than non-greedy matching
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(
    `<${escapedTag}>([^<]*(?:<(?!/${escapedTag}>)[^<]*)*)<\\/${escapedTag}>`,
    'i'
  );
  const match = content.match(regex);
  return match ? match[1].trim() : '';
};

/**
 * Parse messages from XML response format
 */
export const parseXmlMessages = (xml: string): XmlMessage[] => {
  const messages: XmlMessage[] = [];

  if (!xml || typeof xml !== 'string') {
    return messages;
  }

  try {
    // Parse message tags with id attribute
    // Use a regex that captures from <message id="..."> to </message>
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

/**
 * Detect if a string is XML or JSON
 */
export const detectFormat = (text: string): 'xml' | 'json' | 'unknown' => {
  const trimmed = (text || '').trim();
  if (trimmed.startsWith('<')) {
    return 'xml';
  }
  if (trimmed.startsWith('{')) {
    return 'json';
  }
  return 'unknown';
};

/**
 * Parse messages from either XML or JSON response
 */
export const parseMessages = (response: string): XmlMessage[] => {
  const format = detectFormat(response);

  switch (format) {
    case 'xml':
      return parseXmlMessages(response);
    case 'json':
      try {
        const data = JSON.parse(response);
        return data.messages || [];
      } catch {
        return [];
      }
    default:
      return [];
  }
};
