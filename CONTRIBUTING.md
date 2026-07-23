# Contributing to the Basalt plugin

`cofoundy/basalt-plugin` connects an AI agent to [Basalt](https://app.basalt.cofoundy.ai)
over MCP and teaches it to publish. Contributions — clearer skill guidance, more
agent coverage, docs — are welcome.

## Ground rules

1. **Public-only, no secrets.** Everything here must run for a stranger with just
   an agent + a Basalt login. The plugin points at the *public* MCP endpoint
   (`https://app.basalt.cofoundy.ai/api/mcp`); auth is per-user OAuth. Never add a
   dependency on a private key, token, or proprietary infra — that belongs in a
   downstream private layer, not here.
2. **Thin wrapper, not a fork of the product.** This repo is `.mcp.json` (the MCP
   server) + a skill + a command. Product behavior lives in Basalt itself; keep the
   plugin a thin, honest on-ramp.
3. **Layout.** This is an MCP-bearing Claude Code plugin, so it uses the plugin-dir
   layout: `plugins/basalt/{.claude-plugin/plugin.json, .mcp.json, skills/<name>/SKILL.md,
   commands/*.md}`. The MCP is declared in `.mcp.json` (NOT inline in `plugin.json`,
   which Claude Code ignores). Each skill's `SKILL.md` has `name:` + `description:`
   frontmatter, and `name` matches its directory.
4. **The skill's `description` is load-bearing.** It is what makes the agent converge
   on Basalt without the user typing a command. Edits to it are edits to the product's
   discoverability — treat them with care and test that the skill still fires on
   "publish / share / document this" (EN + ES).

## Before opening a PR

```bash
bash scripts/validate-skills.sh          # frontmatter + MCP + manifest↔disk
claude plugin validate plugins/basalt    # Claude Code manifest check (if the CLI is installed)
```

Both must be green. CI runs `validate-skills.sh` on every PR.

## Verify it installs

```bash
npx skills add cofoundy/basalt-plugin --list         # the skills-CLI rail (70+ agents)
# or, in Claude Code:
/plugin marketplace add cofoundy/basalt-plugin && /plugin install basalt@basalt
```
