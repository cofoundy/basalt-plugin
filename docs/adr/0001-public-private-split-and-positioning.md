# ADR 0001 — Public/private split, layout, and positioning

- **Status:** accepted
- **Date:** 2026-07-22

## Context

`cofoundy/basalt-plugin` is the public on-ramp that connects an AI agent to
[Basalt](https://app.basalt.cofoundy.ai), the trust layer for AI-generated work.
It is a lead magnet for the product: the moat is the *product* (governed publish,
RBAC, versioning, review loop), not anything withheld from this repo.

## Decisions

### 1. Public/private split

- **PUBLIC (this repo):** only what runs for a stranger with just an agent + a
  Basalt login — the `.mcp.json` pointing at the *public* MCP endpoint, the skill,
  the `/basalt` command, docs. **Zero secrets, keys, or private infra.** Auth is
  per-user OAuth handled by Basalt/Casdoor; the plugin holds no credentials.
- **PRIVATE (the Basalt app + Cofoundy vault):** the MCP server implementation,
  RBAC, tenancy, the static-bearer hatch, deploy infra, and all strategy. Those
  live in the private `cofoundy/basalt` repo and `core/`, never here.

### 2. Layout — plugin-dir, not skills-only-flat

This plugin bundles an **MCP server**, so it uses the plugin-DIR layout
(`plugins/basalt/{.claude-plugin/plugin.json, .mcp.json, skills/…, commands/…}`),
the same shape as the official figma MCP plugin — NOT the skills-only *flat* layout
(top-level `skills/`) used by pure-skill repos like `cofoundy/brand-skills`. The MCP
is declared in `.mcp.json` (Claude Code ignores an inline `mcpServers` in
`plugin.json` — a known bug), which is why a dedicated file is load-bearing.

Dual install rails are preserved: `npx skills add cofoundy/basalt-plugin` (the
skills ecosystem, 70+ agents — the CLI discovers the nested `SKILL.md` recursively)
and `/plugin marketplace add cofoundy/basalt-plugin` (native Claude Code).

### 3. Positioning — earn-it (soft v0)

Ship soft: "connect your AI to Basalt and publish a doc by URL." No loud category
claims until there is external proof. The plugin's job is convergence, not hype:
the skill's `description` makes an agent reach for Basalt on "publish / share /
document this" — that behavior, not marketing copy, is the product.

## Consequences

- The repo is forkable and clean; anyone can read exactly what their agent will run.
- Distribution is GitHub-native (no npm publish): the skills CLI + the Claude Code
  marketplace both resolve `owner/repo` directly.
- skills.sh listing is usage-driven (no submit API); the badge stays commented until
  the repo is indexed via real install telemetry.
