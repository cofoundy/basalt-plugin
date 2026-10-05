import { describe, expect, mock, test } from 'claude-code/testing'

import { isPublish } from '../hooks/register'

const Box = 'Box' as any
const URL = 'https://app.basalt.cofoundy.ai/cofoundy/factory/intent/panel'
const BAND = { component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 20 } } as const

function engine(on: any) {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('session.start', ($: any, e: any) => ({ cwd: e.cwd }))
  on('command.register', ($: any, e: any) => ({ value: { command: e.name } }))
  on('ui.render', () => <Box key="engine" />)
  on('tool.call', () => ({ result: { stdout: `ok ${URL}` }, text: `ok ${URL}` }))
}

const band = async ($: any) => {
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', ...BAND } as any)
  const shown = (await ui.find({ key: 'abrir' })) !== undefined
  await ui.unmount()
  return shown
}

describe('links band', () => {
  test('a link the session only read is not a doc it made', async ($, on) => {
    engine(on)
    await $.tool.call({ tool: 'Bash', command: `grep -r basalt ~/.claude/projects` } as any)
    expect(await band($)).toBe(false)
  })

  test('a publish puts its link in the band', async ($, on) => {
    engine(on)
    await $.tool.call({ tool: 'Bash', command: 'basalt publish docs/panel.md' } as any)
    expect(await band($)).toBe(true)
  })

  test('which calls publish', () => {
    expect(isPublish('Bash', 'cd vault && basalt publish a.md')).toBe(true)
    expect(isPublish('Bash', 'basalt move p/a p/b')).toBe(true)
    expect(isPublish('Bash', 'basalt list')).toBe(false)
    expect(isPublish('Bash', 'cat basalt-publish.log')).toBe(false)
    expect(isPublish('mcp__plugin_basalt_basalt__publish_doc', undefined)).toBe(true)
    expect(isPublish('mcp__basalt__update_doc', undefined)).toBe(true)
    expect(isPublish('mcp__basalt__get_doc', undefined)).toBe(false)
  })
})
