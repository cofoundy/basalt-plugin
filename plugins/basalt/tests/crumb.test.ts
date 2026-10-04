import { expect, test } from 'claude-code/testing'

import { crumb, toLink } from '../hooks/register'

const BAND_CHROME = 66
const CASES = [
  'https://app.basalt.cofoundy.ai/cofoundy/basalt-pm/dev/prd/collaboration/v3.1-collaboration-wedge-suggestion-mode-and-review-loop-final',
  'https://app.basalt.cofoundy.ai/cofoundy/basalt/visual-ssot-v1',
  'https://app.basalt.cofoundy.ai/rockheads/rate-card',
]

for (const columns of [100, 120, 160, 200]) {
  test(`crumb fits the band at ${columns} columns`, () => {
    for (const url of CASES) {
      const room = columns - BAND_CHROME
      const { path, title } = crumb(toLink(url, 'sesión', 0), room)
      console.log(`${String(columns).padStart(3)} │ ${path}${title}`)
      expect((path + title).length).toBeLessThanOrEqual(Math.max(room, 8))
      expect(title.length).toBeGreaterThan(0)
    }
  })
}
