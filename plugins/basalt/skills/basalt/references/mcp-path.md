# Path B — the content was born in this conversation

Nothing on disk to sync, so you are authoring. The tools you need are few:

- **`get_context`** — who you are and which workspace you're in. Call it first so the doc
  lands in the right place.
- **`list_docs` / `read_doc`** — read a couple of existing docs so the new one matches the
  house structure and conventions (frontmatter, headings, link style). Read before you write.
- **`publish_doc`** — the action. Title + markdown; it compiles, lints, versions, and
  returns the **live URL**. That URL is the deliverable.
- **`update_doc`** — revise in place. **Update, never re-publish a near-duplicate** — a
  second copy fragments the record.
- **`set_access`** — share. For a specific colleague or client, grant them read (or
  comment) access so the link actually opens.

## The flow

1. `get_context` — confirm the active workspace and identity.
2. Look before you write — `list_docs` / `read_doc` on a couple of existing docs.
3. Author the doc: a single `# H1` title, short sections. For data-shaped content (KPIs,
   callouts, diagrams) use Basalt's MDX components rather than raw HTML — the tool's own
   guidance (`instructions` + `basalt://` resources) spells out what is available.
4. `publish_doc` — it returns the URL. **That link is the aha.** Do not paraphrase or
   re-summarize the body back into chat as "the output"; the page is the output.
5. Hand it off — the **title + the live URL** in one line. If it is for a named person,
   `set_access` them first so the link opens.

> Example close: *"Published **Project Atlas — Architecture** → it's live at
> `https://app.basalt.cofoundy.ai/…`. Send that link to your colleague; they can read and
> comment on it directly."*

## Authentication

The first tool call opens a **browser login (OAuth)**. Ask the user to approve it once;
after that the session is cached and every later call is silent. A call that comes back
needing auth is the expected first-run step, not an error.

**No human to ask?** Running unattended — a background agent, a worktree, CI, a scheduled
job — do not open with the MCP: you would block on an approval nobody is there to give.
Take Path A instead (`references/cli-path.md`), whose credential is per host.
