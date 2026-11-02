import { describe, expect, mock, test } from 'claude-code/testing'

import { isGitPush, isPublish, isUnseen, markSeen, merge, normalizeSlug, ordered, publishFacts, pushDir, pushedDocs, pushedRanges, tally, tag, vaultName, withWorkspace } from '../hooks/register'
import type { PushIo } from '../hooks/register'

const Box = 'Box' as any
const URL = 'https://app.basalt.cofoundy.ai/cofoundy/factory/intent/panel'
const BAND = { component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 20 } } as const
const PUSH_OUT = 'To github.com:acme/notes.git\n   1a2b3c4..5d6e7f8  main -> main\n'

function engine(on: any, output = `ok ${URL}`) {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('session.start', ($: any, e: any) => ({ cwd: e.cwd }))
  on('command.register', ($: any, e: any) => ({ value: { command: e.name } }))
  on('ui.render', () => <Box key="engine" />)
  on('tool.call', () => ({ result: { stdout: output }, text: output }))
}

const band = async ($: any) => {
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', ...BAND } as any)
  const shown = (await ui.find({ key: 'abrir' })) !== undefined
  await ui.unmount()
  return shown
}

// A repo at /r with a vault at /r/vault (name: notes) and, unless told, a workflow that runs `basalt publish`.
const repo = ({ action = true, changed = 'A\tvault/research/Plan Q4.md\nM\tREADME.md\n' } = {}): PushIo => ({
  git: async (dir, args) => {
    const line = args.join(' ')
    if (line === 'rev-parse --show-toplevel') return { exitCode: dir.startsWith('/r') ? 0 : 128, stdout: '/r\n' }
    if (line.startsWith('grep')) return { exitCode: action ? 0 : 1, stdout: '' }
    if (line.startsWith('diff --name-status --diff-filter=AMR 1a2b3c4..5d6e7f8')) return { exitCode: 0, stdout: changed }
    return { exitCode: 1, stdout: '' }
  },
  read: async path => (path === '/r/vault/vault.yaml' ? 'name: notes\npublish: auto\n' : undefined),
})

// Every string the band or the pane drew, in order.
const textOf = (node: any): string =>
  typeof node === 'string' ? node : Array.isArray(node) ? node.map(textOf).join('') : node ? textOf(node.children ?? []) : ''

// An engine whose publishes answer, in turn, with each of `outputs`.
function sequence(on: any, outputs: string[]) {
  mock.clock(on)
  mock.store(on)
  mock.env(on, {})
  on('session.start', ($: any, e: any) => ({ cwd: e.cwd }))
  on('command.register', ($: any, e: any) => ({ value: { command: e.name } }))
  on('ui.render', () => <Box key="engine" />)
  let i = 0
  on('tool.call', () => {
    const out = outputs[Math.min(i++, outputs.length - 1)] ?? ''
    return { result: { stdout: out }, text: out }
  })
}

const drawn = async ($: any, component: 'AbovePrompt' | 'Pane') => {
  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  const props = component === 'Pane' ? { requestId: 'basalt-links', props: { bodyColumns: 80 } } : { props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 160 } }
  const ui: any = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', component, ...props } as any)
  const text = textOf(await ui.drawn())
  await ui.unmount()
  return text
}

const A = 'https://app.basalt.cofoundy.ai/acme/notes/ship-log/plan'
const B = 'https://app.basalt.cofoundy.ai/acme/notes/personas'

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

  test('a heredoc that mentions basalt publish is not a publish', async ($, on) => {
    engine(on)
    await $.tool.call({ tool: 'Bash', command: "gh issue create --body-file - <<'EOF'\nrun basalt publish docs/panel.md\nEOF" } as any)
    expect(await band($)).toBe(false)
  })

  test('push output the session merely read is not a push', async ($, on) => {
    engine(on, PUSH_OUT)
    await $.tool.call({ tool: 'Bash', command: 'cat push.log' } as any)
    expect(await band($)).toBe(false)
  })

  test('a push to main of a vault doc is the doc the Action publishes', async () => {
    expect(await pushedDocs(repo(), '/r', PUSH_OUT)).toEqual([
      { url: 'https://app.basalt.cofoundy.ai/notes/research/plan-q4', trail: ['notes', 'research'], title: 'plan-q4', kind: 'new' },
    ])
    expect((await pushedDocs(repo({ changed: 'M\tvault/research/Plan Q4.md\n' }), '/r', PUSH_OUT))[0]?.kind).toBe('edited')
  })

  test('a push that publishes nothing adds nothing', async () => {
    expect(await pushedDocs(repo({ action: false }), '/r', PUSH_OUT)).toEqual([])
    expect(await pushedDocs(repo({ changed: 'M\tREADME.md\nA\tdocs/x.md\n' }), '/r', PUSH_OUT)).toEqual([])
    expect(await pushedDocs(repo(), '/r', '   1a2b3c4..5d6e7f8  feat/x -> feat/x\n')).toEqual([])
    expect(await pushedDocs(repo(), '/elsewhere', PUSH_OUT)).toEqual([])
  })

  test('a flat link takes the workspace the band already knows for its space', () => {
    const flat = { url: 'https://app.basalt.cofoundy.ai/notes/research/plan-q4', trail: ['notes', 'research'], title: 'plan-q4', by: 'session', at: 1 }
    const seen = { url: 'https://app.basalt.cofoundy.ai/acme/notes/old', trail: ['notes'], title: 'old', by: 'session', at: 0 }
    expect(withWorkspace(flat, [seen]).url).toBe('https://app.basalt.cofoundy.ai/acme/notes/research/plan-q4')
    expect(withWorkspace(flat, []).url).toBe(flat.url)
  })

  test('the slug is the CLI one', () => {
    expect(normalizeSlug('research/Plan Q4.md')).toBe('research/plan-q4')
    expect(normalizeSlug('Árbol/Ñandú_v2.mdx')).toBe('arbol/nandu_v2')
    expect(vaultName('# c\nname: "basalt-pm"\n')).toBe('basalt-pm')
    expect(vaultName('publish: auto\n')).toBeUndefined()
  })

  test('which pushes reach main', () => {
    expect(pushedRanges(PUSH_OUT)).toEqual([{ from: '1a2b3c4', to: '5d6e7f8' }])
    expect(pushedRanges(' + 1a2b3c4...5d6e7f8 main -> main (forced update)')).toEqual([{ from: '1a2b3c4', to: '5d6e7f8' }])
    expect(pushedRanges('   1a2b3c4..5d6e7f8  feat/x -> feat/x')).toEqual([])
    expect(pushedRanges(' * [new branch]      main -> main')).toEqual([])
  })

  test('where the push ran', () => {
    expect(pushDir('cd /r && git push', '/w')).toBe('/r')
    expect(pushDir('cd a; cd b && git push', '/w')).toBe('/w/b')
    expect(pushDir('git -C ~/r push origin main', '/w', '/home/x')).toBe('/home/x/r')
    expect(pushDir('git push', '/w')).toBe('/w')
    expect(isGitPush('cd r && git push -q')).toBe(true)
    expect(isGitPush('git commit -m "then git push"')).toBe(false)
  })

  test('which calls publish', () => {
    expect(isPublish('Bash', 'cd vault && basalt publish a.md')).toBe(true)
    expect(isPublish('Bash', 'BASALT_BASE_URL=https://x basalt publish a.md')).toBe(true)
    expect(isPublish('Bash', 'npx basalt-cli publish a.md')).toBe(true)
    expect(isPublish('Bash', "cat > x <<'EOF'\nbasalt publish\nEOF\nbasalt publish x")).toBe(true)
    expect(isPublish('Bash', 'basalt move p/a p/b')).toBe(true)
    expect(isPublish('Bash', 'gh issue create -b "then; basalt publish a.md"')).toBe(false)
    expect(isPublish('Bash', 'basalt list')).toBe(false)
    expect(isPublish('Bash', 'cat basalt-publish.log')).toBe(false)
    expect(isPublish('mcp__plugin_basalt_basalt__publish_doc', undefined)).toBe(true)
    expect(isPublish('mcp__basalt__update_doc', undefined)).toBe(true)
    expect(isPublish('mcp__basalt__get_doc', undefined)).toBe(false)
  })
  test('the CLI row says whether the doc was created or got a new version, and which', () => {
    const facts = publishFacts(`new            notes/ship-log/plan  ${A}  v1  [assets: 3↑ 0✓]\nmodified       notes/personas  ${B}  v7`)
    expect(facts.get(A)).toEqual({ kind: 'new', version: 1 })
    expect(facts.get(B)).toEqual({ kind: 'edited', version: 7 })
    // A CLI that prints no version still says new/modified; a strict-failed row keeps its verb.
    expect(publishFacts(`✗ modified     notes/personas  ${B}`).get(B)).toEqual({ kind: 'edited', version: undefined })
  })

  test('JSON and the MCP Trust Object say it through version', () => {
    expect(publishFacts(JSON.stringify([{ status: 'new', canonicalUrl: A, version: 1 }])).get(A)).toEqual({ kind: 'new', version: 1 })
    expect(publishFacts(JSON.stringify({ url: B, version: 4, sha: 'x' })).get(B)).toEqual({ kind: 'edited', version: 4 })
    expect(publishFacts(JSON.stringify({ url: A, version: 1 })).get(A)?.kind).toBe('new')
  })

  test('created docs come first, newest first; then new versions; old rows last', () => {
    const row = (title: string, at: number, kind?: 'new' | 'edited') => ({ url: `${A}-${title}`, title, trail: [], by: 'session', at, kind })
    expect(ordered([row('e1', 5, 'edited'), row('n1', 1, 'new'), row('old', 9), row('n2', 3, 'new')]).map(l => l.title)).toEqual(['n2', 'n1', 'e1', 'old'])
  })

  test('publishing the same doc again moves its row and keeps it «new» if this session created it', () => {
    const first = { url: A, title: 'plan', trail: ['notes', 'ship-log'], by: 'session', at: 1, kind: 'new' as const, version: 1 }
    expect(merge(first, { ...first, at: 9, kind: 'edited', version: 2 })).toEqual({ ...first, at: 9, kind: 'new', version: 2 })
    expect(merge({ ...first, kind: 'edited', version: 3 }, { ...first, at: 9, kind: 'edited', version: 4 }).version).toBe(4)
  })

  test('the tag says what the session did; the count says what waits to be opened', () => {
    const es = { new: 'creado', edited: 'editado', unseen: 'sin abrir' }
    const l = (kind?: 'new' | 'edited', version?: number, seenAt?: number) => ({ url: A, title: 't', trail: [], by: 'session', at: 1, kind, version, seenAt })
    expect(tag(l('new', 1), es)).toBe('creado v1')
    expect(tag(l('edited', 3), es)).toBe('editado v3')
    expect(tag(l(), es)).toBe('')
    expect(tally([l('new'), l('edited', 2, 5), l('edited')], es)).toBe('● 2 sin abrir')
    expect(tally([l('new', 1, 5), l(undefined, undefined, 5)], es)).toBe('2 docs')
  })

  test('opening a doc sees it; a later publish of it makes it unseen again', () => {
    const row = { url: A, title: 'plan', trail: [], by: 'session', at: 1, kind: 'new' as const }
    const [opened] = markSeen([row], A, 4)
    expect(isUnseen(row)).toBe(true)
    expect(isUnseen(opened!)).toBe(false)
    expect(isUnseen(merge(opened!, { ...row, at: 9, kind: 'edited', version: 2 }))).toBe(true)
  })

  test('what waits to be opened comes before what was already seen, whatever its kind', () => {
    const row = (title: string, at: number, kind: 'new' | 'edited', seenAt?: number) => ({ url: `${A}-${title}`, title, trail: [], by: 'session', at, kind, seenAt })
    expect(ordered([row('created-seen', 5, 'new', 6), row('edited-unseen', 2, 'edited'), row('created-unseen', 1, 'new')]).map(l => l.title))
      .toEqual(['created-unseen', 'edited-unseen', 'created-seen'])
  })

  test('the band shows the doc the session created, even when an edit came after', async ($, on) => {
    sequence(on, [`new  notes/ship-log/plan  ${A}  v1`, `modified  notes/personas  ${B}  v7`])
    await $.tool.call({ tool: 'Bash', command: 'basalt publish ship-log/plan.md' } as any)
    await $.tool.call({ tool: 'Bash', command: 'basalt publish personas.md' } as any)
    const band = await drawn($, 'AbovePrompt')
    expect(band).toContain('● 2 unseen')
    expect(band).toContain('plan')
    expect(band).toContain('created v1')
    expect(band).not.toContain('personas')
  })

  test('Open sees the doc: its «unseen» goes and the next unseen one takes the band', async ($, on) => {
    sequence(on, [`new  notes/ship-log/plan  ${A}  v1`, `modified  notes/personas  ${B}  v7`])
    on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '' } }))
    on('ui.toast', () => ({ value: undefined }))
    await $.tool.call({ tool: 'Bash', command: 'basalt publish ship-log/plan.md' } as any)
    await $.tool.call({ tool: 'Bash', command: 'basalt publish personas.md' } as any)
    await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
    const props = { props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 160 } }
    const ui: any = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', component: 'AbovePrompt', ...props } as any)
    await ui.press({ key: 'abrir' })
    expect(textOf(await ui.drawn())).toContain('● 1 unseen')
    expect(textOf(await ui.drawn())).toContain('personas')
    await ui.press({ key: 'abrir' })
    const after = textOf(await ui.drawn())
    expect(after).toContain('2 docs')
    expect(after).not.toContain('unseen')
    await ui.unmount()
  })

  test('Open with no browser on the box copies the link instead of doing nothing', async ($, on) => {
    engine(on)
    const copied: string[] = []
    on('process.run', () => ({ value: { exitCode: 3, stdout: '', stderr: '' } }))
    on('ui.toast', () => ({ value: undefined }))
    on('ui.copy', ($: any, e: any) => { copied.push(e.text); return { value: { isCopied: true } } })
    await $.tool.call({ tool: 'Bash', command: 'basalt publish docs/panel.md' } as any)
    await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
    const ui: any = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', ...BAND, props: { ...BAND.props, bodyColumns: 160 } } as any)
    await ui.press({ key: 'abrir' })
    expect(copied).toEqual([URL])
    await ui.unmount()
  })

  test('the pane lists what waits to be opened first, under its own heading, each with its tag', async ($, on) => {
    sequence(on, [`modified  notes/personas  ${B}  v7`, `new  notes/ship-log/plan  ${A}  v1`])
    on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '' } }))
    on('ui.toast', () => ({ value: undefined }))
    await $.tool.call({ tool: 'Bash', command: 'basalt publish personas.md' } as any)
    await $.tool.call({ tool: 'Bash', command: 'basalt publish ship-log/plan.md' } as any)
    await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
    const ui: any = await $.ui.mount({ plugin: 'basalt', surface: 'terminal', component: 'Pane', requestId: 'basalt-links', props: { bodyColumns: 80 } } as any)
    await ui.press({ key: `o-${A}` })
    const pane = textOf(await ui.drawn())
    await ui.unmount()
    expect(pane.indexOf('Unseen · 1')).toBeLessThan(pane.indexOf('personas'))
    expect(pane.indexOf('personas')).toBeLessThan(pane.indexOf('Seen · 1'))
    expect(pane.indexOf('Seen · 1')).toBeLessThan(pane.indexOf('plan'))
    expect(pane).toContain('edited v7')
    expect(pane).toContain('created v1')
  })

})
