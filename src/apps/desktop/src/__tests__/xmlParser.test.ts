/**
 * XML Parser Tests - TDD approach for XML response support
 * 
 * Tests the XML parsing functionality needed for the desktop app
 * to handle responses from the backend API with format=xml parameter.
 */

import { describe, it, expect } from "vitest";

// XML parser implementation to test
const parseXmlMessages = (xml: string): Array<{
  id: string;
  session_id: string;
  role: string;
  content: string;
  timestamp: string;
  is_input: string;
  is_output: string;
  tool_name: string;
  finish_reason: string;
}> => {
  const messages: Array<{
    id: string;
    session_id: string;
    role: string;
    content: string;
    timestamp: string;
    is_input: string;
    is_output: string;
    tool_name: string;
    finish_reason: string;
  }> = [];

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

// Decode XML entities
const decodeXmlEntities = (str: string): string => {
  return str
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
};

// Detect format
const detectFormat = (text: string): "xml" | "json" | "unknown" => {
  const trimmed = text.trim();
  if (trimmed.startsWith("<")) {
    return "xml";
  }
  if (trimmed.startsWith("{")) {
    return "json";
  }
  return "unknown";
};

describe("XML Parser", () => {
  describe("parseXmlMessages", () => {
    it("should parse a single message from XML", () => {
      const xml = `<messages>
        <message id="msg1">
          <session_id>sess123</session_id>
          <role>user</role>
          <content>Hello world</content>
          <timestamp>2024-01-15T10:00:00</timestamp>
          <is_input>1</is_input>
          <is_output>0</is_output>
          <tool_name></tool_name>
          <finish_reason></finish_reason>
        </message>
      </messages>`;

      const messages = parseXmlMessages(xml);

      expect(messages.length).toBe(1);
      expect(messages[0].id).toBe("msg1");
      expect(messages[0].session_id).toBe("sess123");
      expect(messages[0].role).toBe("user");
      expect(messages[0].content).toBe("Hello world");
      expect(messages[0].timestamp).toBe("2024-01-15T10:00:00");
      expect(messages[0].is_input).toBe("1");
      expect(messages[0].is_output).toBe("0");
    });

    it("should parse multiple messages from XML", () => {
      const xml = `<messages>
        <message id="msg1">
          <session_id>sess123</session_id>
          <role>user</role>
          <content>Hello</content>
          <timestamp>2024-01-15T10:00:00</timestamp>
          <is_input>1</is_input>
          <is_output>0</is_output>
          <tool_name></tool_name>
          <finish_reason></finish_reason>
        </message>
        <message id="msg2">
          <session_id>sess123</session_id>
          <role>assistant</role>
          <content>Hi there!</content>
          <timestamp>2024-01-15T10:00:01</timestamp>
          <is_input>0</is_input>
          <is_output>1</is_output>
          <tool_name>bash</tool_name>
          <finish_reason>stop</finish_reason>
        </message>
      </messages>`;

      const messages = parseXmlMessages(xml);

      expect(messages.length).toBe(2);
      expect(messages[0].id).toBe("msg1");
      expect(messages[0].role).toBe("user");
      expect(messages[1].id).toBe("msg2");
      expect(messages[1].role).toBe("assistant");
      expect(messages[1].tool_name).toBe("bash");
      expect(messages[1].finish_reason).toBe("stop");
    });

    it("should return empty array for empty messages tag", () => {
      const xml = `<messages></messages>`;
      const messages = parseXmlMessages(xml);
      expect(messages.length).toBe(0);
    });

    it("should handle messages with escaped XML characters", () => {
      const xml = `<messages>
        <message id="msg1">
          <session_id>sess123</session_id>
          <role>user</role>
          <content>Hello &lt;world&gt; &amp; &quot;test&quot;</content>
          <timestamp>2024-01-15T10:00:00</timestamp>
          <is_input>1</is_input>
          <is_output>0</is_output>
          <tool_name></tool_name>
          <finish_reason></finish_reason>
        </message>
      </messages>`;

      const messages = parseXmlMessages(xml);

      expect(messages.length).toBe(1);
      // Content should preserve escaped entities (user decodes them)
      expect(messages[0].content).toBe("Hello &lt;world&gt; &amp; &quot;test&quot;");
    });

    it("should handle multiline content with newlines", () => {
      const xml = `<messages>
        <message id="msg1">
          <session_id>sess123</session_id>
          <role>assistant</role>
          <content>Line 1
Line 2
Line 3</content>
          <timestamp>2024-01-15T10:00:00</timestamp>
          <is_input>0</is_input>
          <is_output>1</is_output>
          <tool_name></tool_name>
          <finish_reason>stop</finish_reason>
        </message>
      </messages>`;

      const messages = parseXmlMessages(xml);

      expect(messages.length).toBe(1);
      expect(messages[0].content).toBe("Line 1\nLine 2\nLine 3");
    });

    it("should handle empty optional fields", () => {
      const xml = `<messages>
        <message id="msg1">
          <session_id>sess123</session_id>
          <role>user</role>
          <content>Hello</content>
          <timestamp>2024-01-15T10:00:00</timestamp>
          <is_input>0</is_input>
          <is_output>0</is_output>
          <tool_name></tool_name>
          <finish_reason></finish_reason>
        </message>
      </messages>`;

      const messages = parseXmlMessages(xml);

      expect(messages.length).toBe(1);
      expect(messages[0].tool_name).toBe("");
      expect(messages[0].finish_reason).toBe("");
    });
  });

  describe("decodeXmlEntities", () => {
    it("should decode &lt; to <", () => {
      expect(decodeXmlEntities("Hello &lt;world&gt;")).toBe("Hello <world>");
    });

    it("should decode &gt; to >", () => {
      expect(decodeXmlEntities("a &gt; b")).toBe("a > b");
    });

    it("should decode &amp; to &", () => {
      expect(decodeXmlEntities("a &amp; b")).toBe("a & b");
    });

    it("should decode &quot; to \"", () => {
      expect(decodeXmlEntities('Hello &quot;world&quot;')).toBe('Hello "world"');
    });

    it("should decode &apos; to '", () => {
      expect(decodeXmlEntities("Hello &apos;world&apos;")).toBe("Hello 'world'");
    });

    it("should handle mixed entities", () => {
      expect(decodeXmlEntities("&lt;div&gt;Hello &amp; World&lt;/div&gt;")).toBe(
        "<div>Hello & World</div>"
      );
    });

    it("should handle text without entities", () => {
      expect(decodeXmlEntities("Hello World")).toBe("Hello World");
    });

    it("should handle empty string", () => {
      expect(decodeXmlEntities("")).toBe("");
    });

    it("should handle multiple sequential entities", () => {
      expect(decodeXmlEntities("a&lt;b&lt;c")).toBe("a<b<c");
    });
  });

  describe("detectFormat", () => {
    it("should detect XML format from <messages>", () => {
      expect(detectFormat("<messages></messages>")).toBe("xml");
    });

    it("should detect XML format with whitespace before tag", () => {
      expect(detectFormat("  <messages>")).toBe("xml");
    });

    it("should detect JSON format from {", () => {
      expect(detectFormat('{"messages":[]}')).toBe("json");
    });

    it("should detect JSON format with whitespace", () => {
      expect(detectFormat('  {"messages":[]}')).toBe("json");
    });

    it("should return unknown for invalid format", () => {
      expect(detectFormat("plain text")).toBe("unknown");
    });

    it("should return unknown for empty string", () => {
      expect(detectFormat("")).toBe("unknown");
    });
  });
});
