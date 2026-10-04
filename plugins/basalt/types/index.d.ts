export type BasaltLink = { url: string; title: string; trail: string[]; by: string; at: number }

declare module 'claude-code' {
  interface PluginState {
    basalt: { links: BasaltLink[] }
  }
}
