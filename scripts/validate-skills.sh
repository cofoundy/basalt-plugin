#!/usr/bin/env bash
# Validate the basalt plugin: every skill has SKILL.md with name+description
# frontmatter (name matches dir), the plugin manifest + MCP declaration are valid
# JSON, and the marketplace entry's source path exists on disk.
#
# NOTE ON LAYOUT: this repo is an MCP-bearing Claude Code plugin, so it uses the
# plugin-DIR layout (plugins/<name>/{.claude-plugin/plugin.json,.mcp.json,skills/…})
# — the same shape as the official figma MCP plugin — NOT the skills-only flat
# layout. The validator walks the plugin dir declared in marketplace.json.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
manifest=".claude-plugin/marketplace.json"

json_ok() { python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }

echo "→ marketplace.json is valid JSON"
if json_ok "$manifest"; then echo "  ✓ $manifest"; else echo "  ✗ $manifest: invalid JSON"; fail=1; fi

# Resolve each plugin's source dir from the manifest and validate it.
plugin_dirs=$(python3 -c "
import json
m=json.load(open('$manifest'))
for p in m.get('plugins',[]):
    print(p.get('source','').lstrip('./'))
" 2>/dev/null)

for pdir in $plugin_dirs; do
  echo "→ plugin: $pdir"
  [[ -d "$pdir" ]] || { echo "  ✗ manifest source '$pdir' missing on disk"; fail=1; continue; }

  # plugin.json
  pj="$pdir/.claude-plugin/plugin.json"
  if [[ -f "$pj" ]] && json_ok "$pj"; then echo "  ✓ plugin.json"; else echo "  ✗ $pj: missing/invalid"; fail=1; fi

  # .mcp.json (this plugin bundles an MCP server — it MUST be declared here, not
  # inline in plugin.json, which Claude Code ignores)
  mcp="$pdir/.mcp.json"
  if [[ -f "$mcp" ]] && json_ok "$mcp"; then
    grep -q '"mcpServers"' "$mcp" && echo "  ✓ .mcp.json (mcpServers declared)" || { echo "  ✗ .mcp.json: no mcpServers key"; fail=1; }
  else
    echo "  ✗ $mcp: missing/invalid"; fail=1
  fi

  # skills
  for d in "$pdir"/skills/*/; do
    [[ -d "$d" ]] || continue
    name="${d%/}"; name="${name##*/}"
    f="${d}SKILL.md"
    ok=1
    [[ -f "$f" ]] || { echo "  ✗ skill $name: missing SKILL.md"; fail=1; continue; }
    grep -qE '^name:' "$f" || { echo "  ✗ skill $name: SKILL.md missing 'name:'"; fail=1; ok=0; }
    grep -qE '^description:' "$f" || { echo "  ✗ skill $name: SKILL.md missing 'description:'"; fail=1; ok=0; }
    # name frontmatter must match the directory
    fm_name=$(grep -E '^name:' "$f" | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')
    [[ "$fm_name" == "$name" ]] || { echo "  ✗ skill $name: frontmatter name '$fm_name' != dir '$name'"; fail=1; ok=0; }
    [[ $ok -eq 1 ]] && echo "  ✓ skill $name"
  done
done

[[ $fail -eq 0 ]] && echo "✓ all valid" || { echo "✗ validation failed"; exit 1; }
