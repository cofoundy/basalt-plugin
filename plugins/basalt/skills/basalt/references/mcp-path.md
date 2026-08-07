# Path B — the content was born in this conversation

Nothing on disk to sync, so you are authoring. The tools you need are few:

- **`get_context`** — who you are and which workspace you're in. Call it first so the doc
  lands in the right place.
- **`get_space`** — the space's **map**: its tree, its landing doc, and its link graph
  (resolved and pending edges). This is what tells you where a new doc BELONGS and what it
  should hang off. Read it before authoring, not after.
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
2. **`get_space` — read the map before you write into it.** The tree tells you where this
   doc belongs; the link graph tells you what should point at it.
3. Look before you write — `list_docs` / `read_doc` on a couple of existing docs.
4. Author the doc: a single `# H1` title, short sections. For data-shaped content (KPIs,
   callouts, diagrams) use Basalt's MDX components rather than raw HTML — the tool's own
   guidance (`instructions` + `basalt://` resources) spells out what is available.
5. **Link it into the graph.** A doc nothing points at is a page with a URL in a pit: it
   will not be found by the next reader, human or agent. Add the edge from the space's
   landing doc or from the nearest doc that already hangs off it.
6. `publish_doc` — it returns the URL. **That link is the aha.** Do not paraphrase or
   re-summarize the body back into chat as "the output"; the page is the output.
7. Hand it off — the **title + the live URL** in one line. If it is for a named person,
   `set_access` them first so the link opens.

Step 5 is the one that decays silently. A space is meant to be a navigable graph — section
→ document → the thing it changed — and every unlinked doc turns it back into a flat list
that only search can reach. `get_space` reports `links` with `resolved` and pending edges,
so the gap is measurable: compare edge count against node count before you call it done.

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
