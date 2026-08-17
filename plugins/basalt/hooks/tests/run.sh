#!/usr/bin/env bash
# run.sh — L-009 tests for the Basalt session-boundary hooks.
#
# THE RULE (cantera L-009): a hook whose success mode is SILENCE is indistinguishable from
# a DEAD hook. So every hook here is proven against the REAL payloads Claude Code sends
# (hooks/tests/fixtures/* — captured payload SHAPES, sanitized values), asserting it FIRES when
# it should, stays SILENT when it should, dies MUTE without the CLI, and that Stop NEVER
# loops. A negative control (wrong-shape payload) must produce silence + exit 0.
#
# THE SECOND RULE this file now carries: a fix that silences the hook in every arm has
# DELETED the feature rather than repaired it. So every positive (goes silent) is paired
# with the negative that must still nag, and the pairs are named as pairs.
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
command -v git >/dev/null 2>&1 || { echo "these tests need git for the Mechanism B fixtures"; exit 2; }

# `pwd -P` matters: post-publish.sh canonicalises a resolved base the same way, and on
# macOS `mktemp -d` hands back /var/… which is a symlink to /private/var/….
WORK="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
DDIR="$TMPDIR/basalt-hooks"
reset_dirty() { rm -rf "$DDIR"; }

# Hermetic git: never let an ambient repo above $WORK, a user gitconfig, or a system
# gitconfig answer a question these fixtures are asking. Without the ceiling, a doc in a
# non-repo fixture dir resolves to whatever repo happens to contain $TMPDIR.
export GIT_CEILING_DIRECTORIES="$WORK"
export GIT_CONFIG_NOSYSTEM=1
export HOME="$WORK/home"; mkdir -p "$HOME"
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true

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

# --- journal introspection ------------------------------------------------------------
# The dirty list is an append-only JOURNAL (A2). Its raw line count is NOT the answer to
# "how many docs are dirty" — the replayed live set is. Assertions that count raw lines
# are the ones B2 had to rewrite.
live_set() { bash -c '. "$1"; replay_journal "$2"' _ "$HOOKS/lib.sh" "$1"; }
live_n()   { live_set "$1" | awk 'NF{n++} END{print n+0}'; }
raw_n()    { [ -f "$1" ] && awk 'END{print NR+0}' "$1" || printf '0'; }

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
  && ok "Write under vault → tracked, zero output" || no "Write under vault → should track the doc silently"

# B2 — this assertion used to read `wc -l == 1`, and it went red for the RIGHT reason:
# the dirty append is now UNCONDITIONAL (B1), because `append_once` dedups against
# HISTORY and the journal keeps a tombstoned path forever — `p ; -p` makes a re-edit's
# append a no-op and Stop goes SILENT on a re-dirtied doc. Restoring the dedup turns this
# suite green OVER that bug. So the assertion is on the REPLAYED LIVE SET, and the raw
# count is asserted too, to pin that the append really is unconditional.
pl="$(jq -c --arg f "$DOC" '.tool_input.file_path=$f' "$FIX/posttooluse-edit.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
{ [ "$(raw_n "$DF_PE")" = "2" ] && [ "$(live_n "$DF_PE")" = "1" ]; } \
  && ok "B2: re-Edit APPENDS unconditionally (2 raw lines), replayed live set is 1" \
  || no "B2: expected 2 raw / 1 live (raw=$(raw_n "$DF_PE") live=$(live_n "$DF_PE"))"

OUTSIDE="$WORK/novault/x.md"; mkdir -p "$WORK/novault"; echo y > "$OUTSIDE"
pl="$(jq -c --arg f "$OUTSIDE" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
{ [ "$(raw_n "$DF_PE")" = "2" ] && [ "$(live_n "$DF_PE")" = "1" ]; } \
  && ok "B2: edit OUTSIDE any vault → journal untouched, live set still 1" \
  || no "outside-vault should be ignored (raw=$(raw_n "$DF_PE") live=$(live_n "$DF_PE"))"

out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/posttooluse-no-filepath.json")" "$HOOKS/post-edit.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "negative control (no file_path) → silent, exit 0" || no "negative control should be silent (out:$out rc:$rc)"

# --- orphan sensor: a doc edited where NO vault.yaml exists above it -------------------
# The one Basalt failure that returns exit 0: with no vault.yaml there is no project
# binding, so `docs/PRD.md` publishes as project "docs" / slug "prd" instead of
# project "<repo>" / slug "docs/prd" — wrong space, no warning. PostToolUse records the
# repo root; Stop speaks once. Narrow by design: a README in a code repo must not trip it.
# `append_once` STAYS here (B1 removed it from the dirty list only): the dedup is
# semantically required — the fix is one vault.yaml, not one per file.
reset_dirty
ORPH="$WORK/orphanrepo"; mkdir -p "$ORPH/docs"
( cd "$ORPH" && git init -q && git config user.email t@example.invalid && git config user.name t ) >/dev/null 2>&1
ORPH_REAL="$(cd "$ORPH" && git rev-parse --show-toplevel)"
OF_PE="$DDIR/orphan-$sid_pe.list"

echo x > "$ORPH/docs/PRD.md"
pl="$(jq -c --arg f "$ORPH/docs/PRD.md" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
out="$(PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh")"
{ [ -z "$out" ] && [ -f "$OF_PE" ] && grep -Fxq "$ORPH_REAL" "$OF_PE"; } \
  && ok "doc with no vault → repo root recorded, zero output" || no "orphan not recorded"

echo x > "$ORPH/docs/OTHER.md"
pl="$(jq -c --arg f "$ORPH/docs/OTHER.md" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
n="$(wc -l < "$OF_PE" | tr -d ' ')"
[ "$n" = "1" ] && ok "second doc, same repo → ONE entry (append_once stays on the orphan list)" \
  || no "orphan should dedupe by repo root (entries=$n)"

echo x > "$ORPH/README.md"
pl="$(jq -c --arg f "$ORPH/README.md" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
n="$(wc -l < "$OF_PE" | tr -d ' ')"
[ "$n" = "1" ] && ok "README in a code repo → NOT flagged (sensor stays narrow)" \
  || no "README should not trip the orphan sensor (entries=$n)"

mkdir -p "$ORPH/src"; echo x > "$ORPH/src/note.md"
pl="$(jq -c --arg f "$ORPH/src/note.md" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
n="$(wc -l < "$OF_PE" | tr -d ' ')"
[ "$n" = "1" ] && ok "stray .md outside docs/ → NOT flagged" || no "stray .md tripped it (entries=$n)"

out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/malformed.json")" "$HOOKS/post-edit.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "malformed payload → silent, exit 0" || no "malformed should be silent (out:$out rc:$rc)"

echo "── post-publish.sh — Mechanism A (publish-tracking) ─────────"
# #5: the nudge asks the agent to run `basalt publish <file>`; the agent does exactly
# that mid-turn; stop.sh was the only writer that ever cleared the list, so the nudge
# could not be satisfied except by not editing. post-publish.sh is edit-tracking's twin.
BP="$FIX/posttooluse-bash-publish.json"
sid_bp="$(jq -r .session_id "$BP")"
DF_BP="$DDIR/dirty-$sid_bp.list"

bash_pl() {   # bash_pl <command> [cwd]
  if [ $# -ge 2 ]; then jq -c --arg c "$1" --arg w "$2" '.tool_input.command=$c | .cwd=$w' "$BP"
  else jq -c --arg c "$1" '.tool_input.command=$c' "$BP"; fi
}
publish_run() { PATH="$PATH_WITH_STUB" run "$(bash_pl "$@")" "$HOOKS/post-publish.sh"; }

# Two vaults sharing `ship-log/<date>.md` — a single-vault test passes identically under
# an exact matcher and a suffix matcher and therefore proves nothing (spec §f).
VA="$WORK/vaults/vault-a"; VB="$WORK/vaults/vault-b"
mkdir -p "$VA/ship-log" "$VB/ship-log"
printf 'name: a\npublish: prompt\n' > "$VA/vault.yaml"
printf 'name: b\npublish: prompt\n' > "$VB/vault.yaml"
DOC_A="$VA/ship-log/2026-08-17.md"; DOC_B="$VB/ship-log/2026-08-17.md"
echo x > "$DOC_A"; echo x > "$DOC_B"

seed() { reset_dirty; mkdir -p "$DDIR"; printf '%s\n' "$@" > "$DF_BP"; }
expect_live() {   # expect_live <label> <expected-n> [expected-entry …]
  local label="$1" want="$2"; shift 2
  local got; got="$(live_n "$DF_BP")"
  if [ "$got" != "$want" ]; then no "$label (live=$got want=$want :: $(live_set "$DF_BP" | tr '\n' ' '))"; return; fi
  local e
  for e in "$@"; do
    if ! live_set "$DF_BP" | grep -Fxq "$e"; then no "$label (missing live entry $e)"; return; fi
  done
  ok "$label"
}

# (c) the #5 arm, both halves.
seed "$DOC_A"
publish_run "basalt publish ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "(c) publish mid-turn → the doc is no longer live" 0
pl="$(jq -c --arg f "$DOC_A" '.tool_input.file_path=$f' "$FIX/posttooluse-edit.json")"
PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null
expect_live "(c) …then edit it again → it is live again (the half append_once broke)" 1 "$DOC_A"

# (f) the two-vault pair. Resolved base + no exact match ⇒ clear NOTHING — suffix
# matching would clear vault-a's entry from a vault-b publish: confident of the WRONG
# answer, strictly worse than the ambiguity the design already guards against.
seed "$DOC_A"
publish_run "cd $VB && basalt publish ship-log/2026-08-17.md" "$WORK" >/dev/null
expect_live "(f) publish from vault-b does NOT clear vault-a's identically-named entry" 1 "$DOC_A"
publish_run "cd $VA && basalt publish ship-log/2026-08-17.md" "$WORK" >/dev/null
expect_live "(f) publish from vault-a DOES clear it (the pair, not one half)" 0

# A1 — exit 0 is a property of the COMMAND, not of a segment.
seed "$DOC_A"
publish_run "basalt publish ship-log/2026-08-17.md || true" "$VA" >/dev/null
expect_live "A1: \`basalt publish f || true\` clears NOTHING (the publish may have failed)" 1 "$DOC_A"

seed "$DOC_A"
publish_run "cd $VA; basalt publish ship-log/2026-08-17.md; echo done" "$WORK" >/dev/null
expect_live "A1: a non-final \`;\` segment clears NOTHING" 1 "$DOC_A"

seed "$DOC_A" "$DOC_B"
publish_run "basalt publish $DOC_A; basalt publish $DOC_B" "$WORK" >/dev/null
expect_live "A1: \`publish a; publish b\` clears ONLY b (the last segment)" 1 "$DOC_A"

seed "$DOC_A" "$DOC_B"
publish_run "basalt publish $DOC_A && basalt publish $DOC_B" "$WORK" >/dev/null
expect_live "A1: \`publish a && publish b\` clears BOTH" 0

seed "$DOC_A"
publish_run "cd $VA && basalt publish ship-log/2026-08-17.md" "$WORK" >/dev/null
expect_live "A1: \`cd v && basalt publish f\` clears f (base = the cd, not the payload cwd)" 0

seed "$DOC_A"
publish_run "basalt publish ship-log/2026-08-17.md | tee out.log" "$VA" >/dev/null
expect_live "A1: a segment followed by \`|\` is untrusted → clears nothing" 1 "$DOC_A"

seed "$DOC_A"
publish_run "basalt publish ship-log/2026-08-17.md & wait" "$VA" >/dev/null
expect_live "A1: a bare \`&\` anywhere → the whole command clears nothing" 1 "$DOC_A"

# (e) A1b — the metacharacter precondition. Quote-blind splitting MANUFACTURES a segment
# whose first token is `basalt`, which defeats A3's token test. No newline required.
seed "$DOC_A"
publish_run 'gh issue comment 5 --body "checked; basalt publish ship-log/2026-08-17.md and done"' "$VA" >/dev/null
expect_live "(e) A1b: a quoted \`;\` cannot manufacture a publish segment" 1 "$DOC_A"

seed "$DOC_A"
publish_run 'basalt publish "ship-log/2026-08-17.md"' "$VA" >/dev/null
expect_live "(e) A1b: a quoted operand clears nothing (declared cost, fails toward the nag)" 1 "$DOC_A"

# A3 — operand parsing.
seed "$DOC_A"
publish_run "basalt publish --dry-run ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "A3: --dry-run exits 0 and fires the hook, but clears NOTHING" 1 "$DOC_A"

seed "$DOC_A"
publish_run "echo basalt publish ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "A3: \`echo basalt publish f\` — first token is not basalt → clears nothing" 1 "$DOC_A"

seed "$DOC_A"
publish_run "basalt publish ./ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "A3: a leading ./ is stripped before matching" 0

seed "$DOC_A"
publish_run "basalt publish --project myproj --tenant myws ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "A3: value-taking flags are skipped WITH their values" 0

seed "$DOC_A"
publish_run "/opt/tools/basalt publish ship-log/2026-08-17.md" "$VA" >/dev/null
expect_live "A3: a \`*/basalt\` path invocation is a publish too" 0

seed "$DOC_A"
publish_run "basalt publish ship-log/" "$VA" >/dev/null
expect_live "A3: an operand ending in / is a directory → matches nothing" 1 "$DOC_A"

seed "$DOC_A"
publish_run "basalt publish ship-log" "$VA" >/dev/null
expect_live "A3: an operand that IS a directory → matches nothing" 1 "$DOC_A"

seed "$DOC_A"
publish_run 'basalt publish $F' "$VA" >/dev/null
expect_live "F4: an unresolvable operand (\$F) matches nothing → the nag survives" 1 "$DOC_A"

# F3/base: `cwd` does not follow a compound `cd`, but an UNRESOLVABLE base falls back to
# suffix matching — and there the exactly-one rule is what keeps it honest.
seed "$DOC_A"
publish_run "basalt publish ship-log/2026-08-17.md" "$WORK/no-such-dir" >/dev/null
expect_live "unresolvable base + exactly ONE suffix match → cleared" 0

seed "$DOC_A" "$DOC_B"
publish_run "basalt publish ship-log/2026-08-17.md" "$WORK/no-such-dir" >/dev/null
expect_live "unresolvable base + TWO suffix matches → ambiguous, drop NONE" 2 "$DOC_A" "$DOC_B"

# A5 — the one free payload-checkable guard.
seed "$DOC_A"
PATH="$PATH_WITH_STUB" run "$(bash_pl "basalt publish ship-log/2026-08-17.md" "$VA" | jq -c '.tool_response.interrupted=true')" "$HOOKS/post-publish.sh" >/dev/null
expect_live "A5: tool_response.interrupted → clears nothing" 1 "$DOC_A"

# A8 — this hook fires on EVERY Bash call. A command with no `basalt` must not even
# touch the journal. NEVER substring-match the raw payload: `cwd` and `transcript_path`
# contain "basalt" in this very repo.
seed "$DOC_A"
before="$(cat "$DF_BP")"
out="$(publish_run "ls -la" "$VA")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ] && [ "$before" = "$(cat "$DF_BP")" ]; } \
  && ok "A8 negative control: a non-basalt command leaves the journal byte-identical" \
  || no "A8 negative control: journal changed or hook spoke (out:$out rc:$rc)"

seed "$DOC_A"
before="$(cat "$DF_BP")"
publish_run "grep -r TODO /opt/notes/basalt-archive" "$WORK" >/dev/null
[ "$before" = "$(cat "$DF_BP")" ] \
  && ok "A8: 'basalt' inside an unrelated command path clears nothing" \
  || no "A8: an unrelated path containing 'basalt' cleared something"

out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/malformed.json")" "$HOOKS/post-publish.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "malformed payload → silent, exit 0" || no "post-publish malformed should be silent (out:$out rc:$rc)"

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

# A journal that replays to an EMPTY live set is silent — the tombstone path end to end.
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/vt" prompt)"
printf '%s\n-%s\n' "$D" "$D" > "$DF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
[ -z "$out" ] && ok "journal replaying to an empty live set → silent" || no "tombstoned doc should be silent (got: $out)"

# --- orphan sensor at Stop -------------------------------------------------------------
OF_STOP="$DDIR/orphan-$sid_stop.list"

reset_dirty; mkdir -p "$DDIR"; printf '%s\n' "$WORK/myrepo" > "$OF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
printf '%s' "$out" | jq -e '.decision=="block" and (.reason|test("no vault.yaml"))' >/dev/null 2>&1 \
  && ok "orphan repo + CLI → block nudge naming the silent failure" || no "orphan should nudge (got: $out)"
r="$(printf '%s' "$out" | jq -r .reason)"
[ "${#r}" -le 200 ] && ok "budget: orphan reason ${#r}B ≤ 200B" || no "orphan reason too long (${#r}B)"
[ ! -f "$OF_STOP" ] && ok "orphan list cleared after speaking → no re-nag" || no "orphan list should clear"

# No CLI → the user is not publishing from here; the warning would be noise.
reset_dirty; mkdir -p "$DDIR"; printf '%s\n' "$WORK/myrepo" > "$OF_STOP"
out="$(PATH="$PATH_NO_BASALT" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
[ -z "$out" ] && ok "orphan + no CLI → SILENT (not a Basalt user, not their problem)" \
  || no "orphan without CLI should stay silent (got: $out)"

# A real dirty doc outranks the orphan hint: a pending publish beats a setup warning.
reset_dirty; mkdir -p "$DDIR"; D="$(mk_vault "$WORK/vorph" prompt)"
printf '%s\n' "$D" > "$DF_STOP"; printf '%s\n' "$WORK/myrepo" > "$OF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh")"
printf '%s' "$out" | jq -e '.reason|test("unpublished")' >/dev/null 2>&1 \
  && ok "dirty doc outranks orphan hint (one message, the actionable one)" || no "dirty should win (got: $out)"

# Loop guard must cover the orphan path too, or Stop nags forever.
reset_dirty; mkdir -p "$DDIR"; printf '%s\n' "$WORK/myrepo" > "$OF_STOP"
out="$(PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-active-guard.json")" "$HOOKS/stop.sh")"; rc=$?
{ [ -z "$out" ] && [ $rc -eq 0 ]; } && ok "orphan + stop_hook_active → silent (loop guard holds)" \
  || no "orphan must respect the loop guard (out:$out rc:$rc)"

echo "── stop.sh — Mechanism B (the #4 repo-backed-vault case) ────"
# The mandated flow for a repo-backed vault is commit + push → the repo's Action
# publishes. Nothing local ever cleared the list, so the nag was UNCONDITIONAL.
#
# Every fixture below is SYNTHETIC — invented repo and vault names, expressing the two
# workflow SHAPES. The repo whose real workflow motivated the customized shape is
# private and must never be pasted into a public fixture.

WF_CANON='name: publish-docs
on:
  push:
    branches: [main]
    paths: ['"'"'**.md'"'"']
  pull_request:
    paths: ['"'"'**.md'"'"']
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: git ls-files | xargs basalt publish
'
WF_CUSTOM='name: publish-docs
on:
  push:
    branches: [main]
    paths: ['"'"'**.md'"'"', '"'"'**.mdx'"'"']
  pull_request:
    paths: ['"'"'**.md'"'"', '"'"'**.mdx'"'"']
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: basalt publish
'
WF_BLOCK='name: publish-docs
on:
  push:
    branches:
      - main
    paths:
      - '"'"'**.md'"'"'
      - '"'"'**.mdx'"'"'
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - run: basalt publish
'
WF_IGNORE='name: publish-docs
on:
  push:
    branches: [main]
    paths-ignore: ['"'"'drafts/**'"'"']
jobs:
  publish:
    steps:
      - run: basalt publish
'
WF_NEGATED='name: publish-docs
on:
  push:
    branches: [main]
    paths: ['"'"'**.md'"'"', '"'"'!drafts/**'"'"']
jobs:
  publish:
    steps:
      - run: basalt publish
'
WF_NOPUSH='name: publish-docs
on:
  workflow_dispatch:
  schedule:
    - cron: '"'"'0 3 * * *'"'"'
jobs:
  publish:
    steps:
      - run: basalt publish
'
WF_OTHERBRANCH='name: publish-docs
on:
  push:
    branches: [production]
    paths: ['"'"'**.md'"'"']
jobs:
  publish:
    steps:
      - run: basalt publish
'
WF_NOBASALT='name: lint
on:
  push:
    branches: [main]
jobs:
  lint:
    steps:
      - run: make lint
'
# A push: trigger with NO branches: list — the shape that ISOLATES condition (4) from
# condition (6). Under the canonical shape, `branches: [main]` makes (6) keep the nag on
# a feature branch all by itself, so (4) looks redundant and a mutation of it survives.
# It is not redundant: with no branches: list, (6) passes by absence and (4) is the only
# thing standing between a feature-branch push and silence. (This is also why (4) has no
# "branches: absent" disjunct — a permissive default keyed on the ABSENCE of a token
# fails open.)
WF_NOBRANCHES='name: publish-docs
on:
  push:
    paths: ['"'"'**.md'"'"']
jobs:
  publish:
    steps:
      - run: basalt publish
'

# mk_repo <name> [workflow-content] [tracked|untracked|unpushed]
# Builds a REAL bare remote and a clone-shaped working repo. THE ENVIRONMENT TRAP:
# `origin/HEAD` is set by `git clone`, NOT by init + remote add + fetch — so condition
# (4) would fail for an environment reason whose easiest "fix" is loosening the
# default-branch check, which is this gate's own failure mode one level up. It is set
# EXPLICITLY here, and asserted below before arm (a)'s verdict is read.
mk_repo() {
  local name="$1" wfc="${2:-}" mode="${3:-tracked}"
  local bare="$WORK/remotes/$name.git" d="$WORK/repos/$name"
  mkdir -p "$WORK/remotes" "$WORK/repos" "$d"
  git init -q --bare "$bare" >/dev/null 2>&1
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name test
  git -C "$d" config commit.gpgsign false
  git -C "$d" remote add origin "$bare"
  mkdir -p "$d/docs"
  printf 'name: %s\npublish: prompt\n' "$name" > "$d/vault.yaml"
  printf 'seed\n' > "$d/README.md"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm seed >/dev/null 2>&1
  git -C "$d" push -q -u origin main >/dev/null 2>&1
  git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  if [ -n "$wfc" ]; then
    mkdir -p "$d/.github/workflows"
    printf '%s' "$wfc" > "$d/.github/workflows/publish-to-basalt.yml"
    if [ "$mode" != "untracked" ]; then
      git -C "$d" add -A .github >/dev/null 2>&1
      git -C "$d" commit -qm workflow >/dev/null 2>&1
      [ "$mode" = "unpushed" ] || git -C "$d" push -q origin main >/dev/null 2>&1
    fi
  fi
  printf '%s' "$d"
}

# add_doc <repo> <rel> [commit|push|dirty]  -> prints the absolute doc path
add_doc() {
  local d="$1" rel="$2" mode="${3:-push}"
  mkdir -p "$(dirname "$d/$rel")"
  printf 'body\n' > "$d/$rel"
  case "$mode" in
    dirty) : ;;                                    # written, never committed
    *)
      git -C "$d" add -- "$rel" >/dev/null 2>&1
      git -C "$d" commit -qm "doc $rel" >/dev/null 2>&1
      [ "$mode" = "commit" ] || git -C "$d" push -q origin HEAD >/dev/null 2>&1 ;;
  esac
  printf '%s' "$d/$rel"
}

seed_stop() { reset_dirty; mkdir -p "$DDIR"; printf '%s\n' "$@" > "$DF_STOP"; }
stop_out() { PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh"; }
expect_silent() { local o; o="$(stop_out)"; [ -z "$o" ] && ok "$1" || no "$1 — expected SILENT, got: $o"; }
expect_nag() {
  local o; o="$(stop_out)"
  printf '%s' "$o" | jq -e '.decision=="block" and (.reason|test("unpublished"))' >/dev/null 2>&1 \
    && ok "$1" || no "$1 — expected a NAG, got: ${o:-<silence>}"
}

R_CANON="$(mk_repo canonvault "$WF_CANON")"

# PROVE THE FIXTURE before reading arm (a)'s verdict.
oh="$(git -C "$R_CANON" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
cb="$(git -C "$R_CANON" symbolic-ref --short -q HEAD 2>/dev/null || true)"
up="$(git -C "$R_CANON" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
{ [ "$oh" = "origin/main" ] && [ "$cb" = "main" ] && [ "$up" = "origin/main" ]; } \
  && ok "fixture state: origin/HEAD=origin/main · branch=main · upstream=origin/main" \
  || no "fixture state wrong (origin/HEAD='$oh' branch='$cb' upstream='$up') — arm (a) verdicts below are meaningless"

# (a) THE POSITIVE ARM, and the discriminating cell right next to it. A single canonical
# fixture passes equally against a hardcoded `.md` check — the rule the gate DELETED —
# so it cannot discriminate. The pair can.
D_MD="$(add_doc "$R_CANON" docs/note.md push)"
seed_stop "$D_MD"
expect_silent "(a) canonical shape paths:['**.md'] + .md doc, committed+pushed on default branch → SILENT"

D_MDX="$(add_doc "$R_CANON" docs/note.mdx push)"
seed_stop "$D_MDX"
expect_nag "(a) DISCRIMINATING CELL: same workflow, .mdx doc → STILL NAGS (its paths list does not match)"

R_CUSTOM="$(mk_repo customvault "$WF_CUSTOM")"
D2_MD="$(add_doc "$R_CUSTOM" docs/note.md push)"
seed_stop "$D2_MD"
expect_silent "(a) customized shape paths:['**.md','**.mdx'] + .md doc → SILENT"
D2_MDX="$(add_doc "$R_CUSTOM" docs/note.mdx push)"
seed_stop "$D2_MDX"
expect_silent "(a) customized shape + .mdx doc → SILENT (derived by EVALUATING the list, not hardcoding .md)"

R_BLOCK="$(mk_repo blockvault "$WF_BLOCK")"
D3="$(add_doc "$R_BLOCK" docs/note.mdx push)"
seed_stop "$D3"
expect_silent "(a) block-sequence list form (paths:\\n  - '**.md'\\n  - '**.mdx') is read too"

# (b) THE NEGATIVE ARM — the one that gets skipped. A fix that silences the hook in all
# three arms has deleted the feature instead of repairing it.
D_DIRTY="$(add_doc "$R_CANON" docs/uncommitted.md dirty)"
seed_stop "$D_DIRTY"
expect_nag "(b) edited, NOT committed → nags exactly as today (condition 2, subject: the DOC)"

R_NOPUSHDOC="$(mk_repo nopushdocvault "$WF_CANON")"
D_COMMITTED="$(add_doc "$R_NOPUSHDOC" docs/note.md commit)"
seed_stop "$D_COMMITTED"
expect_nag "(b) committed but NOT pushed → still nags (the Action runs on push; committed is not published)"

# B3 — the branch gate. `branches: [main]` ships in the canonical template, so this is
# the mainline shape, not an edge case. This very sprint runs on a feature branch.
R_FEAT="$(mk_repo featurevault "$WF_CANON")"
git -C "$R_FEAT" checkout -q -b feature/x
D_FEAT="$(add_doc "$R_FEAT" docs/note.md commit)"
git -C "$R_FEAT" push -q -u origin feature/x >/dev/null 2>&1
seed_stop "$D_FEAT"
expect_nag "B3: pushed to a NON-DEFAULT branch → still nags (condition 4, no disjunct)"

# The pair that makes condition (4) load-bearing rather than shadowed by (6): the same
# no-branches workflow, once on the default branch and once not.
R_NB="$(mk_repo nobranchvault "$WF_NOBRANCHES")"
seed_stop "$(add_doc "$R_NB" docs/note.md push)"
expect_silent "(4) push: with NO branches: list, on the default branch → SILENT (absent list passes)"
R_NB2="$(mk_repo nobranchfeatvault "$WF_NOBRANCHES")"
git -C "$R_NB2" checkout -q -b feature/y
D_NB2="$(add_doc "$R_NB2" docs/note.md commit)"
git -C "$R_NB2" push -q -u origin feature/y >/dev/null 2>&1
seed_stop "$D_NB2"
expect_nag "(4) same workflow, NON-default branch → nags — (6) passes by absence, only (4) holds"

# Conditions (5)–(8) negatives.
R_IGN="$(mk_repo ignorevault "$WF_IGNORE")"
seed_stop "$(add_doc "$R_IGN" docs/note.md push)"
expect_nag "(8) paths-ignore: present → nags (negation is not modelled)"

R_NEG="$(mk_repo negatedvault "$WF_NEGATED")"
seed_stop "$(add_doc "$R_NEG" docs/note.md push)"
expect_nag "(8) a '!'-negated pattern → nags (it INVERTS; guessing its direction yields silence)"

R_NOPUSH="$(mk_repo nopushvault "$WF_NOPUSH")"
seed_stop "$(add_doc "$R_NOPUSH" docs/note.md push)"
expect_nag "(5) no push: trigger (workflow_dispatch/schedule only) → nags"

R_OTHER="$(mk_repo otherbranchvault "$WF_OTHERBRANCH")"
seed_stop "$(add_doc "$R_OTHER" docs/note.md push)"
expect_nag "(6) branches:[production] while ON the default branch → nags"

R_NOBAS="$(mk_repo nobasaltvault "$WF_NOBASALT")"
seed_stop "$(add_doc "$R_NOBAS" docs/note.md push)"
expect_nag "(1) the repo's only workflow never mentions basalt → nags"

R_NOWF="$(mk_repo nowfvault "")"
seed_stop "$(add_doc "$R_NOWF" docs/note.md push)"
expect_nag "(1) repo has NO publish workflow at all → nags"

# --- Condition (0) — the subject is the WORKFLOW, not the doc -------------------------
# (2) and (3) test the DOC; (0) tests the CANDIDATE WORKFLOW FILE. Read as "the same two
# git calls" without the subject, the next reader points them back at the doc and reopens
# the hole: `basalt onboard` writes an UNTRACKED workflow, the agent does what the nudge
# says and stages only the doc, every other condition passes — and origin/main has no
# Action at all. Mechanism B would convert a TRUE POSITIVE into silence, precisely during
# first-run misconfiguration, the moment the sensor exists for.
R_UNTRACKED="$(mk_repo untrackedwfvault "$WF_CANON" untracked)"
D_U="$(add_doc "$R_UNTRACKED" docs/note.md push)"
# Prove the fixture BITES for the intended reason before reading its verdict.
if [ -f "$R_UNTRACKED/.github/workflows/publish-to-basalt.yml" ] \
   && ! git -C "$R_UNTRACKED" ls-files --error-unmatch -- .github/workflows/publish-to-basalt.yml >/dev/null 2>&1 \
   && git -C "$R_UNTRACKED" ls-files --error-unmatch -- docs/note.md >/dev/null 2>&1; then
  ok "fixture state: WORKFLOW on disk but UNTRACKED, DOC tracked+pushed (the basalt-onboard shape)"
else
  no "fixture state: untracked-workflow repo is not in the intended state"
fi
seed_stop "$D_U"
expect_nag "(0) WORKFLOW untracked (doc committed+pushed) → nags — the refute-pass case"

R_WFUNPUSHED="$(mk_repo unpushedwfvault "$WF_CANON" unpushed)"
seed_stop "$(add_doc "$R_WFUNPUSHED" docs/note.md commit)"
expect_nag "(0) WORKFLOW committed but NOT pushed → nags (the Action on the remote is not this file)"

# The durable variant, and it INVERTS the discriminating cell above: the workflow was
# pushed with paths:['**.md'] and hand-edited locally to add '**.mdx'. Reading the local
# file says "silent"; the Action that actually runs says "never publishes .mdx".
R_WFDIRTY="$(mk_repo dirtywfvault "$WF_CANON")"
printf '%s' "$WF_CUSTOM" > "$R_WFDIRTY/.github/workflows/publish-to-basalt.yml"
D_WD="$(add_doc "$R_WFDIRTY" docs/note.mdx push)"
if [ -n "$(git -C "$R_WFDIRTY" status --porcelain -- .github/workflows/publish-to-basalt.yml)" ]; then
  ok "fixture state: WORKFLOW tracked+pushed but locally MODIFIED to add '**.mdx'"
else
  no "fixture state: dirty-workflow repo is not dirty"
fi
seed_stop "$D_WD"
expect_nag "(0) WORKFLOW locally modified → nags (the local file is not the Action that runs)"

# C2 — (5)–(8) are evaluated PER CANDIDATE; ONE qualifying candidate is enough. The other
# reading (ALL candidates must qualify) lets a single workflow_dispatch-only helper kill
# Mechanism B repo-wide, silently, with every test green.
R_TWO="$(mk_repo twowfvault "$WF_CANON")"
mkdir -p "$R_TWO/.github/workflows"
printf '%s' "$WF_NOPUSH" > "$R_TWO/.github/workflows/basalt-manual.yml"
git -C "$R_TWO" add -A .github >/dev/null 2>&1
git -C "$R_TWO" commit -qm "second workflow" >/dev/null 2>&1
git -C "$R_TWO" push -q origin main >/dev/null 2>&1
seed_stop "$(add_doc "$R_TWO" docs/note.md push)"
expect_silent "C2: a non-qualifying second candidate does not veto the qualifying one"

# --- end-to-end arms across both mechanisms ------------------------------------------
echo "── arms (c) + (d) end to end ────────────────────────────────"
E2E="$WORK/e2e"; mkdir -p "$E2E/docs"
printf 'name: e2e\npublish: prompt\n' > "$E2E/vault.yaml"
EA="$E2E/docs/a.md"; EB="$E2E/docs/b.md"; echo x > "$EA"; echo x > "$EB"
edit_run() { pl="$(jq -c --arg f "$1" '.tool_input.file_path=$f' "$FIX/posttooluse-edit.json")"; PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null; }
write_run() { pl="$(jq -c --arg f "$1" '.tool_input.file_path=$f' "$FIX/posttooluse-write.json")"; PATH="$PATH_WITH_STUB" run "$pl" "$HOOKS/post-edit.sh" >/dev/null; }
guard_run() { PATH="$PATH_WITH_STUB" run "$(cat "$FIX/stop-active-guard.json")" "$HOOKS/stop.sh"; }

reset_dirty; mkdir -p "$DDIR"
write_run "$EA"
publish_run "basalt publish docs/a.md" "$E2E" >/dev/null
out="$(stop_out)"
[ -z "$out" ] && ok "(c) e2e: Write then \`basalt publish\` in the SAME turn → Stop is SILENT" \
  || no "(c) e2e: expected silence, got: $out"

reset_dirty; mkdir -p "$DDIR"
write_run "$EA"
publish_run "basalt publish docs/a.md" "$E2E" >/dev/null
edit_run "$EA"
out="$(stop_out)"
printf '%s' "$out" | jq -e '.reason|test("1 vault doc")' >/dev/null 2>&1 \
  && ok "(c) e2e: …publish then edit AGAIN in the same turn → nags for exactly 1" \
  || no "(c) e2e: expected a nag for 1 doc, got: ${out:-<silence>}"

# (d) A7 — the sharpest single test for Mechanism A. The loop-guard Stop returns BEFORE
# the clear and PRESERVES the list, which is exactly how a false positive outlives its
# own turn: the agent publishes during the blocked turn, the guard preserves the entry,
# and the next real Stop nags for an already-published doc.
reset_dirty; mkdir -p "$DDIR"
write_run "$EA"                                     # turn 1: Write
out="$(stop_out)"                                   # Stop → block
printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "(d) step 1: Write → Stop blocks" || no "(d) step 1: expected a block, got: $out"
publish_run "basalt publish docs/a.md" "$E2E" >/dev/null   # blocked turn: publish
g="$(guard_run)"; grc=$?
{ [ -z "$g" ] && [ $grc -eq 0 ]; } && ok "(d) step 2: guard Stop is silent and preserves the list" \
  || no "(d) step 2: guard should be silent (out:$g rc:$grc)"
edit_run "$EB"                                      # next turn: edit a DIFFERENT file
out="$(stop_out)"
printf '%s' "$out" | jq -e '.reason|test("1 vault doc")' >/dev/null 2>&1 \
  && ok "(d) A7: Write→Stop→publish→guard→Edit other → nags for EXACTLY ONE doc" \
  || no "(d) A7: expected exactly 1, got: ${out:-<silence>}"

# The variant that actually bites: the blocked turn RE-EDITS the doc before publishing
# it, so the entry the guard preserves is a published one. Under the old list this nags
# for two docs; under the journal it nags for one.
reset_dirty; mkdir -p "$DDIR"
write_run "$EA"
stop_out >/dev/null                                        # Stop blocks + clears
edit_run "$EA"                                             # blocked turn: fix, then
publish_run "basalt publish docs/a.md" "$E2E" >/dev/null   #   publish
guard_run >/dev/null                                       # guard Stop PRESERVES [a, -a]
edit_run "$EB"
out="$(stop_out)"
printf '%s' "$out" | jq -e '.reason|test("1 vault doc")' >/dev/null 2>&1 \
  && ok "(d) A7 variant: an entry preserved ACROSS the guard is still cleared by its tombstone" \
  || no "(d) A7 variant: expected exactly 1, got: ${out:-<silence>}"

echo "── stop.sh — publish_overrides (#10, the per-PATH hole) ─────"
# The publish policy is per VAULT; the state that produces the nag is per DOC. For a doc
# the server REJECTS, the only lever was `publish: manual` — which silences every other
# doc in the vault too, leaving a nag that fires every session with nothing to do about it.
#
# So every arm here is a PAIR: the listed path that goes silent, and a path in the SAME
# session that must still nag. An implementation that silences both has deleted the
# feature rather than repaired it, and an implementation that silences neither has shipped
# a no-op; only the pair can tell those apart from a green run.

# mk_ovault <dir> <publish-policy> <overrides-block>  -> prints the vault dir
# Deliberately NOT a git repo: Mechanism B must not get to answer a question these arms
# are asking.
mk_ovault() {
  local d="$1" pol="$2" ov="$3"
  mkdir -p "$d/docs" "$d/notes"
  { printf 'name: ov\npublish: %s\n' "$pol"; [ -n "$ov" ] && printf '%s' "$ov"; } > "$d/vault.yaml"
  printf 'x\n' > "$d/BITACORA.mdx"; printf 'x\n' > "$d/README.mdx"
  printf 'x\n' > "$d/docs/context.mdx"; printf 'x\n' > "$d/notes/x.mdx"
  printf '%s' "$d"
}
stop_out_pub() { PATH="$PATH_WITH_STUB" BASALT_STUB_MODE=publish-ok run "$(cat "$FIX/stop-inactive.json")" "$HOOKS/stop.sh"; }
expect_nag_n() {   # expect_nag_n <label> <n> — the COUNT is the whole assertion here
  local o; o="$(stop_out)"
  printf '%s' "$o" | jq -e --arg n "$2" '.decision=="block" and (.reason|test("Basalt: "+$n+" vault doc"))' >/dev/null 2>&1 \
    && ok "$1" || no "$1 — expected a NAG for exactly $2, got: ${o:-<silence>}"
}

OV_MANUAL='publish_overrides:
  manual:
    - BITACORA.mdx                 # the server rejects it; delete this line when that lifts
'
OV_A="$(mk_ovault "$WORK/ov-a" prompt "$OV_MANUAL")"

seed_stop "$OV_A/BITACORA.mdx"
expect_silent "#10 (a) prompt vault, publish_overrides.manual lists BITACORA.mdx → SILENT"

seed_stop "$OV_A/BITACORA.mdx" "$OV_A/README.mdx"
expect_nag_n "#10 (b) PAIR OF (a) — the one that matters: +1 UNLISTED doc → nags for EXACTLY 1 (0 = the vault got silenced, 2 = the override did nothing)" 1

OV_C="$(mk_ovault "$WORK/ov-c" prompt "")"
seed_stop "$OV_C/BITACORA.mdx"
expect_nag_n "#10 (c) PAIR OF (a) — the same path with the override line REMOVED, nothing else changed → nags again" 1

# (d) no publish_overrides key at all ⇒ today's behavior, byte for byte, all three policies.
OV_DP="$(mk_ovault "$WORK/ov-d-prompt" prompt "")"
seed_stop "$OV_DP/docs/context.mdx"
expect_nag_n "#10 (d) no publish_overrides + publish: prompt → nags, exactly as today" 1

OV_DM="$(mk_ovault "$WORK/ov-d-manual" manual "")"
seed_stop "$OV_DM/docs/context.mdx"
expect_silent "#10 (d) no publish_overrides + publish: manual → silent, exactly as today"

OV_DA="$(mk_ovault "$WORK/ov-d-auto" auto "")"; : > "$BASALT_STUB_CALLS"
seed_stop "$OV_DA/docs/context.mdx"
out="$(stop_out_pub)"
{ printf '%s' "$out" | grep -qi 'auto-published' && grep -Fxq "$OV_DA/docs/context.mdx" "$BASALT_STUB_CALLS"; } \
  && ok "#10 (d) no publish_overrides + publish: auto → publishes, exactly as today" \
  || no "#10 (d) auto without overrides regressed (out:$out calls:$(cat "$BASALT_STUB_CALLS"))"

# (e) `auto` is an accepted key, so a listed path can newly REACH the bucket that shells
# out to `basalt publish` — a real network write. Its twin proves the reach is confined to
# the path someone actually typed.
OV_AUTOKEY='publish_overrides:
  auto:
    - docs/context.mdx             # safe to ship unattended
'
OV_E="$(mk_ovault "$WORK/ov-e" prompt "$OV_AUTOKEY")"; : > "$BASALT_STUB_CALLS"
seed_stop "$OV_E/docs/context.mdx"
out="$(stop_out_pub)"
{ printf '%s' "$out" | grep -qi 'auto-published' && grep -Fxq "$OV_E/docs/context.mdx" "$BASALT_STUB_CALLS"; } \
  && ok "#10 (e) publish_overrides.auto in a PROMPT vault → that path reaches the auto bucket" \
  || no "#10 (e) expected an auto publish (out:$out calls:$(cat "$BASALT_STUB_CALLS"))"

: > "$BASALT_STUB_CALLS"
seed_stop "$OV_E/README.mdx"
out="$(stop_out_pub)"
{ printf '%s' "$out" | jq -e '.reason|test("Basalt: 1 vault doc")' >/dev/null 2>&1 && [ ! -s "$BASALT_STUB_CALLS" ]; } \
  && ok "#10 (e) PAIR: an UNLISTED path in that same vault stays prompt — never auto-published" \
  || no "#10 (e) PAIR: unlisted path was auto-published or did not nag (out:$out calls:$(cat "$BASALT_STUB_CALLS"))"

# (f) Robustness. Each unsupported shape is paired with a well-formed entry in the SAME
# vault, so "exactly 1" separates "the shape was refused" from "the whole block died".
OV_GLOB='publish_overrides:
  manual:
    - '"'"'*.mdx'"'"'                     # a glob: UNSUPPORTED on purpose, matches nothing
    - README.mdx
'
OV_F1="$(mk_ovault "$WORK/ov-f-glob" prompt "$OV_GLOB")"
seed_stop "$OV_F1/BITACORA.mdx" "$OV_F1/README.mdx"
expect_nag_n "#10 (f) a glob entry silences NOTHING while the literal beside it works → exactly 1 (0 would mean one line silenced a subtree nobody enumerated)" 1

OV_BADKEY='publish_overrides:
  silent:
    - BITACORA.mdx
  manual:
    - README.mdx
'
OV_F2="$(mk_ovault "$WORK/ov-f-badkey" prompt "$OV_BADKEY")"
seed_stop "$OV_F2/BITACORA.mdx" "$OV_F2/README.mdx"
expect_nag_n "#10 (f) an unrecognized key is IGNORED (its doc keeps the vault policy) while a real key beside it works → exactly 1" 1

OV_FLOW='publish_overrides: {manual: [BITACORA.mdx, README.mdx]}
'
OV_F3="$(mk_ovault "$WORK/ov-f-flow" prompt "$OV_FLOW")"
seed_stop "$OV_F3/BITACORA.mdx" "$OV_F3/README.mdx"
expect_nag_n "#10 (f) PAIR OF (a): flow style is not parsed → BOTH keep the vault policy and nag" 2

# The suffix-matching trap post-publish.sh documents at length, in its two forms.
OV_SUFFIX='publish_overrides:
  manual:
    - notes/x.mdx
'
OV_F4A="$(mk_ovault "$WORK/ov-f-vault-a" prompt "$OV_SUFFIX")"
OV_F4B="$(mk_ovault "$WORK/ov-f-vault-b" prompt "")"
seed_stop "$OV_F4A/notes/x.mdx"
expect_silent "#10 (f) notes/x.mdx listed in ITS OWN vault → silent"
seed_stop "$OV_F4B/notes/x.mdx"
expect_nag_n "#10 (f) PAIR: the identically-named doc in a DIFFERENT vault → nags (paths resolve against THEIR vault root)" 1

OV_BASENAME='publish_overrides:
  manual:
    - x.mdx
    - notes/x.mdx
'
OV_F5="$(mk_ovault "$WORK/ov-f-basename" prompt "$OV_BASENAME")"
seed_stop "$OV_F5/notes/x.mdx"
expect_silent "#10 (f) the vault-root-relative entry notes/x.mdx matches → silent"
OV_F5B="$(mk_ovault "$WORK/ov-f-basename-only" prompt 'publish_overrides:
  manual:
    - x.mdx
')"
seed_stop "$OV_F5B/notes/x.mdx"
expect_nag_n "#10 (f) PAIR: the bare basename x.mdx does NOT match notes/x.mdx → nags (exact, never a suffix)" 1

OV_DOTSLASH='publish_overrides:
  manual:
    - ./docs/context.mdx           # a leading ./ normalizes away
'
OV_F6="$(mk_ovault "$WORK/ov-f-dotslash" prompt "$OV_DOTSLASH")"
seed_stop "$OV_F6/docs/context.mdx" "$OV_F6/README.mdx"
expect_nag_n "#10 (f) ./docs/context.mdx normalizes and silences it, the unlisted doc still nags → exactly 1" 1

# The block ends where the indentation returns to column 0 — a list under the NEXT
# top-level key must not be read as more overrides.
OV_TERM='publish_overrides:
  manual:
    - BITACORA.mdx
tags:
  - README.mdx
'
OV_F7="$(mk_ovault "$WORK/ov-f-terminate" prompt "$OV_TERM")"
seed_stop "$OV_F7/BITACORA.mdx" "$OV_F7/README.mdx"
expect_nag_n "#10 (f) the block ends at column 0 → a list under the NEXT key silences nothing, exactly 1" 1

echo "─────────────────────────────────────────────────────────────"
printf 'pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
