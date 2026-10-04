<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/logo-dark.png">
    <img alt="Basalt" src="./assets/logo.png" width="420">
  </picture>
</p>

<h1 align="center">Basalt — publish from your AI agent</h1>

<p align="center">
<a href="./LICENSE"><img src="https://badgen.net/badge/license/MIT/blue" alt="license MIT"></a>
<a href="https://skills.sh"><img src="https://badgen.net/badge/agents/70+/black" alt="agents 70+"></a>
<a href="https://github.com/cofoundy/basalt-plugin"><img src="https://badgen.net/badge/npx%20skills%20add/cofoundy%2Fbasalt-plugin/green" alt="npx skills add cofoundy/basalt-plugin"></a>
</p>

<!-- skills.sh badge stays out until the repo is indexed (post-install telemetry) — a 404 badge reads as broken:
     [![skills.sh](https://skills.sh/b/cofoundy/basalt-plugin)](https://skills.sh/cofoundy/basalt-plugin) -->

**Your AI wrote something good. Now it lives at a URL your colleague can actually
open.** Tell your agent to *publish* or *share* a doc and it converges on
[Basalt](https://app.basalt.cofoundy.ai) — the trust layer for AI-generated work.
Markdown in → a branded, permissioned, versioned page by URL. No copy-pasting into a
gist, no "let me send you the file," no work that evaporates in a chat log.

**Before:** your agent's best writing dies in the terminal, or lands in a throwaway
gist with no permissions, no history, no review.
**After:** one sentence — "publish this" — and you get back a live link to send. The
page is governed, versioned, and your colleague can comment on it. *Companies
remember.*

<p align="center">
  <img src="./assets/readme/workflow.svg" width="100%" alt="Four steps: you ask your agent to publish; it reads your workspace conventions; publish_doc compiles, versions and applies permissions; you get a live URL to send.">
</p>

## What you get

- **A shareable link, not a file.** `publish_doc` returns a live URL — that's the
  deliverable. Send it; your colleague reads and reviews in place.
- **It writes as *you*.** The agent inherits *your* Basalt permissions over MCP —
  it sees and changes exactly what you can, never more.
- **Zero typing.** The bundled skill auto-fires on "publish this / share this doc /
  documéntalo" — no command to memorize. (There's a `/basalt` command too, if you
  want it.)
- **Every link, one key away.** In Claude Code, a band above the prompt collects
  every Basalt doc the session publishes — `o` opens the latest, `c` copies it. No
  scrolling up the chat to find the URL. ([details](#the-links-band-every-doc-of-the-session-one-key-away))
- **Governed by default.** Versioned, access-controlled, reviewable — because
  AI-authored work should become durable org truth, not chat scrollback.

## Install

**As a Claude Code plugin** (MCP server + skill + `/basalt` command, one install):

```
/plugin marketplace add cofoundy/basalt-plugin
/plugin install basalt@basalt
```

**Or just the skill**, in any of 70+ agents (Claude Code, Codex, Cursor, OpenCode…)
via the [open agent-skills ecosystem](https://skills.sh):

```
npx skills add cofoundy/basalt-plugin
```

The first time your agent calls a Basalt tool, a browser login (OAuth) opens —
approve once and you're connected to your workspace. That's the only setup.

## Use it

Just ask, in plain language:

> "Write up how our auth service works and **publish it** so the team can review."

The agent looks at your workspace conventions, writes the doc, calls `publish_doc`,
and hands you back a **live URL**. Send that link — done.

## What it can do

Once connected, your agent can (within *your* permissions):

- Read any doc you have access to — `list_docs`, `search_docs`, `read_doc`.
- Publish & update docs by URL, versioned — `publish_doc`, `update_doc`.
- Share a doc with a colleague or client — `set_access`.
- Read review comments, propose a diff, and republish — the full review loop.

## What's inside

An MCP-bearing Claude Code plugin (the same shape as the official Figma plugin):

```
plugins/basalt/
├── .claude-plugin/plugin.json   # plugin manifest
├── .mcp.json                    # the Basalt MCP server (HTTP + per-user OAuth)
├── commands/basalt.md           # the /basalt command
├── skills/basalt/SKILL.md       # the auto-invoking skill (its description is the magic)
├── hooks/                       # three session-boundary hooks (silence by default)
│   └── register.tsx             #   + the links band (a Claude Code function-hooks module)
├── types/index.d.ts             # the band's state contract
└── tests/                       # `claude plugin test plugins/basalt`
```

The plugin holds **no secrets** — it points at the public MCP endpoint and auth is
per-user OAuth. It's a thin, honest on-ramp; the product lives in Basalt.

## Session hooks (quiet unless there's something to do)

Three hooks fire only at session boundaries, and stay **silent by default** — a hook
that talks when it doesn't need to is just noise:

- **On session start** — if you're not signed in, the agent gets one line so it can
  offer `basalt login` *before* your first publish fails. Signed in? Nothing.
- **While you work** — edits to a file under a `vault.yaml` are quietly tracked (no
  network, no output).
- **At the end of a turn** — if you edited vault docs but didn't publish, one line
  asks whether to publish. Set `publish: auto` in that `vault.yaml` and it publishes
  the changed files for you (diff-aware, once per turn — never on every keystroke).

Per-vault policy lives in `vault.yaml`: `publish: prompt` (default) · `auto` ·
`manual`. When one doc needs a different answer than its vault — the server refuses
it, say — an optional `publish_overrides:` block gives that exact path its own policy,
so you don't have to silence the whole vault to quiet one file. Every hook ships with
tests that run against **real captured Claude Code payloads** (`hooks/tests/run.sh`) —
a silent hook is worthless if it's silently dead.

## The links band (every doc of the session, one key away)

Agents publish docs mid-conversation, and the URL scrolls away with the chat. The band
above the prompt keeps them: every `app.basalt.cofoundy.ai` link that enters the
session — from the CLI, the MCP, the model's own text or a subagent — lands there.

<p align="center">
  <img src="./assets/readme/links-band.svg" width="100%" alt="A Claude Code session where the agent published three docs. Above the prompt, the Basalt band shows the mark, 3 docs and the latest one, architecture-v2, with the buttons Open, Copy and All; a side pane lists every doc of the session with its space, folder and link.">
</p>

`o` opens the latest doc in your browser, `c` copies its URL, `l` (or `/basalt-links`)
opens a side pane with every doc of the session. The pane stays pinned across reloads
and sessions until you close it. Long nested names keep the title (cut in the middle,
so its version suffix survives), then the space, then the nearest folders.

The mark is the real logo where the surface can draw it: the SVG on the desktop app,
a PNG on kitty or Ghostty run directly, and `⬣` in Molten elsewhere (inside tmux,
screen, zellij or herdr Claude Code draws no pictures).

Labels are in English, and in Spanish when your locale is (`LC_ALL`, `LC_MESSAGES` or
`LANG` starting with `es`).

It is a Claude Code function-hooks module (early access); clients without function
hooks keep the three shell hooks above, unchanged. Already installed? Update the
plugin (`/plugin` → basalt → update) and run `/reload-plugins`.

## Already have docs in git?

Use the [`basalt` CLI](https://www.npmjs.com/package/basalt-cli) instead — it syncs a
git repo diff-aware and keeps git the source of truth. This plugin (MCP) is for
content **born in a conversation**; the CLI is for content that already lives in a repo.

## MCP endpoint

```
https://app.basalt.cofoundy.ai/api/mcp
```

No token to paste — the first call runs OAuth in your browser. Headless/CI callers
can use a static bearer (see the Basalt docs).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Run `bash scripts/validate-skills.sh` before a PR.

## License

MIT — see [LICENSE](./LICENSE). Dogfooded and maintained by [Cofoundy](https://cofoundy.dev).

---

_Basalt is a [Cofoundy](https://cofoundy.dev) product. **Agents create. Basalt
governs. Humans decide. Companies remember.**_

<sub>publish docs from an AI agent · Claude Code MCP plugin · agent skill to publish &
share markdown by URL · governed, permissioned, versioned AI documentation · Claude,
Codex, Cursor, OpenCode</sub>
