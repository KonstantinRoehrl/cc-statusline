import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { AgentRecord } from '../types'
import { buildRow } from './format'

const records = atom(
  { plugin: 'cc-statusline', key: 'records' } as const,
  {} as Record<string, AgentRecord>,
)
const mainModel = atom({ plugin: 'cc-statusline', key: 'mainModel' } as const, '')

export const register: Register = on => {
  on('turn.step', async function* ($, e, next) {
    const agentId = e.agentId

    if (agentId === undefined) {
      if ((await read($, mainModel)) !== e.model) {
        await update($, mainModel, () => e.model)
      }
    } else {
      const effort = typeof e.effort === 'string' ? e.effort : undefined
      // Drawing is pure (state writes are denied in ui.render), so records of agents the list
      // has dropped are pruned here, when the next subagent step is recorded.
      const listed = new Set((await $.agent.list()).map(a => a.id))
      await update($, records, all => ({
        ...Object.fromEntries(Object.entries(all).filter(([id]) => listed.has(id))),
        [agentId]: { ...all[agentId], model: e.model, effort },
      }))
    }

    for await (const chunk of next(e)) {
      if (agentId !== undefined && chunk.kind === 'stop' && chunk.usage) {
        const u = chunk.usage
        const tokens =
          u.input_tokens +
          u.cache_read_input_tokens +
          u.cache_creation_input_tokens +
          u.output_tokens
        await update($, records, all => ({
          ...all,
          [agentId]: { ...all[agentId], tokens },
        }))
      }
      yield chunk
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)

    const agents = (await $.agent.list()).filter(a => a.type !== 'teammate')
    if (agents.length === 0) return next(e)

    const [all, main, usage] = await Promise.all([
      read($, records),
      read($, mainModel),
      $.session.usage(),
    ])
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {agents.map(agent => {
          const record = all[agent.id]
          const window =
            record?.model !== undefined && record.model === main
              ? usage.context.window
              : undefined
          const row = buildRow(
            { description: agent.description, ...record, window },
            e.props.bodyColumns,
          )
          return (
            <Text>
              {row.map(s => (
                <Text color={s.color}>{s.text}</Text>
              ))}
            </Text>
          )
        })}
      </Box>
    )
  })
}
