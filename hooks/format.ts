export type RowData = {
  description: string
  model?: string
  effort?: string
  tokens?: number
  window?: number
}

export type Segment = { text: string; color?: string }

// 256-color 73 and 252 of the main statusline, as their RGB equivalents.
export const MODEL_COLOR = '#5fafaf'
export const VALUE_COLOR = '#d0d0d0'
const SEPARATOR = ' · '

export function fmtModelName(id: string | undefined): string {
  if (!id) return '—'
  if (!id.startsWith('claude-')) return id
  const rest = id.slice('claude-'.length).replace(/-\d{8}$/, '')
  const dash = rest.indexOf('-')
  const family = dash === -1 ? rest : rest.slice(0, dash)
  const version = dash === -1 ? '' : rest.slice(dash + 1)
  const name = family.charAt(0).toUpperCase() + family.slice(1)
  return version ? `${name}-${version.replaceAll('-', '.')}` : name
}

export function fmtK(n: number): string {
  if (n < 1000) return String(n)
  return `${Math.floor(n / 1000)}.${Math.floor((n % 1000) / 100)}k`
}

const lerp = (a: number, b: number, t: number): number =>
  a + Math.trunc(((b - a) * t) / 100)

/** Green below `good`, red above `bad`, green -> amber -> red between (statusline-lib.sh `gradient_worse`). */
export function gradientColor(pct: number, good: number, bad: number): string {
  const raw = bad === good ? 100 : Math.trunc(((pct - good) * 100) / (bad - good))
  const t = Math.min(100, Math.max(0, raw))
  const first = t <= 50
  const tt = first ? t * 2 : (t - 50) * 2
  const r = first ? lerp(0, 255, tt) : 255
  const g = first ? lerp(215, 135, tt) : lerp(135, 0, tt)
  return `rgb(${r},${g},0)`
}

const plainLength = (segments: Segment[]): number =>
  segments.reduce((sum, s) => sum + s.text.length, 0)

function joinDot(parts: Segment[][]): Segment[] {
  const out: Segment[] = []
  for (const part of parts) {
    if (part.length === 0) continue
    if (out.length > 0) out.push({ text: SEPARATOR })
    out.push(...part)
  }
  return out
}

/**
 * One subagent row: `Model (effort) · ctx NN% · description · 12.3k tok`, each
 * missing segment dropped, shrunk to `columns` (0 = no limit) by cutting the
 * description in the middle of the row first (ports subagent-statusline.sh).
 */
export function buildRow(d: RowData, columns: number): Segment[] {
  const modelText = d.effort
    ? `${fmtModelName(d.model)} (${d.effort})`
    : fmtModelName(d.model)
  const lead: Segment[][] = [[{ text: modelText, color: MODEL_COLOR }]]

  const hasTokens = d.tokens !== undefined
  if (hasTokens && d.window !== undefined && d.window > 0) {
    const pct = Math.min(100, Math.max(0, Math.floor((d.tokens! * 100) / d.window)))
    lead.push([{ text: `ctx ${pct}%`, color: gradientColor(pct, 40, 65) }])
  }
  const tokens: Segment[] = hasTokens
    ? [{ text: `${fmtK(d.tokens!)} tok`, color: VALUE_COLOR }]
    : []
  const description: Segment[] = d.description ? [{ text: d.description }] : []

  const full = joinDot([...lead, description, tokens])
  if (columns <= 0 || plainLength(full) <= columns) return full

  const leadLength = plainLength(joinDot(lead))
  if (d.description) {
    const separators = tokens.length > 0 ? 2 : 1
    const avail =
      columns - leadLength - plainLength(tokens) - separators * SEPARATOR.length
    if (avail > 1) {
      const cut: Segment[] = [{ text: `${d.description.slice(0, avail - 1)}…` }]
      return joinDot([...lead, cut, tokens])
    }
  }
  const plain = full.map(s => s.text).join('')
  return [{ text: plain.slice(0, columns) }]
}
