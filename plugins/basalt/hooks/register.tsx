import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { MARK_PNG, MARK_SVG } from './mark'

import type { BasaltLink } from '../types'

// Basalt brand tokens (products/basalt/tokens/colors.css). Dark-first:
// Molten is the one ember (the mark, nothing else), Signal Teal is links.
const MOLTEN = '#E2603B'
const ASH = '#F4F5F3'
const MUTED = '#7C828B' // stone-400: metadata on dark
const TEAL = '#3FB6A8'
const COLUMN = '#3A3F47' // column grey: the chip behind the wordmark
const STONE = '#B8BDC4' // stone-300: secondary text on dark

const PANE = 'basalt-links'
const URL_RE = /https:\/\/app\.basalt\.cofoundy\.ai\/[^\s)\]"'<>`\\]+/g
// What the band's fixed parts take: "⬣ basalt · 12 docs · " + the four buttons.
const BAND_CHROME = 24 + 44
const links = atom({ plugin: 'basalt', key: 'links' } as const, [])

// Every string in a row's content (model text, tool results, nested blocks).
const strings = (value: unknown, out: string[] = []): string[] => {
  if (typeof value === 'string') out.push(value)
  else if (Array.isArray(value)) value.forEach(v => strings(v, out))
  else if (value && typeof value === 'object') Object.values(value).forEach(v => strings(v, out))

  return out
}

// The command as the shell runs it: heredoc bodies and quoted strings are text the
// command carries (an issue body, a commit message), not commands it runs.
export const commandText = (command: string): string =>
  command
    .replace(/<<-?\s*(['"]?)([A-Za-z_][\w-]*)\1[^\n]*\n[\s\S]*?(?:\n[ \t]*\2[ \t]*(?=\n|$)|$)/g, ' ')
    .replace(/'[^']*'|"(?:[^"\\]|\\.)*"/g, "''")

// `basalt …` at the head of a shell segment, after any `VAR=value` and an npx/pnpm/bunx runner.
const AT_HEAD = String.raw`(?:^|[;&|(\n])\s*(?:\w+=\S*\s+)*(?:(?:npx|bunx|pnpm\s+(?:exec\s+|dlx\s+)?)\s*)?`
const BASALT_PUBLISH = new RegExp(AT_HEAD + String.raw`basalt(?:-cli)?\s+(?:publish|move)\b`)
const GIT_PUSH = new RegExp(AT_HEAD + String.raw`git(?:\s+-C\s+\S+)?\s+push\b`)

// The calls that publish: `basalt publish|move` from a shell, `publish_doc|update_doc` over MCP.
export const isPublish = (tool: string, command: unknown): boolean =>
  tool === 'Bash'
    ? typeof command === 'string' && BASALT_PUBLISH.test(commandText(command))
    : /basalt/i.test(tool) && /__(publish_doc|update_doc)$/.test(tool)

export const isGitPush = (command: unknown): boolean =>
  typeof command === 'string' && GIT_PUSH.test(commandText(command))

// The ranges a `git push` moved onto a default branch ("  1a2b3c4..5d6e7f8  main -> main").
// A new branch, a delete or a push to any other branch publishes nothing: the vault's
// Action publishes on a push to main.
export const pushedRanges = (output: string): { from: string; to: string }[] =>
  [...output.matchAll(/^\s*\+?\s*([0-9a-f]{7,40})\.\.\.?([0-9a-f]{7,40})\s+\S+\s+->\s+(\S+)/gm)]
    .filter(m => m[3] === 'main' || m[3] === 'master')
    .map(m => ({ from: m[1] ?? '', to: m[2] ?? '' }))

// The directory the push ran in: `git -C <dir> push`, else the last `cd <dir>` before it,
// else the session's own (relative paths against it).
export const pushDir = (command: string, cwd: string, home = ''): string => {
  const text = commandText(command)
  const push = text.match(GIT_PUSH)
  const head = push?.index === undefined ? text : text.slice(0, push.index + push[0].length)
  const dashC = head.match(/git\s+-C\s+(\S+)\s+push\s*$/)
  const cds = [...head.matchAll(/(?:^|[;&|(\n])\s*cd\s+([^\s;&|)]+)/g)]
  const dir = dashC?.[1] ?? cds[cds.length - 1]?.[1]
  if (!dir) return cwd
  const expanded = dir.replace(/^~(?=\/|$)/, home)

  return expanded.startsWith('/') ? expanded : `${cwd.replace(/\/$/, '')}/${expanded}`
}

// Byte-identical to the CLI's `normalizeSlug` (cli/src/local-docs.ts): the slug IS the
// path relative to the vault root, each segment normalized, the .md/.mdx suffix gone.
const segment = (seg: string) =>
  seg.normalize('NFD').replace(/\p{M}+/gu, '').toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-').replace(/-+/g, '-').replace(/^-+|-+$/g, '')

export const normalizeSlug = (relPath: string): string =>
  relPath.replace(/\.(md|mdx)$/i, '').split(/[\\/]/).map(segment).filter(Boolean).join('/')

export const vaultName = (yaml: string): string | undefined =>
  yaml.match(/^name:[ \t]*(.+?)[ \t]*$/m)?.[1]?.replace(/^["']|["']$/g, '').trim() || undefined

const BASE = 'https://app.basalt.cofoundy.ai'

// What reading a push needs from outside: git in a directory, a file's text.
export type PushIo = {
  git: (dir: string, args: string[]) => Promise<{ exitCode: number; stdout: string }>
  read: (path: string) => Promise<string | undefined>
}

// The docs a push to main hands to the vault's publish Action: each .md/.mdx it added or
// changed under a vault.yaml, in a repo whose workflows run `basalt publish`. The URL is
// the flat /{space}/{slug} one: the app sends whoever may read it to the canonical URL,
// and the workspace is not knowable from the repo.
export async function pushedDocs(io: PushIo, dir: string, output: string): Promise<{ url: string; trail: string[]; title: string }[]> {
  const ranges = pushedRanges(output)
  if (ranges.length === 0) return []
  const top = await io.git(dir, ['rev-parse', '--show-toplevel'])
  if (top.exitCode !== 0) return []
  const root = top.stdout.trim()
  const docs: { url: string; trail: string[]; title: string }[] = []
  for (const { from, to } of ranges) {
    const action = await io.git(root, ['grep', '-l', '-e', 'basalt publish', to, '--', '.github/workflows'])
    if (action.exitCode !== 0) continue
    const changed = await io.git(root, ['diff', '--name-only', '--diff-filter=AMR', `${from}..${to}`, '--', '*.md', '*.mdx'])
    for (const file of changed.stdout.split('\n').filter(Boolean)) {
      const parts = file.split('/')
      for (let depth = parts.length - 1; depth >= 0; depth--) {
        const yaml = await io.read([root, ...parts.slice(0, depth), 'vault.yaml'].join('/'))
        if (yaml === undefined) continue
        const space = vaultName(yaml) ?? segment(parts[depth - 1] ?? root.split('/').pop() ?? '')
        const slug = normalizeSlug(parts.slice(depth).join('/'))
        if (space && slug) {
          const path = slug.split('/')
          docs.push({ url: `${BASE}/${space}/${slug}`, trail: [space, ...path.slice(0, -1)], title: path[path.length - 1] ?? slug })
        }
        break
      }
    }
  }

  return docs
}

const pushIo = ($: EngineInterface): PushIo => ({
  git: (dir, args) => $.process.run(['git', '-C', dir, ...args]).catch(() => ({ exitCode: 1, stdout: '' })),
  read: path => $.fs.read(path).then(text => (typeof text === 'string' ? text : undefined), () => undefined),
})

// Canonical URLs are /{workspace}/{space}/{doc…}; the workspace is always the
// same for one person, so the trail starts at the space.
export const toLink = (url: string, by: string, at: number): BasaltLink => {
  const segments = new URL(url).pathname.split('/').filter(Boolean).map(decodeURIComponent)
  const trail = segments.length >= 3 ? segments.slice(1) : segments
  const title = trail[trail.length - 1] ?? url

  return { url, title, trail: trail.slice(0, -1), by, at }
}

// A flat /{space}/{slug} URL turns canonical when the band already holds a doc of that
// space under its workspace (the redirect costs a hop, and a copied link should not).
export const withWorkspace = (link: BasaltLink, list: BasaltLink[]): BasaltLink => {
  const flat = new URL(link.url).pathname.split('/').filter(Boolean)
  if (flat[0] !== link.trail[0] || flat.length !== link.trail.length + 1) return link
  for (const other of list) {
    const parts = new URL(other.url).pathname.split('/').filter(Boolean)
    if (parts.length >= 3 && parts[1] === flat[0]) return { ...link, url: `${BASE}/${parts[0]}/${flat.join('/')}` }
  }

  return link
}

// Rows stored by an earlier version carry no trail.
const fresh = (link: BasaltLink) => (Array.isArray(link.trail) ? link : toLink(link.url, link.by, link.at))

const cut = (text: string, room: number) => {
  if (text.length <= room) return text
  const keep = Math.max(1, room - 1)
  const head = Math.ceil(keep / 2)

  return text.slice(0, head) + '…' + text.slice(text.length - (keep - head))
}

// Fits "space › folder › title" into `room` cells: the title always survives
// (cut in the middle, so its start and its version suffix stay), then the
// nearest folders, and whatever does not fit collapses to "…".
// Fits "space › folder › title" into `room` cells. Priority: the title (cut in
// the middle, so its start and its version suffix stay), then the space, then
// the nearest folders; the folders that do not fit collapse to "…".
export const crumb = (link: BasaltLink, room: number) => {
  const trail = link.trail
  const space = trail[0]
  // The space keeps its place beside the title unless the room is too small for both.
  const reserve = space === undefined ? 0 : trail.length > 1 ? space.length + 7 : space.length + 3
  const title = cut(link.title, Math.max(16, room - reserve))
  let left = room - title.length
  const whole = trail.reduce((sum, part) => sum + part.length + 3, 0)
  if (whole <= left) return { path: trail.map(part => part + ' › ').join(''), title }
  left -= 4 // "… › "
  const folders = trail.slice(1)
  const head = space !== undefined && space.length + 3 <= left ? [space] : []
  left -= head.reduce((sum, part) => sum + part.length + 3, 0)
  const near: string[] = []
  for (const part of [...folders].reverse()) {
    if (part.length + 3 > left) break
    near.unshift(part)
    left -= part.length + 3
  }

  return { path: [...head, '…', ...near].map(part => part + ' › ').join(''), title }
}

async function openUrl($: EngineInterface, url: string) {
  const mac = await $.process.run(['open', url]).catch(() => ({ exitCode: 1 }))
  if (mac.exitCode !== 0) await $.process.run(['xdg-open', url]).catch(() => undefined)
}

// English by default; Spanish when the locale says so (POSIX precedence:
// LC_ALL, then LC_MESSAGES, then LANG).
const STRINGS = {
  en: {
    open: 'Open', copy: 'Copy', all: 'All', copied: 'Link copied',
    pane: 'Basalt · session docs', empty: 'No Basalt docs in this session yet.',
    command: 'List the Basalt docs of this session', opened: 'Basalt docs of this session opened in the pane.',
    session: 'session', subagent: 'subagent',
  },
  es: {
    open: 'Abrir', copy: 'Copiar', all: 'Todos', copied: 'Link copiado',
    pane: 'Basalt · docs de la sesión', empty: 'Ningún doc de Basalt en esta sesión todavía.',
    command: 'Lista los docs de Basalt de esta sesión', opened: 'Docs de Basalt de esta sesión abiertos en el panel.',
    session: 'sesión', subagent: 'subagente',
  },
} as const
type Strings = (typeof STRINGS)[keyof typeof STRINGS]

export const pickLanguage = (lcAll?: string, lcMessages?: string, lang?: string): keyof typeof STRINGS => {
  const locale = lcAll || lcMessages || lang || ''

  return locale.toLowerCase().startsWith('es') ? 'es' : 'en'
}

async function labels($: EngineInterface): Promise<Strings> {
  const language = pickLanguage(await $.env.get('LC_ALL'), await $.env.get('LC_MESSAGES'), await $.env.get('LANG'))

  return STRINGS[language]
}

// The pane stays open across reloads and sessions until the person closes it.
async function openPane($: EngineInterface, focus?: true) {
  await $.store.set('isPinned', true)
  await $.ui.open({ id: PANE, title: (await labels($)).pane, ...(focus ? { focus } : {}) })
}

async function copyUrl($: EngineInterface, url: string, surface: Parameters<EngineInterface['ui']['copy']>[0]['surface']) {
  await $.ui.copy({ text: url, surface })
  $.ui.toast((await labels($)).copied)
}

// Whether this terminal shows kitty graphics: kitty or Ghostty, run directly.
// A multiplexer (tmux, screen, herdr) passes none through, and there `Image`
// would draw its alt dim, so the glyph in Molten is the better fallback.
async function hasGraphics($: EngineInterface) {
  const multiplexed = [
    await $.env.get('TMUX'),
    await $.env.get('STY'),
    await $.env.get('HERDR_ENV'),
    await $.env.get('ZELLIJ'),
  ].some(Boolean)
  if (multiplexed) return false
  const program = await $.env.get('TERM_PROGRAM')

  return program === 'ghostty' || Boolean(await $.env.get('KITTY_WINDOW_ID'))
}

// The mark, best the surface can draw: the SVG on desktop, the PNG on a
// terminal with kitty graphics, and the hexagon glyph in Molten elsewhere.
async function mark($: EngineInterface, e: Parameters<EngineInterface['ui']['resolve']>[0]) {
  if (e.surface === 'terminal' && (await hasGraphics($))) {
    const { Image } = $.ui.resolve(e)

    return <Image source={{ png: MARK_PNG }} columns={2} rows={1} alt="⬣" />
  }
  if (e.surface === 'desktop') {
    const { Svg } = $.ui.resolve(e)

    return <Svg source={MARK_SVG} alt="Basalt" width={16} height={16} />
  }
  const { Text } = $.ui.resolve(e)

  return <Text color={MOLTEN}>⬣</Text>
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'basalt-links', description: (await labels($)).command })
    if ((await $.store.get('isPinned')) === true) void openPane($)

    return next(e)
  })

  on('command.run', { command: 'basalt-links' }, async $ => {
    await openPane($)

    return { text: (await labels($)).opened }
  })

  // Only what this session published: the result of a publish, never a link it merely read
  // (a subagent grepping old transcripts filled the band with docs nobody made), and the
  // docs a push to main hands to the vault's publish Action (no URL ever reaches the session).
  on('tool.call', async ($, e, next) => {
    const out = await next(e)
    if (out.deny !== undefined || out.isError) return out
    const command = (e as { command?: unknown }).command
    const publish = isPublish(e.tool, command)
    const push = e.tool === 'Bash' && !publish && isGitPush(command)
    if (!publish && !push) return out
    const text = strings([out.text, out.result]).join('\n')
    const found: BasaltLink[] = []
    const by = e.agentId ? 'subagent' : 'session'
    const now = await $.clock.now()
    if (publish) {
      for (const url of new Set((text.match(URL_RE) ?? []).map(url => url.replace(/[.,;:!?]+$/, ''))))
        found.push(toLink(url, by, now))
    } else {
      const dir = pushDir(command as string, await $.session.cwd(), (await $.env.get('HOME')) ?? '')
      for (const doc of await pushedDocs(pushIo($), dir, text).catch(() => [])) found.push({ ...doc, by, at: now })
    }
    if (found.length > 0) {
      // One doc, one row: a flat /{space}/{slug} and its canonical /{ws}/{space}/{slug} are the same doc.
      const key = (link: BasaltLink) => [...link.trail, link.title].join('/')
      await update($, links, list => {
        const known = new Set(list.map(fresh).map(key))
        const added = found.filter(link => !known.has(key(link)) && known.add(key(link))).map(link => withWorkspace(link, list))

        return [...list, ...added]
      })
    }

    return out
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = (await read($, links)).map(fresh)
    const last = list[list.length - 1]
    if (e.props.hasSurvey || !last) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const t = await labels($)
    const { path, title } = crumb(last, e.props.bodyColumns - BAND_CHROME)
    const below = await next(e)

    return (
      <Box flexDirection="column">
        <Box>
          {await mark($, e)}
          <Text> </Text>
          <Text color={ASH} backgroundColor={COLUMN} bold> basalt </Text>
          <Text> </Text>
          <Text color={TEAL} bold>{list.length}</Text>
          <Text color={MUTED}> doc{list.length === 1 ? '' : 's'}  </Text>
          <Text key="path" color={STONE}>{path}</Text>
          <Text key="title" color={ASH} bold>{title} </Text>
          <Button key="abrir" hotkey="o" variant="primary" label={t.open} onPress={() => openUrl($, last.url)} />
          <Text> </Text>
          <Button key="copiar" hotkey="c" label={t.copy} onPress={() => copyUrl($, last.url, e.surface)} />
          <Text> </Text>
          <Button key="todos" hotkey="l" label={t.all} onPress={() => openPane($, true)} />
        </Box>
        {below}
      </Box>
    )
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    if (e.origin.kind === 'person') await $.store.set('isPinned', false)

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const t = await labels($)
    const list = (await read($, links)).map(fresh)
    const room = Math.max(16, e.props.bodyColumns - 2)

    return (
      <Box flexDirection="column">
        {list.length === 0 && <Text color={MUTED}>{t.empty}</Text>}
        {[...list].reverse().map(link => {
          const { path } = crumb({ ...link, title: '' }, room)

          return (
            <Box flexDirection="column" marginBottom={1}>
              <Text color={ASH} bold wrap="truncate-middle">{link.title}</Text>
              {link.trail.length > 0 && <Text color={MUTED} wrap="truncate-start">{path.replace(/ › $/, '')}</Text>}
              <Text color={TEAL} wrap="truncate-middle">{link.url}</Text>
              <Box>
                <Button key={`o-${link.url}`} variant="primary" label={t.open} onPress={() => openUrl($, link.url)} />
                <Text> </Text>
                <Button key={`c-${link.url}`} label={t.copy} onPress={() => copyUrl($, link.url, e.surface)} />
                <Text color={MUTED}> · {link.by === 'subagent' || link.by === 'subagente' ? t.subagent : t.session}</Text>
              </Box>
            </Box>
          )
        })}
      </Box>
    )
  })
}
