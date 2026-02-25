import { connect } from "net";
import { log } from "./logger";

const SOCKET_PATH = "/tmp/agent.sock";

let currentSessionId: string = generateSessionId();

function generateSessionId(): string {
  return `session-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
}

export function getSessionId(): string {
  return currentSessionId;
}

export function newSession(): void {
  currentSessionId = generateSessionId();
}

export interface IPCMessage {
  command_type: string;
  session_id?: string;
  message: string;
}

export interface ToolCall {
  id: string;
  type: string;
  function: {
    name: string;
    arguments: string;
  };
}

export interface Message {
  role: string;
  content: string | null;
  tool_calls: ToolCall[] | null;
}

export interface Choice {
  index: number;
  message: Message;
  finish_reason: string | null;
}

export interface AgentResponse {
  choices: Choice[];
}

export interface ToolResult {
  tool_call_id: string;
  tool_name: string;
  result: string;
}

function extractXmlTag(xml: string, tag: string): string | null {
  const startTag = `<${tag}>`;
  const endTag = `</${tag}>`;
  const start = xml.indexOf(startTag);
  if (start === -1) return null;
  const contentStart = start + startTag.length;
  const end = xml.indexOf(endTag, contentStart);
  if (end === -1) return null;
  return xml.slice(contentStart, end);
}

function extractXmlAttributes(xml: string, tag: string): Record<string, string> {
  const tagStart = `<${tag}`;
  const tagEnd = `</${tag}>`;
  const start = xml.indexOf(tagStart);
  if (start === -1) return {};
  const tagEndPos = xml.indexOf(">", start);
  if (tagEndPos === -1) return {};
  
  const attrsStr = xml.slice(start + tagStart.length, tagEndPos);
  const attrs: Record<string, string> = {};
  const attrRegex = /(\w+)="([^"]*)"/g;
  let match;
  while ((match = attrRegex.exec(attrsStr)) !== null) {
    attrs[match[1]] = match[2];
  }
  return attrs;
}

function parseToolCallsXml(xml: string): ToolCall[] {
  const toolCalls: ToolCall[] = [];
  let remaining = xml;
  
  while (remaining.includes("<tool_call ")) {
    const start = remaining.indexOf("<tool_call ");
    const endTag = remaining.indexOf("</tool_call>", start);
    if (endTag === -1) break;
    
    const toolCallXml = remaining.slice(start, endTag + "</tool_call>".length);
    const attrs = extractXmlAttributes(toolCallXml, "tool_call");
    
    const funcStart = toolCallXml.indexOf("<function>");
    const funcEnd = toolCallXml.indexOf("</function>");
    if (funcStart === -1 || funcEnd === -1) {
      remaining = remaining.slice(start + 1);
      continue;
    }
    
    const funcXml = toolCallXml.slice(funcStart, funcEnd + "</function>".length);
    const name = extractXmlTag(funcXml, "name") || "";
    const args = extractXmlTag(funcXml, "arguments") || "";
    
    toolCalls.push({
      id: attrs.id || "",
      type: attrs.type || "function",
      function: { name, arguments: args }
    });
    
    remaining = remaining.slice(endTag + "</tool_call>".length);
  }
  
  return toolCalls;
}

export function parseAgentResponse(raw: string): AgentResponse | null {
  try {
    const choice: Choice = {
      index: 0,
      message: {
        role: "assistant",
        content: extractXmlTag(raw, "content"),
        tool_calls: parseToolCallsXml(raw),
      },
      finish_reason: extractXmlTag(raw, "finish_reason"),
    };
    return { choices: [choice] };
  } catch (e) {
    log("parseAgentResponse error: " + e);
    return null;
  }
}

export function parseToolResult(raw: string): ToolResult | null {
  try {
    return {
      tool_call_id: extractXmlTag(raw, "tool_call_id") || "",
      tool_name: extractXmlTag(raw, "tool_name") || "",
      result: extractXmlTag(raw, "result") || "",
    };
  } catch (e) {
    log("parseToolResult error: " + e);
    return null;
  }
}

export function extractContent(response: AgentResponse): string {
  const choice = response.choices[0];
  if (!choice?.message?.content) return "";
  return choice.message.content;
}

export function extractThought(content: string): string | null {
  const match = content.match(/<thought>([\s\S]*?)<\/thought>/);
  return match ? match[1].trim() : null;
}

export function extractMarkdown(content: string): string | null {
  const match = content.match(/<markdown>([\s\S]*?)<\/markdown>/);
  return match ? match[1].trim() : null;
}

export function extractPlainContent(content: string): string {
  let plain = content;
  plain = plain.replace(/<thought>[\s\S]*?<\/thought>/g, "");
  plain = plain.replace(/<markdown>[\s\S]*?<\/markdown>/g, "");
  return plain.trim();
}

export function parseAndFormatContent(content: string): { thought?: string; markdown?: string; plain: string } {
  const thought = extractThought(content);
  const markdown = extractMarkdown(content);
  
  if (thought || markdown) {
    return {
      thought: thought ?? undefined,
      markdown: markdown ?? undefined,
      plain: extractPlainContent(content),
    };
  }
  
  return { plain: content };
}

export function getSessionId(): string {
  return currentSessionId;
}

export function newSession(): void {
  currentSessionId = generateSessionId();
}

export interface IPCMessage {
  command_type: string;
  session_id?: string;
  message: string;
}

export interface ToolCall {
  id: string;
  type: string;
  function: {
    name: string;
    arguments: string;
  };
}

export interface Message {
  role: string;
  content: string | null;
  tool_calls: ToolCall[] | null;
}

export interface Choice {
  index: number;
  message: Message;
  finish_reason: string | null;
}

export interface AgentResponse {
  choices: Choice[];
}

export interface ToolResult {
  type: "tool_result";
  tool_call_id: string;
  tool_name: string;
  result: string;
}

export function extractContent(response: AgentResponse): string {
  const choice = response.choices[0];
  if (!choice?.message?.content) return "";
  return choice.message.content;
}

export function extractThought(content: string): string | null {
  const match = content.match(/<thought>([\s\S]*?)<\/thought>/);
  return match ? match[1].trim() : null;
}

export function extractMarkdown(content: string): string | null {
  const match = content.match(/<markdown>([\s\S]*?)<\/markdown>/);
  return match ? match[1].trim() : null;
}

export function extractPlainContent(content: string): string {
  let plain = content;
  plain = plain.replace(/<thought>[\s\S]*?<\/thought>/g, "");
  plain = plain.replace(/<markdown>[\s\S]*?<\/markdown>/g, "");
  return plain.trim();
}

export function parseAndFormatContent(content: string): { thought?: string; markdown?: string; plain: string } {
  const thought = extractThought(content);
  const markdown = extractMarkdown(content);
  
  if (thought || markdown) {
    return {
      thought: thought ?? undefined,
      markdown: markdown ?? undefined,
      plain: extractPlainContent(content),
    };
  }
  
  return { plain: content };
}

export async function sendIpcMessage(message: IPCMessage): Promise<string> {
  const fullMessage = {
    command_type: message.command_type,
    session_id: message.session_id ?? currentSessionId,
    message: message.message,
  };
  const data = JSON.stringify(fullMessage);
  
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    
    const socket = connect(SOCKET_PATH, () => {
      socket.write(data + "\n", () => {
        // Don't end immediately - wait for response
      });
    });
    
    socket.on("data", (chunk: Buffer) => {
      chunks.push(chunk);
    });
    
    socket.on("close", () => {
      if (chunks.length > 0) {
        resolve(Buffer.concat(chunks).toString());
      } else {
        resolve("");
      }
    });
    
    socket.on("error", () => {
      resolve("");
    });
  });
}
