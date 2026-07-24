#!/usr/bin/env bash
# session-start.sh — SessionStart hook. Derives Basalt state locally and speaks ONE line
# ONLY when there is something actionable. Silence by default.
#
# The only state SessionStart can truthfully act on is "no auth" (`basalt onboard --json`
# → state.session == false): the day-zero flow where the agent should ask permission to
# `basalt login` before the first publish fails. Everything else (authed, vault or not) is
# SILENT — a dirty-doc signal doesn't exist yet at session start (that's the live PostToolUse
# dirty-list, empty here). No CLI installed → the probe fails → we exit 0 mute.
#
# Injection mechanism (VERIFIED 2026-07-24): stdout as
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}
# reaches the model's context. Budget: the line is ≤200 bytes.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

payload="$(cat)"

# Run the probe in the session's cwd so vault/git detection is correct.
cwd="$(json_get "$payload" "cwd")"
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null || true

command -v basalt >/dev/null 2>&1 || exit 0          # no CLI → mute

onboard="$(basalt onboard --json 2>/dev/null)" || exit 0
[ -n "$onboard" ] || exit 0

session="$(json_get "$onboard" "state.session")"      # true | false | ""
[ "$session" = "false" ] || exit 0                     # authed / unknown → SILENT

line='Basalt: no active session. If the user asks to publish or share written work, ask permission to run `basalt login` (opens a browser to approve).'

# Emit as additionalContext (JSON preferred; falls back to a hand-built object if no jq).
if command -v jq >/dev/null 2>&1; then
  jq -cn --arg c "$line" \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
else
  esc=${line//\\/\\\\}; esc=${esc//\"/\\\"}
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$esc"
fi
exit 0
