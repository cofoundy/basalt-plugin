#!/usr/bin/env bash
# post-publish.sh — PostToolUse(Bash) hook. Edit-tracking's twin: when a Bash command
# really published a vault doc, append a TOMBSTONE for it to this session's dirty
# journal, so Stop stops asking for a publish that already happened.
# ZERO network, ZERO output, always. No `basalt` invocation — this reads the command
# string the model already ran.
#
# THE BUG THIS CLOSES (#5): the nudge asks the agent to run `basalt publish <file>`, the
# agent does exactly that mid-turn, and `stop.sh` — the only writer that ever cleared the
# list — nags anyway. The nudge could not be satisfied except by not editing.
#
# WHY THIS CAN TRUST exit-0 AT ALL (recon F2, measured on 2.1.233 with a marker log as an
# independent instrument): PostToolUse fires ONLY when the Bash command exits 0 — 4
# executions, 2 fires, the two non-zero exits produced no payload at all. So a FAILED
# `basalt publish` never reaches this hook. There is no exit-code field in the payload
# (F1); this is how success is known without one, and without a network call.
#
# THE RESIDUAL RISK THAT BUYS (A5), stated rather than asserted away: if a future harness
# starts firing on non-zero exits, a failed publish clears the entry and the hook goes
# quiet on a genuinely unpublished doc — the feature's one true positive, deleted, with
# no error. The suite cannot pin this (it feeds fixtures to the hook, never the harness's
# firing policy, and F1 gives no exit code to synthesize a "failed publish" from).
# `tests/probe-harness.sh` re-measures F2 against the installed harness; run it when the
# supported version moves.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

payload="$(cat)"

# --- A8: this fires on EVERY Bash call, so bail cheap and bail early ------------------
# Read the command, `case` it for `basalt`, and exit before touching the dirty dir.
# NEVER substring-match the raw payload: `cwd` and `transcript_path` contain "basalt" in
# this very repo, which would make the matcher fire on every command in it.
cmd="$(json_get "$payload" "tool_input.command")"
[ -n "$cmd" ] || exit 0
case "$cmd" in *basalt*) ;; *) exit 0 ;; esac

# --- A1b: metacharacter precondition -------------------------------------------------
# A command containing a quote, a backslash or a newline clears NOTHING.
#
# The vulnerability is not newlines — it is that quote-blind splitting MANUFACTURES a
# segment whose first token is `basalt`, which defeats the token test below. A `;` inside
# a quoted string does it with no newline at all:
#
#   gh issue comment 5 --body "checked; basalt publish ship-log/x.md and done"
#      split on ';' → [basalt] [publish] [ship-log/x.md] [and] [done"]
#      the token test PASSES, the operand is clean  →  it clears
#
# What this costs, all failing toward the nag: quoted paths, quoted flag values,
# `cd "/p with spaces"`. Mainline publishing is unquoted and untouched.
case "$cmd" in
  *\'*|*\"*|*\\*) exit 0 ;;
esac
case "$cmd" in
  *$'\n'*) exit 0 ;;
esac

# --- the one free payload-checkable guard (A5) ---------------------------------------
[ "$(json_get "$payload" "tool_response.interrupted")" = "true" ] && exit 0

sid="$(json_get "$payload" "session_id")"
[ -n "$sid" ] || sid="nosession"
df="$(dirty_file "$sid")"
[ -f "$df" ] || exit 0                    # nothing tracked this turn → nothing to clear

cwd="$(json_get "$payload" "cwd")"

# --- split the command into segments + the separators between them -------------------
# Character scan, not a regex (recon F6: ugrep and GNU grep disagree on `[^\n]` inside a
# bracket, so a regex path parser behaves one way locally and another in CI).
SEG=(); SEP=()
split_command() {
  local s="$1" cur=""
  while [ -n "$s" ]; do
    case "$s" in
      '&&'*) SEG+=("$cur"); SEP+=("&&"); cur=""; s="${s:2}" ;;
      '||'*) SEG+=("$cur"); SEP+=("||"); cur=""; s="${s:2}" ;;
      '&'*)  SEG+=("$cur"); SEP+=("&");  cur=""; s="${s:1}" ;;
      '|'*)  SEG+=("$cur"); SEP+=("|");  cur=""; s="${s:1}" ;;
      ';'*)  SEG+=("$cur"); SEP+=(";");  cur=""; s="${s:1}" ;;
      *)     cur="$cur${s:0:1}"; s="${s:1}" ;;
    esac
  done
  SEG+=("$cur"); SEP+=("end")
}
split_command "$cmd"

# --- A1: exit 0 is a property of the COMMAND, not of a segment -----------------------
# The harness fires only on exit 0 (F2). That says the COMMAND succeeded. After splitting
# a compound command, only `&&` carries that implication down to a segment:
#
#   A segment may clear anything only when it is the LAST segment, or every separator
#   between it and the last segment is `&&`. A segment followed — before the end — by
#   `;`, `||`, `|`, `&` or a newline is UNTRUSTED and clears nothing.
#
# Without this, `basalt publish a.md || true` exits 0 with a FAILED publish, fires the
# hook, and clears the entry. So does `cd v; basalt publish a.md; echo done`.
seg_trusted() {
  local i="$1" j n=${#SEP[@]}
  for ((j = i; j < n - 1; j++)); do
    [ "${SEP[j]}" = "&&" ] || return 1
  done
  return 0
}

# A command containing a bare `&` anywhere clears nothing — backgrounding decouples the
# segment's fate from the command's exit code entirely.
for ((k = 0; k < ${#SEP[@]}; k++)); do
  [ "${SEP[k]}" = "&" ] && exit 0
done

# --- A3: is this segment a publish, and what are its operands? -----------------------
OPERANDS=()
parse_publish_segment() {
  local seg="$1" t i n j skipnext=0
  local -a toks=()
  OPERANDS=()
  IFS=$' \t' read -r -a toks <<< "$seg"
  n=${#toks[@]}; i=0
  while [ "$i" -lt "$n" ]; do            # skip leading VAR=value assignments
    case "${toks[i]}" in [A-Za-z_]*=*) i=$((i + 1)) ;; *) break ;; esac
  done
  # the first non-assignment token must be `basalt` (or `*/basalt`) and the second
  # `publish`. So `echo basalt publish x` and a commit message clear nothing.
  [ "$i" -lt "$n" ] || return 1
  case "${toks[i]}" in basalt|*/basalt) ;; *) return 1 ;; esac
  i=$((i + 1))
  [ "$i" -lt "$n" ] || return 1
  [ "${toks[i]}" = "publish" ] || return 1
  i=$((i + 1))
  # `--dry-run` exits 0 and fires the hook while publishing NOTHING — exactly the trap F2
  # creates: exit 0 means "the command succeeded", not "a publish happened".
  for ((j = 0; j < n; j++)); do
    [ "${toks[j]}" = "--dry-run" ] && return 1
  done
  while [ "$i" -lt "$n" ]; do
    t="${toks[i]}"
    if [ "$skipnext" -eq 1 ]; then skipnext=0; i=$((i + 1)); continue; fi
    case "$t" in
      --project|--tenant) skipnext=1 ;;    # value-taking flags: skip the value too
      -*) : ;;                             # any other flag
      *) OPERANDS+=("$t") ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# seg_cd_dir <segment> -> exit 0 when the segment IS a `cd`, printing its target
seg_cd_dir() {
  local seg="$1" i n
  local -a toks=()
  IFS=$' \t' read -r -a toks <<< "$seg"
  n=${#toks[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[i]}" in [A-Za-z_]*=*) i=$((i + 1)) ;; *) break ;; esac
  done
  [ "$i" -lt "$n" ] || return 1
  [ "${toks[i]}" = "cd" ] || return 1
  i=$((i + 1))
  [ "$i" -lt "$n" ] && printf '%s' "${toks[i]}"
  return 0
}

# --- base resolution: resolve when a base exists, SUFFIX only when none does ---------
# Recon F3: the payload's `cwd` does NOT follow a compound `cd` (measured — the command
# really ran in /tmp, the payload still reported the session dir). But `cwd` fails ONLY
# when a `cd` is present, and in that case the `cd` is right there in the command.
# Disjoint cases, correct instrument for each:
#   1. base = the last `cd <dir>` before the publish segment, else the payload's `cwd`
#   2. resolve the operand against that base → an EXACT match at replay
#   3. resolved base + no exact match ⇒ clear NOTHING. No suffix fallback here.
#
# Why: suffix matching clears the WRONG file across two vaults sharing a basename —
#   live: …/vault-a/ship-log/2026-08-17.md   (edited, never published)
#   cmd:  cd …/vault-b && basalt publish ship-log/2026-08-17.md
# The exactly-one guard does not fire, because there genuinely IS exactly one match: the
# system is confident of the wrong answer, strictly worse than the ambiguity it guards.
# Suffix matching is the fallback for an UNRESOLVABLE base only, and there it keeps the
# exactly-one-live-entry rule (applied at replay).
base="$cwd"
n_seg=${#SEG[@]}
for ((k = 0; k < n_seg; k++)); do
  if dir="$(seg_cd_dir "${SEG[k]}")"; then
    case "$dir" in
      '')     base="" ;;                            # bare `cd` → $HOME, not knowable here
      -|'~'*) base="" ;;
      /*)     base="$dir" ;;
      *)      if [ -n "$base" ]; then base="$base/$dir"; else base=""; fi ;;
    esac
  fi
  parse_publish_segment "${SEG[k]}" || continue
  seg_trusted "$k" || continue
  rbase=""
  [ -n "$base" ] && rbase="$(cd "$base" 2>/dev/null && pwd -P)"
  for ((m = 0; m < ${#OPERANDS[@]}; m++)); do
    op="${OPERANDS[m]}"
    op="${op#./}"                                   # `basalt publish ./ship-log/x.md`
    case "$op" in ''|*/) continue ;; esac           # a trailing `/` is a directory
    case "$op" in
      /*) target="$op" ;;
      *)  if [ -n "$rbase" ]; then target="$rbase/$op"; else target="$op"; fi ;;
    esac
    case "$target" in /*) [ -d "$target" ] && continue ;; esac
    printf -- '-%s\n' "$target" >> "$df"            # O_APPEND only (A2)
  done
done
exit 0
