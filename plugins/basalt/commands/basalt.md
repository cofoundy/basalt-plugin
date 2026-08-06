---
description: Publish or share the current work to Basalt — turn markdown into a branded, permissioned, versioned page at a URL a colleague can review. Manual entry to the same flow the skill auto-invokes.
---

You are helping the user publish or share written work on **Basalt** (the trust
layer for AI-generated work). This plugin ships both channels: the Basalt MCP server
and the `basalt` CLI.

Arguments (optional): `$ARGUMENTS` may name what to publish (a file, a topic, or
"this"). If empty, infer from the current conversation / working directory.

**First, pick the channel — one question decides everything after it:**

> Does the content already exist as a file in a git repo?

- **Yes** → the **CLI**. Git stays the source of truth and the CLI syncs diff-aware.
- **No**, it was born in this conversation → the **MCP**.

## If it is a file in a repo (CLI)

```bash
basalt publish <file> --strict
```

`--strict` exits non-zero on any unresolved wikilink — keep it on so the space stays a
navigable graph. If the publish errors, or this repo has never published, run
`basalt onboard`: it prints a 6-rung ladder from the repo's real state and the exact
next step. Follow that step instead of improvising setup.

⚠️ **On a repo's FIRST publish, check the project binding.** Without a `vault.yaml` at
the docs root the CLI takes the first path segment as the space name — `docs/PRD.md`
publishes as project `docs` / slug `prd` instead of project `<repo>` / slug `docs/prd`.
Exit 0, no warning, wrong space. Confirm with `basalt status <file> --json` and check
the `project` field. It is the only failure here that does not announce itself.

## If it was born in this conversation (MCP)

1. **`get_context`** — confirm who the user is and which workspace is active. If the
   MCP asks for authorization, tell the user to approve the one-time OAuth login in
   their browser (`/mcp` in an interactive session, or their claude.ai connector
   settings), then continue. **Running unattended with no human to ask? Use the CLI
   instead** — its credential is per host and needs no browser.
2. **Look before writing** — `list_docs` / `read_doc` on a couple of existing docs so
   the new page matches the workspace's conventions (frontmatter, headings, links).
3. **Write the doc** in clean markdown — a single `# H1` title, short sections. For
   data-shaped content use Basalt's MDX components, not raw HTML.
4. **`publish_doc`** — it compiles, lints, versions, and returns the **live URL**.
   That URL is the deliverable; do not paste the whole body back into chat.
5. **Hand it off** — give the user the **title + the live URL** in one line and tell
   them to send it. If it is for a specific colleague or client, `set_access` them so
   the link opens.

To revise an already-published doc, use **`update_doc`** (MCP) or re-publish the same
file (CLI) — never a second near-duplicate.
