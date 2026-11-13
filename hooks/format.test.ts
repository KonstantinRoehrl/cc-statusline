import { expect, test } from 'claude-code/testing'

import { buildRow, fmtK, fmtModelName, gradientColor } from './format'

const plain = (row: { text: string }[]): string => row.map(s => s.text).join('')

test('fmtModelName shortens ids like the statusline', async () => {
  expect(fmtModelName('claude-sonnet-5')).toBe('Sonnet-5')
  expect(fmtModelName('claude-opus-4-8')).toBe('Opus-4.8')
  expect(fmtModelName('claude-haiku-4-5-20251001')).toBe('Haiku-4.5')
  expect(fmtModelName('gpt-x')).toBe('gpt-x')
  expect(fmtModelName(undefined)).toBe('—')
  expect(fmtModelName('')).toBe('—')
})

test('fmtK abbreviates thousands and keeps small counts raw', async () => {
  expect(fmtK(439)).toBe('439')
  expect(fmtK(1234)).toBe('1.2k')
  expect(fmtK(40800)).toBe('40.8k')
  expect(fmtK(420000)).toBe('420.0k')
})

test('gradientColor follows gradient_worse(pct, 40, 65)', async () => {
  expect(gradientColor(10, 40, 65)).toBe('rgb(0,215,0)')
  expect(gradientColor(40, 40, 65)).toBe('rgb(0,215,0)')
  expect(gradientColor(42, 40, 65)).toBe('rgb(40,203,0)')
  expect(gradientColor(52, 40, 65)).toBe('rgb(244,139,0)')
  expect(gradientColor(60, 40, 65)).toBe('rgb(255,54,0)')
  expect(gradientColor(65, 40, 65)).toBe('rgb(255,0,0)')
  expect(gradientColor(90, 40, 65)).toBe('rgb(255,0,0)')
})

test('buildRow lays out a full row in the old order and colors', async () => {
  const row = buildRow(
    {
      description: 'Trivial subagent for statusline test',
      model: 'claude-opus-4-8',
      effort: 'high',
      tokens: 420000,
      window: 1000000,
    },
    0,
  )
  expect(plain(row)).toBe(
    'Opus-4.8 (high) · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
  expect(row[0]).toEqual({ text: 'Opus-4.8 (high)', color: '#5fafaf' })
  expect(row[2]).toEqual({ text: 'ctx 42%', color: 'rgb(40,203,0)' })
  expect(row[4]).toEqual({ text: 'Trivial subagent for statusline test' })
  expect(row[6]).toEqual({ text: '420.0k tok', color: '#d0d0d0' })
})

test('buildRow drops segments with no data', async () => {
  expect(
    plain(
      buildRow(
        { description: 'Review fix-5-2 F2 test', model: 'claude-sonnet-5', tokens: 40800, window: 1000000 },
        0,
      ),
    ),
  ).toBe('Sonnet-5 · ctx 4% · Review fix-5-2 F2 test · 40.8k tok')
  expect(
    plain(buildRow({ description: 'agent', model: 'claude-haiku-4-5-20251001' }, 0)),
  ).toBe('Haiku-4.5 · agent')
  expect(plain(buildRow({ description: '', tokens: 439 }, 0))).toBe('— · 439 tok')
  expect(
    plain(buildRow({ description: 'no window', model: 'claude-sonnet-5', tokens: 5000 }, 0)),
  ).toBe('Sonnet-5 · no window · 5.0k tok')
})

test('buildRow cuts the description first, then the whole row', async () => {
  const data = {
    description: 'Trivial subagent for statusline test',
    model: 'claude-opus-4-8',
    tokens: 420000,
    window: 1000000,
  }
  const cut = plain(buildRow(data, 40))
  expect(cut).toBe('Opus-4.8 · ctx 42% · Trivi… · 420.0k tok')
  expect(cut.length).toBe(40)

  const tight = plain(buildRow({ ...data, effort: 'high' }, 40))
  expect(tight).toBe('Opus-4.8 (high) · ctx 42% · Trivial suba')

  expect(plain(buildRow({ ...data, effort: 'high' }, 20))).toBe('Opus-4.8 (high) · ct')
  expect(plain(buildRow(data, 200))).toBe(
    'Opus-4.8 · ctx 42% · Trivial subagent for statusline test · 420.0k tok',
  )
})
