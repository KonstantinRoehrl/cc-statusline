import type { AgentInfo, TurnUsage } from 'claude-code'
import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'cc-statusline',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: true,
    maxRows: 10,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 9 },
    view: {},
  },
} as const

const agent = (id: string, over: Partial<AgentInfo> = {}): AgentInfo => ({
  id,
  description: `task ${id}`,
  type: 'general-purpose',
  status: 'running',
  ...over,
})

const stop = (usage: TurnUsage | null) => ({
  kind: 'stop' as const,
  stopReason: 'end_turn' as const,
  usage,
})

const USAGE: TurnUsage = {
  model: 'claude-opus-4-8',
  input_tokens: 100,
  output_tokens: 200,
  cache_read_input_tokens: 40000,
  cache_creation_input_tokens: 500,
}

test('no band without subagents, on a survey, or for teammates alone', async ($, on) => {
  let agents: AgentInfo[] = []
  on('agent.list', () => ({ value: agents }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 1000000 }, rateLimits: [] },
  }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  const empty = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await empty.findAll({ type: 'Text' })).map(t => t.text)).toEqual(['engine'])
  await empty.unmount()

  agents = [agent('a1')]
  const survey = await $.ui.mount({
    ...BAND,
    surface: 'terminal',
    props: { ...BAND.props, hasSurvey: true },
  })
  expect((await survey.findAll({ type: 'Text' })).map(t => t.text)).toEqual(['engine'])
  await survey.unmount()

  agents = [agent('t1', { type: 'teammate', status: 'idle' })]
  const team = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await team.findAll({ type: 'Text' })).map(t => t.text)).toEqual(['engine'])
  await team.unmount()
})

test('one row per agent, finished ones included, fed by turn.step', async ($, on) => {
  on('agent.list', () => ({
    value: [agent('a1', { description: 'Review fix' }), agent('a2', { status: 'completed' })],
  }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 1000000 }, rateLimits: [] },
  }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  on('turn.step', async function* (_, e) {
    const usage = e.agentId === undefined ? null : USAGE
    yield stop(usage)
    return {
      turnId: e.turnId,
      index: e.index,
      answer: '',
      toolUses: [],
      stopReason: 'end_turn' as const,
      usage,
    }
  })

  const step = (agentId: string | undefined, model: string, effort?: 'high') =>
    $.turn.step({ turnId: 't', index: 0, model, effort, messageCount: 1, agentId })
  const drain = async (s: AsyncIterable<unknown>) => {
    for await (const _ of s) void _
  }
  await drain(step(undefined, 'claude-opus-4-8'))
  await drain(step('a1', 'claude-opus-4-8', 'high'))
  await drain(step('a2', 'claude-haiku-4-5-20251001'))

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const rows = await ui.findAll({ type: 'Text' })
  const texts = rows.map(r => r.text)
  expect(texts).toContain('Opus-4.8 (high) · ctx 4% · Review fix · 40.8k tok')
  expect(texts).toContain('Haiku-4.5 · task a2 · 40.8k tok')
  await ui.unmount()
})
