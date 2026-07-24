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

vault="$(find_vault "$file")"
[ -n "$vault" ] || exit 0                              # not under a vault → ignore

sid="$(json_get "$payload" "session_id")"
[ -n "$sid" ] || sid="nosession"

mkdir -p "$(dirty_dir)" 2>/dev/null || exit 0
df="$(dirty_file "$sid")"
# dedupe: only append if not already listed
if ! { [ -f "$df" ] && grep -Fxq "$file" "$df"; }; then
  printf '%s\n' "$file" >> "$df"
fi
exit 0
