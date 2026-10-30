// `kind`: whether this session CREATED the doc or published a new version of one that existed.
// `version`: the server's version number, when the publish reported it. Both absent on rows
// stored by an earlier version of the band.
export type BasaltLink = {
  url: string
  title: string
  trail: string[]
  by: string
  at: number
  kind?: 'new' | 'edited'
  version?: number
}

declare module 'claude-code' {
  interface PluginState {
    basalt: { links: BasaltLink[] }
  }
}
