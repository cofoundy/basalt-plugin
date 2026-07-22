---
description: Publish or share the current work to Basalt — turn markdown into a branded, permissioned, versioned page at a URL a colleague can review. Manual entry to the same flow the skill auto-invokes.
---

You are helping the user publish or share written work on **Basalt** (the trust
layer for AI-generated work). The Basalt MCP server is connected via this plugin.

Arguments (optional): `$ARGUMENTS` may name what to publish (a file, a topic, or
"this"). If empty, infer from the current conversation / working directory.

Do this:

1. **`get_context`** — confirm who the user is and which workspace is active. If the
   MCP asks for authorization, tell the user to approve the one-time OAuth login in
   their browser (`/mcp` in an interactive session, or their claude.ai connector
   settings), then continue.
2. **Look before writing** — `list_docs` / `read_doc` on a couple of existing docs so
   the new page matches the workspace's conventions (frontmatter, headings, links).
3. **Write the doc** in clean markdown — a single `# H1` title, short sections. For
   data-shaped content use Basalt's MDX components, not raw HTML.
4. **`publish_doc`** — it compiles, lints, versions, and returns the **live URL**.
   That URL is the deliverable; do not paste the whole body back into chat.
5. **Hand it off** — give the user the **title + the live URL** in one line and tell
   them to send it. If it is for a specific colleague or client, `set_access` them so
   the link opens.

To revise an already-published doc, use **`update_doc`** — never publish a second
near-duplicate. If the docs already live in a **git repo**, prefer the `basalt` CLI
(`npm i -g basalt-cli`) which syncs the repo diff-aware instead of retyping through MCP.
