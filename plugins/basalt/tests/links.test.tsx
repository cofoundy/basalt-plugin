import { describe, expect, mock, test } from 'claude-code/testing'

import { isGitPush, isPublish, normalizeSlug, pushDir, pushedDocs, pushedRanges, vaultName, withWorkspace } from '../hooks/register'
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
const repo = ({ action = true, changed = 'vault/research/Plan Q4.md\nREADME.md\n' } = {}): PushIo => ({
  git: async (dir, args) => {
    const line = args.join(' ')
    if (line === 'rev-parse --show-toplevel') return { exitCode: dir.startsWith('/r') ? 0 : 128, stdout: '/r\n' }
    if (line.startsWith('grep')) return { exitCode: action ? 0 : 1, stdout: '' }
    if (line.startsWith('diff --name-only --diff-filter=AMR 1a2b3c4..5d6e7f8')) return { exitCode: 0, stdout: changed }
    return { exitCode: 1, stdout: '' }
  },
  read: async path => (path === '/r/vault/vault.yaml' ? 'name: notes\npublish: auto\n' : undefined),
})

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
      { url: 'https://app.basalt.cofoundy.ai/notes/research/plan-q4', trail: ['notes', 'research'], title: 'plan-q4' },
    ])
  })

  test('a push that publishes nothing adds nothing', async () => {
    expect(await pushedDocs(repo({ action: false }), '/r', PUSH_OUT)).toEqual([])
    expect(await pushedDocs(repo({ changed: 'README.md\ndocs/x.md\n' }), '/r', PUSH_OUT)).toEqual([])
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
})
