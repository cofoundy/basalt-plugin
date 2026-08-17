#!/usr/bin/env bash
# probe-harness.sh — OPT-IN, NOT CI. Run this when the supported Claude Code version moves.
#
# WHY IT EXISTS. `tests/run.sh` feeds fixtures to the hooks: it exercises THE HOOK, never
# the harness's firing policy. Mechanism A rests on one measured harness fact —
#
#   F2: PostToolUse fires ONLY when the Bash command exits 0
#
# — and `run.sh` cannot pin it. The payload has no exit-code field (F1), so the two worlds
# (fired-on-success / fired-on-failure) are BYTE-IDENTICAL on the wire: no "failed
# publish" fixture can be synthesized, and the hook cannot defend itself either. If a
# future version starts firing on non-zero exits, every assertion in `run.sh` still
# passes and the change is invisible — the exact green-and-silent class this work exists
# to fight.
#
# THE RESIDUAL RISK IN PLAIN WORDS: if the harness flips, a FAILED `basalt publish` clears
# the dirty entry and the hook goes quiet on a genuinely unpublished doc — the feature's
# one true positive, deleted, with no error. This script is what makes that visible.
#
# METHOD (the same control that produced F2): each command appends a marker to a log, so
# EXECUTIONS and HOOK FIRES are two independent instruments. Four commands, two exiting
# non-zero. All four markers must appear (every command really ran) and only the two
# zero-exit commands may produce a hook fire.
#
#   bash plugins/basalt/hooks/tests/probe-harness.sh
set -u
command -v claude >/dev/null 2>&1 || { echo "probe-harness.sh needs the \`claude\` CLI on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "probe-harness.sh needs jq"; exit 2; }

W="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$W"' EXIT
PROJ="$W/probe"; mkdir -p "$PROJ/.claude"
MARKERS="$PROJ/markers.log"; FIRES="$PROJ/fires.jsonl"
: > "$MARKERS"; : > "$FIRES"

cat > "$PROJ/.claude/settings.json" <<JSON
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "cat >> $FIRES" } ] }
    ]
  }
}
JSON

printf 'harness: %s\n' "$(claude --version 2>/dev/null || echo unknown)"
printf 'probing in %s\n\n' "$PROJ"

CMDS=(
  "echo A >> markers.log; true"
  "echo B >> markers.log; exit 7"
  "echo C >> markers.log; true"
  "echo D >> markers.log; exit 3"
)
for c in "${CMDS[@]}"; do
  ( cd "$PROJ" && claude -p "Run exactly this in Bash, nothing else: $c" \
      --allowedTools Bash >/dev/null 2>&1 ) || true
done

printf '%-34s %-6s %-8s %s\n' "Bash tool call" "exit" "marker" "hook fired"
rc=0
for i in 0 1 2 3; do
  c="${CMDS[$i]}"
  mark="$(printf '%s' "$c" | sed -n 's/^echo \([A-D]\).*/\1/p')"
  case "$c" in *"exit 7"*) want_exit=7 ;; *"exit 3"*) want_exit=3 ;; *) want_exit=0 ;; esac
  grep -Fxq "$mark" "$MARKERS" && got_mark=yes || got_mark=NO
  fired=no
  if [ -s "$FIRES" ] && jq -sr '.[].tool_input.command' "$FIRES" 2>/dev/null | grep -Fxq "$c"; then fired=yes; fi
  printf '%-34s %-6s %-8s %s\n' "$c" "$want_exit" "$got_mark" "$fired"
  [ "$got_mark" = yes ] || rc=1                       # the command must really have run
  if [ "$want_exit" = 0 ]; then
    [ "$fired" = yes ] || rc=1
  else
    [ "$fired" = no ] || rc=1                         # F2 HAS FLIPPED — see the header
  fi
done

echo
if [ $rc -eq 0 ]; then
  echo "F2 HOLDS on this harness: 4 executions, 2 fires, non-zero exits produce no payload."
else
  echo "F2 DOES NOT HOLD on this harness. Mechanism A's success semantics are no longer"
  echo "sound: a FAILED \`basalt publish\` can now clear a dirty entry, and the hook will"
  echo "go silent on a genuinely unpublished doc. Re-open the design before shipping."
fi
exit $rc
