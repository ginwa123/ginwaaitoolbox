/**
 * Tool type definitions for Kerjabot
 * Defines tool calls, results, and tool-related types
 */

/** Available tool types */
export enum ToolType {
  Bash = 'bash',
  ChangeAgent = 'change_agent',
  GetSkill = 'get_skill',
  ListSkills = 'list_skills',
  ReadFile = 'read_file',
  WriteFile = 'write_file',
  EditFile = 'edit_file',
  SearchFiles = 'search_files',
  ListDir = 'list_dir',
}

/** Tool call from assistant */
export interface ToolCall {
  readonly id: string;
  readonly type: ToolType;
  readonly name: string;
  readonly arguments: Readonly<Record<string, unknown>>;
  readonly timestamp: Date;
}

/** Tool execution result */
export interface ToolResult {
  readonly success: boolean;
  readonly output?: string;
  readonly error?: string;
  readonly exitCode?: number;
  readonly duration: number;
  readonly timestamp: Date;
}

/** Tool call with its result */
export interface ToolCallWithResult {
  readonly call: ToolCall;
  readonly result: ToolResult;
}

/** Tool definition for available tools */
export interface ToolDefinition {
  readonly name: string;
  readonly type: ToolType;
  readonly description: string;
  readonly parameters: ToolParameter[];
}

/** Tool parameter definition */
export interface ToolParameter {
  readonly name: string;
  readonly type: 'string' | 'number' | 'boolean' | 'array' | 'object';
  readonly description: string;
  readonly required: boolean;
  readonly default?: unknown;
}

/** Bash tool specific arguments */
export interface BashArguments {
  readonly command: string;
  readonly cwd?: string;
  readonly timeout?: number;
  readonly maxOutput?: number;
}

/** Change agent tool arguments */
export interface ChangeAgentArguments {
  readonly agent: string;
  readonly message: string;
  readonly temperature?: number;
}

/** Get skill tool arguments */
export interface GetSkillArguments {
  readonly skillName: string;
}

/** File operation arguments */
export interface FileReadArguments {
  readonly filePath: string;
}

export interface FileWriteArguments {
  readonly filePath: string;
  readonly content: string;
}

export interface FileEditArguments {
  readonly filePath: string;
  readonly oldString: string;
  readonly newString: string;
}

export interface SearchFilesArguments {
  readonly query: string;
  readonly path?: string;
  readonly filePattern?: string;
}

export interface ListDirArguments {
  readonly path: string;
  readonly maxDepth?: number;
}

/** Tool call status */
export enum ToolCallStatus {
  Pending = 'pending',
  Executing = 'executing',
  Completed = 'completed',
  Failed = 'failed',
  Cancelled = 'cancelled',
}

/** Tool call with execution status */
export interface ToolCallState {
  readonly call: ToolCall;
  readonly status: ToolCallStatus;
  readonly result?: ToolResult;
  readonly startTime?: Date;
  readonly endTime?: Date;
}

/** Create a new tool call */
export const createToolCall = (
  type: ToolType,
  name: string,
  args: Record<string, unknown>,
  id?: string
): ToolCall => ({
  id: id ?? generateToolCallId(),
  type,
  name,
  arguments: Object.freeze({ ...args }),
  timestamp: new Date(),
});

/** Create a tool result */
export const createToolResult = (
  success: boolean,
  duration: number,
  output?: string,
  error?: string,
  exitCode?: number
): ToolResult => ({
  success,
  output,
  error,
  exitCode,
  duration,
  timestamp: new Date(),
});

/** Generate unique tool call ID */
function generateToolCallId(): string {
  return `tool_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}
