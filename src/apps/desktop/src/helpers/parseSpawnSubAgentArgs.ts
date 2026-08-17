export interface SubAgentArgs {
  /** Required. The name of the pre-configured sub-agent from
   * LlmConfig.sub_agents. Also used as the sub-agent's label in
   * the result XML. */
  agent_name: string
  instruction: string
  tools?: string[]
  timeout_seconds?: number
  inherited_context?: string
}

/**
 * Extract the sub_agents array from an assistant message's tool_calls_json,
 * matched by tool_call_id. Returns null when:
 *   - tool_calls_json is missing/unparseable
 *   - tool_call_id is missing/empty
 *   - no tool call with the given id exists
 *   - the matching tool call is not spawn_sub_agent
 *   - the matching call's arguments are not parseable
 *   - the matching call's sub_agents is not an array
 *   - any sub-agent is missing the required `agent_name` or `instruction`
 *     field, or those fields are not strings, or `agent_name` is empty
 *
 * `arguments` may be either a JSON string (OpenAI format) or an already-parsed
 * object — both are handled.
 */
export function parseSpawnSubAgentArgs(
  toolCallsJson: string | null | undefined,
  toolCallId: string | null | undefined,
): SubAgentArgs[] | null {
  if (!toolCallsJson || !toolCallId) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(toolCallsJson)
  } catch {
    return null
  }

  if (!Array.isArray(parsed)) return null

  const match = parsed.find(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    (tc: any) => tc && tc.id === toolCallId && tc.function?.name === 'spawn_sub_agent',
  )
  if (!match) return null

  const rawArgs = match.function?.arguments
  if (rawArgs == null) return null

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  let args: any
  if (typeof rawArgs === 'string') {
    try {
      args = JSON.parse(rawArgs)
    } catch {
      return null
    }
  } else if (typeof rawArgs === 'object') {
    args = rawArgs
  } else {
    return null
  }

  if (!args || !Array.isArray(args.sub_agents)) return null

  // Defensive copy: only include known fields, don't trust the LLM's shape.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  return args.sub_agents.map((sa: any) => {
    if (
      !sa ||
      typeof sa.agent_name !== 'string' ||
      sa.agent_name.length === 0 ||
      typeof sa.instruction !== 'string'
    ) {
      return null
    }
    const result: SubAgentArgs = {
      agent_name: sa.agent_name,
      instruction: sa.instruction,
    }
    if (Array.isArray(sa.tools)) result.tools = sa.tools
    if (typeof sa.timeout_seconds === 'number') result.timeout_seconds = sa.timeout_seconds
    if (typeof sa.inherited_context === 'string') result.inherited_context = sa.inherited_context
    return result
  }).filter((sa: SubAgentArgs | null): sa is SubAgentArgs => sa !== null)
}
