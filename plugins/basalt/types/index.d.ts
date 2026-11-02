// `kind`: whether this session CREATED the doc or published a new version of one that existed.
// `version`: the server's version number, when the publish reported it. Both absent on rows
// stored by an earlier version of the band.
// `seenAt`: when the person last opened or copied it. A row is unseen while absent, or once a
// later publish moves `at` past it.
export type BasaltLink = {
  url: string
  title: string
  trail: string[]
  by: string
  at: number
  kind?: 'new' | 'edited'
  version?: number
  seenAt?: number
}

declare module 'claude-code' {
  interface PluginState {
    basalt: { links: BasaltLink[] }
  }
}
