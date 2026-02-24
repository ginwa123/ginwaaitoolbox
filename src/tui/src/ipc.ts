import { connect } from "net";

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

export function parseAgentResponse(raw: string): AgentResponse | null {
  try {
    return JSON.parse(raw) as AgentResponse;
  } catch {
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
