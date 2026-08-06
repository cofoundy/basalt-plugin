# Path A — the content already lives in a git repo

Git is the source of truth; the CLI mirrors it diff-aware. Nothing is retyped, and
publishing the same file twice is an update, not a fork.

```bash
basalt publish <file> --strict
```

That is the whole normal case. `--strict` exits non-zero when any published doc has an
unresolved wikilink — keep it on, since it is what makes a space a navigable graph
instead of a pile of orphan pages.

## When something is off: `basalt onboard`

Run it when a publish errors, or when this repo has never published before. It derives a
6-rung ladder from the repo's real state and prints the exact next step:

```
basalt onboard — rung 3/6 (publishing loose, no vault)
  ✓ CLI   ✓ session   ✓ publisher key   · vault.yaml   ✓ git repo   · CI publish workflow
  NEXT → create vault.yaml (`name: <project>`) at the docs root
```

Follow its NEXT instead of improvising setup. It is a diagnostic, not a ritual before
every publish.

## The one failure that does not error: no `vault.yaml`

Without a `vault.yaml` at the docs root there is no project binding, so the CLI takes the
**first path segment as the space name**:

```
no vault.yaml    docs/PRD.md  →  project "docs",   slug "prd"        exit 0, no warning
with vault.yaml  docs/PRD.md  →  project "<repo>", slug "docs/prd"
```

The publish reports success and lands in a space nobody meant to create. Every other
error in this system is loud; this one is not. Before the first publish in a repo,
confirm the binding:

```bash
basalt status <file> --json     # the `project` field must be the intended space
```

A `vault.yaml` is two lines and fixes the whole tree at once — the file tree becomes the
space tree, and slugs become paths:

```yaml
name: <project>
publish: prompt      # auto | prompt | manual — how the Stop hook behaves
```

## Unattended runs

The CLI credential is stored per host, so once `basalt login` has happened on this
machine, publishing needs no browser and no human. `basalt onboard` reports whether that
session exists (`✓ session`) before anything depends on it.

This is why an agent running in a worktree, a background job, or CI belongs on this path:
the MCP's first call can open an OAuth approval that nobody is present to grant.
