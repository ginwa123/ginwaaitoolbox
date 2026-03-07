/**
 * Agent service with pure functions for agent operations
 * Mock implementation for frontend-only development
 */

import type { AgentConfig, AgentCapability } from '~/types';
import { AgentType, AgentStatus } from '~/types';

/** Mock agent configurations */
const mockAgents: AgentConfig[] = [
  {
    id: 'general',
    type: AgentType.General,
    name: 'General Agent',
    description: 'Versatile agent for general-purpose tasks and coordination',
    icon: 'Bot',
    color: 'agent-general',
    temperature: 0.7,
    maxTokens: 4096,
    systemPrompt:
      'You are a helpful general-purpose AI assistant. You can handle a wide variety of tasks and coordinate with specialized agents when needed.',
    skills: ['conversation', 'coordination', 'task-delegation'],
  },
  {
    id: 'exploration',
    type: AgentType.Exploration,
    name: 'Exploration Agent',
    description: 'Discovers and analyzes codebases, files, and project structures',
    icon: 'Search',
    color: 'agent-exploration',
    temperature: 0.3,
    maxTokens: 4096,
    systemPrompt:
      'You are an exploration specialist. Your job is to discover, analyze, and understand codebases, files, and project structures. Be thorough and systematic.',
    skills: ['file-exploration', 'code-analysis', 'pattern-recognition'],
  },
  {
    id: 'planning',
    type: AgentType.Planning,
    name: 'Planning Agent',
    description: 'Creates detailed plans and strategies for complex tasks',
    icon: 'Map',
    color: 'agent-planning',
    temperature: 0.5,
    maxTokens: 4096,
    systemPrompt:
      'You are a planning specialist. Break down complex tasks into manageable steps and create detailed execution plans.',
    skills: ['task-planning', 'strategy', 'dependency-analysis'],
  },
  {
    id: 'executing',
    type: AgentType.Executing,
    name: 'Executing Agent',
    description: 'Implements solutions and writes code with precision',
    icon: 'Code',
    color: 'agent-executing',
    temperature: 0.2,
    maxTokens: 4096,
    systemPrompt:
      'You are an execution specialist. Implement solutions, write code, and make changes with precision and attention to detail.',
    skills: ['code-generation', 'refactoring', 'implementation'],
  },
  {
    id: 'review',
    type: AgentType.Review,
    name: 'Review Agent',
    description: 'Reviews code, plans, and outputs for quality and correctness',
    icon: 'CheckCircle',
    color: 'agent-review',
    temperature: 0.3,
    maxTokens: 4096,
    systemPrompt:
      'You are a review specialist. Carefully examine code, plans, and outputs for quality, correctness, and adherence to best practices.',
    skills: ['code-review', 'quality-assurance', 'verification'],
  },
  {
    id: 'knowledge',
    type: AgentType.Knowledge,
    name: 'Knowledge Agent',
    description: 'Manages and retrieves information from knowledge bases',
    icon: 'BookOpen',
    color: 'agent-knowledge',
    temperature: 0.4,
    maxTokens: 4096,
    systemPrompt:
      'You are a knowledge specialist. Manage, retrieve, and synthesize information from various knowledge sources.',
    skills: ['information-retrieval', 'synthesis', 'documentation'],
  },
  {
    id: 'compaction',
    type: AgentType.Compaction,
    name: 'Compaction Agent',
    description: 'Summarizes and compacts conversation history',
    icon: 'Minimize2',
    color: 'agent-compaction',
    temperature: 0.3,
    maxTokens: 4096,
    systemPrompt:
      'You are a compaction specialist. Summarize and condense information while preserving essential context and meaning.',
    skills: ['summarization', 'context-management', 'compression'],
  },
];

/** Get all available agents */
export const getAllAgents = (): readonly AgentConfig[] => {
  return Object.freeze([...mockAgents]);
};

/** Get agent by ID */
export const getAgentById = (id: string): AgentConfig | null => {
  return mockAgents.find((a) => a.id === id) ?? null;
};

/** Get agent by type */
export const getAgentByType = (type: AgentType): AgentConfig | null => {
  return mockAgents.find((a) => a.type === type) ?? null;
};

/** Get default agent */
export const getDefaultAgent = (): AgentConfig => {
  return mockAgents[0];
};

/** Filter agents by capability */
export const filterAgentsBySkill = (
  skill: string
): readonly AgentConfig[] => {
  return Object.freeze(mockAgents.filter((a) => a.skills.includes(skill)));
};

/** Get agent capabilities */
export const getAgentCapabilities = (
  agentId: string
): readonly AgentCapability[] => {
  const agent = getAgentById(agentId);
  if (!agent) return Object.freeze([]);

  return Object.freeze(
    agent.skills.map((skill) => ({
      name: skill,
      description: `Capability: ${skill}`,
      tools: [],
    }))
  );
};

/** Validate agent configuration */
export const validateAgentConfig = (
  config: Partial<AgentConfig>
): { valid: boolean; errors: string[] } => {
  const errors: string[] = [];

  if (!config.id) errors.push('Agent ID is required');
  if (!config.name) errors.push('Agent name is required');
  if (!config.type) errors.push('Agent type is required');
  if (!config.systemPrompt) errors.push('System prompt is required');

  if (config.temperature !== undefined) {
    if (config.temperature < 0 || config.temperature > 2) {
      errors.push('Temperature must be between 0 and 2');
    }
  }

  if (config.maxTokens !== undefined) {
    if (config.maxTokens < 1 || config.maxTokens > 8192) {
      errors.push('Max tokens must be between 1 and 8192');
    }
  }

  return { valid: errors.length === 0, errors };
};

/** Get agent color class */
export const getAgentColorClass = (agentType: AgentType): string => {
  const colorMap: Record<AgentType, string> = {
    [AgentType.General]: 'bg-agent-general',
    [AgentType.Exploration]: 'bg-agent-exploration',
    [AgentType.Planning]: 'bg-agent-planning',
    [AgentType.Executing]: 'bg-agent-executing',
    [AgentType.Review]: 'bg-agent-review',
    [AgentType.Knowledge]: 'bg-agent-knowledge',
    [AgentType.Compaction]: 'bg-agent-compaction',
  };
  return colorMap[agentType] ?? 'bg-gray-500';
};

/** Get agent status text */
export const getAgentStatusText = (status: AgentStatus): string => {
  const statusMap: Record<AgentStatus, string> = {
    [AgentStatus.Idle]: 'Idle',
    [AgentStatus.Working]: 'Working',
    [AgentStatus.Waiting]: 'Waiting',
    [AgentStatus.Error]: 'Error',
    [AgentStatus.Completed]: 'Completed',
  };
  return statusMap[status] ?? 'Unknown';
};
