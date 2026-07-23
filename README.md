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

## What you get

- **A shareable link, not a file.** `publish_doc` returns a live URL — that's the
  deliverable. Send it; your colleague reads and reviews in place.
- **It writes as *you*.** The agent inherits *your* Basalt permissions over MCP —
  it sees and changes exactly what you can, never more.
- **Zero typing.** The bundled skill auto-fires on "publish this / share this doc /
  documéntalo" — no command to memorize. (There's a `/basalt` command too, if you
  want it.)
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
└── skills/basalt/SKILL.md       # the auto-invoking skill (its description is the magic)
```

The plugin holds **no secrets** — it points at the public MCP endpoint and auth is
per-user OAuth. It's a thin, honest on-ramp; the product lives in Basalt.

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
