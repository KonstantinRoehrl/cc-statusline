/** What the band remembers about one subagent, from its `turn.step` events. */
export type AgentRecord = {
  model?: string
  effort?: string
  tokens?: number
}

declare module 'claude-code' {
  interface PluginState {
    'cc-statusline': {
      records: Record<string, AgentRecord>
      mainModel: string
    }
  }
}
