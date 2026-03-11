/**
 * Agent type definitions for Kerjabot
 * Defines the different agent types and their configurations
 */

/** Available agent types in the system */
export enum AgentType {
  Agent = 'Agent',
  Compaction = 'CompactionAgent',
}

/** Agent configuration with readonly properties for immutability */
export interface AgentConfig {
  readonly id: string;
  readonly type: AgentType;
  readonly name: string;
  readonly description: string;
  readonly icon: string;
  readonly color: string;
  readonly temperature: number;
  readonly maxTokens: number;
  readonly systemPrompt: string;
  readonly skills: readonly string[];
}

/** Agent state in a session */
export interface AgentState {
  readonly agentId: string;
  readonly status: AgentStatus;
  readonly currentTask?: string;
  readonly startTime?: Date;
  readonly endTime?: Date;
}

/** Agent execution status */
export enum AgentStatus {
  Idle = 'idle',
  Working = 'working',
  Waiting = 'waiting',
  Error = 'error',
  Completed = 'completed',
}

/** Agent capability definition */
export interface AgentCapability {
  readonly name: string;
  readonly description: string;
  readonly tools: readonly string[];
}

/** Agent selection event */
export interface AgentSelectionEvent {
  readonly agentId: string;
  readonly timestamp: Date;
}
