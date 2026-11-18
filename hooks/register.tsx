import type { Register } from 'claude-code'

import { buildRow } from './format'

export const register: Register = on => {
  // Synchronous on purpose: a terminal row whose first answer takes over 300 ms is drawn blank.
  on('ui.render', { component: 'AgentRow' }, ($, e, next) => {
    // A non-empty body means a subagentStatusLine command the person configured drew the row.
    if (e.props.body) return next(e)

    const agent = e.props
    const effort = agent.effort ?? agent.lastRequest?.effort
    const row = buildRow(
      {
        description: agent.description,
        model: agent.model,
        effort: effort === undefined ? undefined : String(effort),
        tokens: agent.tokenCount,
        window: agent.contextWindowSize,
      },
      agent.columns ?? 0,
    )
    const { Text } = $.ui.resolve(e)

    return (
      <Text>
        {row.map(s => (
          <Text color={s.color}>{s.text}</Text>
        ))}
      </Text>
    )
  })
}
