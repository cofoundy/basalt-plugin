#!/usr/bin/env bash
# post-edit.sh — PostToolUse(Edit|Write) hook. If the edited file lives under a vault.yaml,
# record its absolute path in this session's dirty-list. ZERO network, ZERO output, always.
#
# Facts baked in (captured 2026-07-24): tool_input.file_path is ABSOLUTE for both Write and
# Edit; subagent edits fire this same hook carrying the parent session_id — so the dirty-list
# keyed by session_id naturally includes subagent edits, read back at the parent's Stop.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

payload="$(cat)"

file="$(json_get "$payload" "tool_input.file_path")"
[ -n "$file" ] || exit 0

sid="$(json_get "$payload" "session_id")"
[ -n "$sid" ] || sid="nosession"
mkdir -p "$(dirty_dir)" 2>/dev/null || exit 0

# append_once <listfile> <line>
append_once() {
  { [ -f "$1" ] && grep -Fxq "$2" "$1"; } || printf '%s\n' "$2" >> "$1"
}

vault="$(find_vault "$file")"
if [ -n "$vault" ]; then
  append_once "$(dirty_file "$sid")" "$file"           # under a vault → publishable
elif is_doc "$file"; then
  # A doc with no vault above it. Not an error yet — but a publish from here would land
  # in the wrong space silently, so record the REPO ROOT (not the file): the fix is one
  # `vault.yaml` per tree, and Stop should say it once, not once per file.
  root="$(cd "$(dirname "$file")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] && append_once "$(orphan_file "$sid")" "$root"
fi
exit 0
