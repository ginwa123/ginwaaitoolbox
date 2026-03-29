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
 * Decode XML entities in a string
 */
export const decodeXmlEntities = (str: string): string => {
  return str
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
};

/**
 * Parse messages from XML response format
 */
export const parseXmlMessages = (xml: string): XmlMessage[] => {
  const messages: XmlMessage[] = [];

  // Parse message tags with id attribute
  const messageRegex = /<message id="([^"]*)">([\s\S]*?)<\/message>/g;
  let match;

  while ((match = messageRegex.exec(xml)) !== null) {
    const id = match[1];
    const content = match[2];

    const getTagValue = (tag: string): string => {
      const regex = new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, "i");
      const tagMatch = content.match(regex);
      return tagMatch ? tagMatch[1] : "";
    };

    messages.push({
      id,
      session_id: getTagValue("session_id"),
      role: getTagValue("role"),
      content: getTagValue("content"),
      timestamp: getTagValue("timestamp"),
      is_input: getTagValue("is_input"),
      is_output: getTagValue("is_output"),
      tool_name: getTagValue("tool_name"),
      finish_reason: getTagValue("finish_reason"),
    });
  }

  return messages;
};

/**
 * Detect if a string is XML or JSON
 */
export const detectFormat = (text: string): "xml" | "json" | "unknown" => {
  const trimmed = text.trim();
  if (trimmed.startsWith("<")) {
    return "xml";
  }
  if (trimmed.startsWith("{")) {
    return "json";
  }
  return "unknown";
};

/**
 * Parse messages from either XML or JSON response
 */
export const parseMessages = (response: string): XmlMessage[] => {
  const format = detectFormat(response);

  switch (format) {
    case "xml":
      return parseXmlMessages(response);
    case "json":
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
