/**
 * Mock sessions for development
 */

import type { Session, SessionSummary } from '~/types';
import { SessionStatus, AgentType } from '~/types';

export const mockSessions: Session[] = [
  {
    id: 'sess_demo',
    name: 'Project Structure Discussion',
    status: SessionStatus.Active,
    agentType: AgentType.General,
    createdAt: new Date(Date.now() - 1000 * 60 * 60 * 2),
    updatedAt: new Date(Date.now() - 1000 * 60 * 5),
    messageCount: 6,
    tokenCount: 220,
    metadata: {
      description: 'Understanding the Kerjabot project structure',
      tags: ['exploration', 'onboarding'],
    },
  },
  {
    id: 'sess_2',
    name: 'Code Review Session',
    status: SessionStatus.Completed,
    agentType: AgentType.Review,
    createdAt: new Date(Date.now() - 1000 * 60 * 60 * 24),
    updatedAt: new Date(Date.now() - 1000 * 60 * 60 * 23),
    messageCount: 12,
    tokenCount: 450,
    metadata: {
      description: 'Reviewing authentication implementation',
      tags: ['review', 'auth'],
    },
  },
  {
    id: 'sess_3',
    name: 'Feature Planning',
    status: SessionStatus.Paused,
    agentType: AgentType.Planning,
    createdAt: new Date(Date.now() - 1000 * 60 * 60 * 48),
    updatedAt: new Date(Date.now() - 1000 * 60 * 60 * 47),
    messageCount: 8,
    tokenCount: 320,
    metadata: {
      description: 'Planning the new dashboard feature',
      tags: ['planning', 'dashboard'],
    },
  },
];

export const mockSessionSummaries: SessionSummary[] = mockSessions.map((s) => ({
  id: s.id,
  name: s.name,
  status: s.status,
  agentType: s.agentType,
  messageCount: s.messageCount,
  lastMessageAt: s.updatedAt,
  preview: s.metadata?.description,
}));
