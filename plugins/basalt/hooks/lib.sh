#!/usr/bin/env bash
# lib.sh — shared helpers for the Basalt session-boundary hooks.
#
# WORLD-READABLE PLUGIN (ADR-0001): zero secrets, zero Cofoundy content. These hooks
# only invoke the user's own `basalt` CLI with the user's own credentials.
#
# Payload shapes are the REAL ones captured 2026-07-24 (see hooks/tests/fixtures/ and
# cofoundy-toolkit/docs/claude-code-capabilities.md). Load-bearing facts baked in here:
#   - PostToolUse `tool_input.file_path` is an ABSOLUTE path (Write + Edit).
#   - Every event in a run shares one `session_id` (subagent tool calls included) —
#     so the dirty-list keyed by session_id captures subagent edits too.
#   - Payloads are valid JSON but a `tool_response` diff line serialises as
#     "\\ No newline at end of file"; `echo "$p" | jq` CORRUPTS it. We read stdin via
#     here-strings (`<<<`), never `echo`.

# --- JSON extraction: prefer jq, then python3, then a flat grep last resort ----------
# json_get <payload> <dotted.path>  ->  prints the value (strings unquoted) or empty.
json_get() {
  local payload="$1" path="$2" out=""
  if command -v jq >/dev/null 2>&1; then
    # NB: `getpath(…) // empty` is WRONG — jq's `//` treats a boolean `false` as falsy and
    # collapses it to empty, so `state.session:false` would read as missing. Convert
    # explicitly: null → "", everything else → its string form (false→"false", true→"true").
    out=$(jq -r "getpath(\"$path\" | split(\".\")) as \$v | if \$v == null then \"\" else (\$v | tostring) end" <<<"$payload" 2>/dev/null) && {
      printf '%s' "$out"; return 0;
    }
  fi
  if command -v python3 >/dev/null 2>&1; then
    out=$(BP_PATH="$path" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
for k in os.environ["BP_PATH"].split("."):
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else (d if isinstance(d, str) else json.dumps(d)))
' <<<"$payload" 2>/dev/null) && { printf '%s' "$out"; return 0; }
  fi
  # Last resort (no jq, no python): grep the LAST path component as a flat key. Handles
  # "file_path":"…", "session_id":"…", "stop_hook_active":true. Good enough for the flat
  # fields these hooks read; nested objects are not reachable this way.
  local key="${path##*.}"
  grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false|[0-9]+)" <<<"$payload" \
    | head -1 | sed -E 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

# --- dirty-list: one file per session, under a stable temp dir -----------------------
dirty_dir() { printf '%s/basalt-hooks' "${TMPDIR:-/tmp}"; }
dirty_file() { printf '%s/dirty-%s.list' "$(dirty_dir)" "$1"; }   # $1 = session_id

# --- vault discovery: walk up from a file to the nearest vault.yaml -------------------
# find_vault <abs-file-path>  ->  prints the vault.yaml path, or empty if none upward.
find_vault() {
  local d
  d=$(dirname "$1" 2>/dev/null) || return 0
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/vault.yaml" ]; then printf '%s/vault.yaml' "$d"; return 0; fi
    d=$(dirname "$d")
  done
  [ -f "/vault.yaml" ] && printf '/vault.yaml'
  return 0
}

# vault_policy <vault.yaml-path>  ->  auto | prompt | manual  (default prompt).
vault_policy() {
  local v="$1" p=""
  [ -f "$v" ] || { printf 'prompt'; return 0; }
  p=$(grep -iE '^[[:space:]]*publish:[[:space:]]*' "$v" 2>/dev/null | head -1 \
      | sed -E 's/^[[:space:]]*publish:[[:space:]]*//I; s/[[:space:]#].*$//' | tr 'A-Z' 'a-z')
  case "$p" in
    auto|prompt|manual) printf '%s' "$p" ;;
    *) printf 'prompt' ;;
  esac
}
