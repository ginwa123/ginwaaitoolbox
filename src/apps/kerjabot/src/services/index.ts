/**
 * Services barrel export
 * Central export point for all service modules
 */

export {
  getAllAgents,
  getAgentById,
  getAgentByType,
  getDefaultAgent,
  filterAgentsBySkill,
  getAgentCapabilities,
  validateAgentConfig,
  getAgentColorClass,
  getAgentStatusText,
} from './agentService';

export { 
  chatService, 
  streamMessage, 
  executeTool, 
  sendMessage, 
  cancelStream,
  createSession,
  getSessions,
  checkBackend,
  pingSession,
} from './chatService';

export type { AgentConfig, AgentType, AgentCapability } from '~/types';
