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

// Canonical URLs are /{workspace}/{space}/{doc…}; the workspace is always the
// same for one person, so the trail starts at the space.
export const toLink = (url: string, by: string, at: number): BasaltLink => {
  const segments = new URL(url).pathname.split('/').filter(Boolean).map(decodeURIComponent)
  const trail = segments.length >= 3 ? segments.slice(1) : segments
  const title = trail[trail.length - 1] ?? url

  return { url, title, trail: trail.slice(0, -1), by, at }
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

  // Every row the conversation keeps (the person's, the model's, a tool's, a subagent's) is scanned.
  on('session.append', async ($, e, next) => {
    const stored = await next(e)
    const found = strings(e.message.content).flatMap(text => text.match(URL_RE) ?? [])
    if (found.length > 0) {
      const now = await $.clock.now()
      const by = e.agentId ? 'subagent' : 'session'
      await update($, links, list => {
        const known = new Set(list.map(link => link.url))
        const fresh = [...new Set(found.map(url => url.replace(/[.,;:!?]+$/, '')))]
          .filter(url => !known.has(url))
          .map(url => toLink(url, by, now))

        return [...list, ...fresh]
      })
    }

    return stored
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
