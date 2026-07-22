# Basalt — Claude Code plugin

**Connect your AI to [Basalt](https://app.basalt.cofoundy.ai) — the trust layer for
AI-generated work.** Ask your agent to *publish* or *share* something and it converges
here: markdown in → a branded, permissioned, versioned page at a URL your colleague can
open and review.

This plugin bundles two things in one install:

- **The Basalt MCP server** (`.mcp.json`, HTTP + OAuth) — your agent reads, publishes,
  updates and shares docs as *you*, inheriting your permissions.
- **A skill** that teaches the agent to reach for Basalt when you say "publish this",
  "document this", "share this doc", "publica esto" — no command to type; it
  auto-invokes on the task.

## Install

```
/plugin marketplace add cofoundy/basalt-plugin
/plugin install basalt@basalt
```

The first time your agent uses a Basalt tool, a browser login (OAuth) opens — approve
once and you're connected to your workspace.

## Use it

Just ask, in plain language:

> "Write up how our auth service works and **publish it** so the team can review."

The agent writes the doc, calls `publish_doc`, and hands you back a **live URL** to
share. That link is the whole point — send it to your colleague and they read (and
comment) directly.

Manual invocation is available as `/basalt`, but you rarely need it — the skill fires
on the natural request.

## What it can do

Once connected, your agent can (within *your* permissions):

- Read any doc you have access to (`list_docs`, `read_doc`, `search_docs`).
- Publish & update docs by URL, versioned (`publish_doc`, `update_doc`).
- Share a doc with a colleague or client (`set_access`).
- Read review comments, propose a diff, and republish — the full review loop.

## Already have docs in git?

Use the [`basalt` CLI](https://www.npmjs.com/package/basalt-cli) instead — it syncs a
git repo diff-aware and keeps git the source of truth. MCP (this plugin) is for content
born in a conversation; the CLI is for content that already lives in a repo.

## MCP endpoint

The plugin points at the single canonical endpoint:

```
https://app.basalt.cofoundy.ai/api/mcp
```

No token to paste — the first call runs OAuth in your browser. For headless/CI callers,
Basalt also supports a static bearer (see the Basalt docs).

---

_Basalt is a [Cofoundy](https://cofoundy.dev) product. Agents create. Basalt governs.
Humans decide. Companies remember._
