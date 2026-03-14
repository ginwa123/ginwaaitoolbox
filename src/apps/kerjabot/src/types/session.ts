/**
 * Session type definitions for Kerjabot
 * Defines session state, status, and related types
 */

import type { AgentType } from './agent';

/** Session status enumeration */
export enum SessionStatus {
  Active = 'active',
  Idle = 'idle',
  Paused = 'paused',
  Completed = 'completed',
  Error = 'error',
}

/** Session model with readonly properties */
export interface Session {
  readonly id: string;
  readonly name: string;
  readonly status: SessionStatus;
  readonly agentType: AgentType;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly messageCount: number;
  readonly tokenCount: number;
  readonly metadata?: SessionMetadata;
}

/** Session metadata for additional context */
export interface SessionMetadata {
  readonly description?: string;
  readonly tags?: readonly string[];
  readonly source?: string;
  readonly planId?: string;
}

/** Session creation parameters */
export interface CreateSessionParams {
  readonly id?: string;
  readonly name: string;
  readonly agentType: AgentType;
  readonly description?: string;
  readonly tags?: readonly string[];
  readonly metadata?: SessionMetadata;
}

/** Session update parameters */
export interface UpdateSessionParams {
  readonly name?: string;
  readonly status?: SessionStatus;
  readonly metadata?: Partial<SessionMetadata>;
}

/** Session summary for list views */
export interface SessionSummary {
  readonly id: string;
  readonly name: string;
  readonly status: SessionStatus;
  readonly agentType: AgentType;
  readonly lastMessageAt?: Date;
  readonly messageCount: number;
  readonly preview?: string;
}

/** Session filter options */
export interface SessionFilter {
  readonly status?: SessionStatus;
  readonly agentType?: AgentType;
  readonly searchQuery?: string;
  readonly tags?: readonly string[];
}

/** Session sort options */
export enum SessionSortBy {
  CreatedAt = 'createdAt',
  UpdatedAt = 'updatedAt',
  Name = 'name',
  MessageCount = 'messageCount',
}

/** Session sort direction */
export enum SortDirection {
  Asc = 'asc',
  Desc = 'desc',
}

/** Session sort configuration */
export interface SessionSort {
  readonly by: SessionSortBy;
  readonly direction: SortDirection;
}

/** Session statistics */
export interface SessionStats {
  readonly totalSessions: number;
  readonly activeSessions: number;
  readonly totalMessages: number;
  readonly totalTokens: number;
  readonly averageMessagesPerSession: number;
}

/** Create a new session */
export const createSession = (
  params: CreateSessionParams,
  id?: string
): Session => {
  const now = new Date();
  return {
    id: id ?? generateSessionId(),
    name: params.name,
    status: SessionStatus.Active,
    agentType: params.agentType,
    createdAt: now,
    updatedAt: now,
    messageCount: 0,
    tokenCount: 0,
    metadata: {
      description: params.description,
      tags: params.tags,
    },
  };
};

/** Update session with new values */
export const updateSession = (
  session: Session,
  params: UpdateSessionParams
): Session => ({
  ...session,
  ...(params.name && { name: params.name }),
  ...(params.status && { status: params.status }),
  ...(params.metadata && {
    metadata: { ...session.metadata, ...params.metadata },
  }),
  updatedAt: new Date(),
});

/** Generate unique session ID */
function generateSessionId(): string {
  return `sess_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}
