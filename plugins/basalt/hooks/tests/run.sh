#!/usr/bin/env bash
# run.sh — L-009 tests for the Basalt session-boundary hooks.
#
# THE RULE (cantera L-009): a hook whose success mode is SILENCE is indistinguishable from
# a DEAD hook. So every hook here is proven against the REAL payloads Claude Code sends
# (hooks/tests/fixtures/*, captured 2026-07-24 — see cofoundy-toolkit/docs/claude-code-
# capabilities.md), asserting it FIRES when it should, stays SILENT when it should, dies
# MUTE without the CLI, and that Stop NEVER loops. A negative control (wrong-shape payload)
# must produce silence + exit 0.
#
#   bash plugins/basalt/hooks/tests/run.sh     # exits non-zero on any failure
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tests/
HOOKS="$(dirname "$HERE")"                              # hooks/
FIX="$HERE/fixtures"
pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

command -v jq >/dev/null 2>&1 || { echo "these tests need jq to build fixtures"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
DDIR="$TMPDIR/basalt-hooks"
reset_dirty() { rm -rf "$DDIR"; }

# --- stub `basalt` (mode-driven) ------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
export BASALT_STUB_CALLS="$WORK/publish-calls.log"
cat > "$BIN/basalt" <<'STUB'
#!/usr/bin/env bash
case "${BASALT_STUB_MODE:-}" in
  noauth) [ "$1" = "onboard" ] && { echo '{"state":{"session":false,"vault":{"found":false}},"rung":1}'; exit 0; } ;;
  authed) [ "$1" = "onboard" ] && { echo '{"state":{"session":true,"vault":{"found":false}},"rung":3}'; exit 0; } ;;
  publish-ok)   [ "$1" = "publish" ] && { shift; printf '%s\n' "$@" >> "$BASALT_STUB_CALLS"; exit 0; } ;;
  publish-fail) [ "$1" = "publish" ] && exit 7 ;;
esac
exit 0
STUB
chmod +x "$BIN/basalt"
PATH_WITH_STUB="$BIN:$PATH"
PATH_NO_BASALT="/usr/bin:/bin"                          # excludes ~/.local/bin (real basalt)

run() { printf '%s' "$1" | bash "$2"; }                # run <payload> <script> ; prints stdout

echo "── session-start.sh ─────────────────────────────────────────"
SS="$FIX/sessionstart-startup.json"

out="$(PATH="$PATH_WITH_STUB" BASALT_STUB_MODE=noauth run "$(cat "$SS")" "$HOOKS/session-start.sh")"
if printf '%s' "$out" | grep -q 'basalt login' \
   && printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  ok "no auth → injects a login-permission line"
else no "no auth → should inject a login line (got: $out)"; fi

ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if [ "${#ctx}" -le 200 ] && [ "${#ctx}" -gt 0 ]; then ok "budget: additionalContext ${#ctx}B ≤ 200B"
else no "budget: additionalContext is ${#ctx}B (must be 1..200)"; fi

out="$(PATH="$PATH_WITH_STUB" BASALT_STUB_MODE=authed run "$(cat "$SS")" "$HOOKS/session-start.sh")"
[ -z "$out" ] && ok "authed → SILENT (common case)" || no "authed → should be silent (got: $out)"

out="$(PATH="$PATH_NO_BASALT" run "$(cat "$SS")" "$HOOKS/session-start.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "no CLI → dies MUTE (exit 0)" || no "no CLI → should be mute exit 0 (out:$out rc:$rc)"

echo "── post-edit.sh ─────────────────────────────────────────────"
reset_dirty
VAULT="$WORK/vaultproj"; mkdir -p "$VAULT/docs"
printf 'name: testvault\npublish: prompt\n' > "$VAULT/vault.yaml"
DOC="$VAULT/docs/test.md"; echo hi > "$DOC"
sid_pe="$(jq -r .session_id "$FIX/posttooluse-write.json")"
DF_PE="$DDIR/dirty-$sid_pe.list"

pl="$(jq -c --arg f "$DOC" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
out="$(PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh")"
{ [ -z "$out" ] && [ -f "$DF_PE" ] && grep -Fxq "$DOC" "$DF_PE"; } \
  && ok "Write under vault → tracked, zero output" || no "Write under vault → should track $DOC silently"

pl="$(jq -c --arg f "$DOC" '.tool_input.file_path=$f' "$FIX/posttooluse-edit.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
n="$(wc -l < "$DF_PE" 2>/dev/null | tr -d ' ')"
[ "$n" = "1" ] && ok "Edit same file → deduped (still 1 entry)" || no "dedupe failed (entries=$n)"

OUTSIDE="$WORK/novault/x.md"; mkdir -p "$WORK/novault"; echo y > "$OUTSIDE"
pl="$(jq -c --arg f "$OUTSIDE" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
n="$(wc -l < "$DF_PE" 2>/dev/null | tr -d ' ')"
[ "$n" = "1" ] && ok "edit OUTSIDE any vault → ignored" || no "outside-vault should be ignored (entries=$n)"

out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/posttooluse-no-filepath.json")" "$HOOKS/post-edit.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "negative control (no file_path) → silent, exit 0" || no "negative control should be silent (out:$out rc:$rc)"

out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/malformed.json")" "$HOOKS/post-edit.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "malformed payload → silent, exit 0" || no "malformed should be silent (out:$out rc:$rc)"

echo "── stop.sh ──────────────────────────────────────────────────"
sid_stop="$(jq -r .session_id "$FIX/stop-inactive.json")"
DF_STOP="$DDIR/dirty-$sid_stop.list"

mk_vault() { local d="$1" pol="$2"; mkdir -p "$d/docs"; printf 'name: v\npublish: %s\n' "$pol" > "$d/vault.yaml"; local f="$d/docs/a.md"; echo x > "$f"; printf '%s' "$f"; }

# prompt (default) → block nudge, dirty cleared
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/vp" prompt)"; printf '%s\n' "$D" > "$DF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
if printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 \
   && printf '%s' "$out" | grep -qi 'unpublished' && [ ! -f "$DF_STOP" ]; then
  ok "prompt policy → {decision:block} nudge, dirty-list cleared"
else no "prompt policy → expected block nudge + cleared list (got: $out)"; fi

# prompt nudge stays within 200B reason budget
rlen="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null | wc -c | tr -d ' ')"
[ "$rlen" -le 201 ] && ok "budget: Stop reason ${rlen}B ≤ 200B" || no "Stop reason too long (${rlen}B)"

# manual → silent, dirty cleared
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/vm" manual)"; printf '%s\n' "$D" > "$DF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
{ [ -z "$out" ] && [ ! -f "$DF_STOP" ]; } && ok "manual policy → silent, dirty cleared" || no "manual should be silent+cleared (got: $out)"

# auto + publish OK → plain receipt (NOT block), CLI called, dirty cleared
reset_dirty; mkdir -p "$DDIR"; : > "$BASALT_STUB_CALLS"; D="$(mk_vault "$WORK/va" auto)"; printf '%s\n' "$D" > "$DF_STOP"
out="$(PATH="$PATH_WITH_STUB" BASALT_STUB_MODE=publish-ok run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
if printf '%s' "$out" | grep -qi 'auto-published' \
   && ! printf '%s' "$out" | grep -q 'decision' \
   && grep -Fxq "$D" "$BASALT_STUB_CALLS" && [ ! -f "$DF_STOP" ]; then
  ok "auto policy + CLI ok → publishes once, plain receipt, no model turn"
else no "auto policy → expected publish + plain receipt (out:$out calls:$(cat "$BASALT_STUB_CALLS"))"; fi

# auto + no CLI → degrade to block nudge
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/va2" auto)"; printf '%s\n' "$D" > "$DF_STOP"
out="$(PATH="$PATH_NO_BASALT" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "auto policy + no CLI → degrades MUTE-safe to a nudge" || no "auto+noCLI should degrade to nudge (got: $out)"

# stop_hook_active=true → SILENT, exit 0, dirty-list PRESERVED (never loops, never clears)
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/vg" prompt)"; printf '%s\n' "$D" > "$DF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-active-guard.json")" "$HOOKS/stop.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ] && [ -f "$DF_STOP" ]; } \
  && ok "stop_hook_active → silent (loop guard), list untouched" || no "guard should be silent + preserve list (out:$out rc:$rc)"

# empty dirty-list → silent
reset_dirty; mkdir -p "$DDIR"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
[ -z "$out" ] && ok "no dirty-list → silent (the common case)" || no "empty should be silent (got: $out)"

echo "─────────────────────────────────────────────────────────────"
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
