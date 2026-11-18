import type { AgentInfo } from 'claude-code'
import type { Engine } from 'claude-code/testing'
import { expect, test } from 'claude-code/testing'

import { MODEL_COLOR, VALUE_COLOR } from './format'

type RowProps = AgentInfo & {
  rowIds: string[]
  columns?: number
  body?: string
  isHidden: boolean
}

const agent = (over: Partial<RowProps> = {}): RowProps => ({
  id: 'a1',
  description: 'Trivial subagent for statusline test',
  type: 'general-purpose',
  status: 'running',
  kind: 'local_agent',
  taskStatus: 'running',
  label: 'Trivial subagent for statusline test',
  startTime: 0,
  cwd: '/repo',
  model: 'claude-opus-4-8',
  effort: 'high',
  contextWindowSize: 1000000,
  tokenCount: 420000,
  tokenSamples: [420000],
  hasRow: true,
  rowIds: ['a1'],
  isHidden: false,
  ...over,
})

const ROW = { plugin: 'cc-statusline', component: 'AgentRow', requestId: 'a1' } as const

/** The texts and colours of every Text drawn, outermost first. */
const drawRow = async ($: Engine, props: RowProps) => {
  const ui = await $.ui.mount({ ...ROW, surface: 'terminal', props })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => ({
    text: t.text,
    color: t.props.color,
  }))
  await ui.unmount()
  return texts
}

test('a subagent row: model, effort, ctx, description and tokens, coloured', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  expect(await drawRow($, agent())).toEqual([
    { text: 'Opus-4.8 (high) · ctx 42% · Trivial subagent for statusline test · 420.0k tok', color: undefined },
    { text: 'Opus-4.8 (high)', color: MODEL_COLOR },
    { text: ' · ', color: undefined },
    { text: 'ctx 42%', color: 'rgb(40,203,0)' },
    { text: ' · ', color: undefined },
    { text: 'Trivial subagent for statusline test', color: undefined },
    { text: ' · ', color: undefined },
    { text: '420.0k tok', color: VALUE_COLOR },
  ])
})

test('effort falls back to the last request, a number as written', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  const inherited = agent({ effort: undefined, lastRequest: { at: 0, model: 'claude-opus-4-8', effort: 'max' } })
  expect((await drawRow($, inherited))[0]?.text).toBe(
    'Opus-4.8 (max) · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
  expect((await drawRow($, agent({ effort: 32000 })))[0]?.text).toBe(
    'Opus-4.8 (32000) · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
  expect((await drawRow($, agent({ effort: undefined })))[0]?.text).toBe(
    'Opus-4.8 · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
})

test('no ctx segment without a known context window', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  const row = agent({ contextWindowSize: undefined, tokenCount: 0 })
  expect((await drawRow($, row))[0]?.text).toBe(
    'Opus-4.8 (high) · Trivial subagent for statusline test · 0 tok',
  )
})

test('a teammate with no model gets the degraded row', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  const teammate = agent({
    id: 't1',
    type: 'teammate',
    kind: 'in_process_teammate',
    status: 'idle',
    description: 'researcher',
    model: undefined,
    effort: undefined,
    contextWindowSize: undefined,
    tokenCount: 0,
  })
  expect((await drawRow($, teammate))[0]?.text).toBe('— · researcher · 0 tok')
})

test('a narrow row cuts the description first', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  expect((await drawRow($, agent({ columns: 51 })))[0]?.text).toBe(
    'Opus-4.8 (high) · ctx 42% · Trivial s… · 420.0k tok',
  )
})

test('a body the person configured passes through untouched', async ($, on) => {
  const seen: (string | undefined)[] = []
  on('ui.render', ($, e) => {
    if (e.component === 'AgentRow') seen.push(e.props.body)
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  expect(await drawRow($, agent({ body: 'from my script' }))).toEqual([
    { text: 'engine', color: undefined },
  ])
  expect(seen).toEqual(['from my script'])
})

test('an empty configured body still gets the mod row', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  expect((await drawRow($, agent({ body: '' })))[0]?.text).toBe(
    'Opus-4.8 (high) · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
})

test('nothing is drawn above the prompt', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  const ui = await $.ui.mount({
    plugin: 'cc-statusline',
    surface: 'terminal',
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
  })
  expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toEqual(['engine'])
  await ui.unmount()
})
