#!/usr/bin/env bash
# lib.sh — shared helpers for the Basalt session-boundary hooks.
#
# WORLD-READABLE PLUGIN (ADR-0001): zero secrets, zero Cofoundy content. These hooks
# only invoke the user's own `basalt` CLI with the user's own credentials.
#
# Payload shapes are the REAL ones captured 2026-07-24 (see hooks/tests/fixtures/ and
# the plugin capability notes). Load-bearing facts baked in here:
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

# --- orphan-list: docs edited with NO vault.yaml above them ---------------------------
# Publishing from a repo with no vault.yaml is the ONE Basalt failure that does not
# announce itself: with no project binding the CLI takes the first path segment as the
# space name, so `docs/PRD.md` lands as project "docs" / slug "prd" instead of
# project "<repo>" / slug "docs/prd" — exit 0, no warning, wrong space. Every other
# error here is loud; this one needs a sensor. Same shape as the dirty-list: PostToolUse
# records, Stop speaks once (batching-at-close, never push-on-edit).
orphan_file() { printf '%s/orphan-%s.list' "$(dirty_dir)" "$1"; }  # $1 = session_id

# is_doc <path> -> 0 when the file reads as publishable prose, 1 otherwise.
# Deliberately narrow: `.mdx` anywhere (authoring it IS the intent to publish), `.md`
# only under a `docs/` directory. A README in a code repo must never trip this — a
# sensor that cries on every repo gets muted, and then it is worth less than nothing.
is_doc() {
  case "$1" in
    *.mdx) return 0 ;;
    */docs/*.md|*/docs/*/*.md|*/docs/*/*/*.md) return 0 ;;
    *) return 1 ;;
  esac
}

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

# =====================================================================================
# publish_overrides — a per-PATH policy that overrides the vault's (#10)
# =====================================================================================
# The publish policy is per VAULT; the state that produces the nag is per DOC. So when one
# doc cannot publish — because the server REJECTS it, not because nobody tried — the only
# lever was `publish: manual`, which silences every other doc in the vault too. What is
# left is a nag that fires every session with no action available, which trains the reader
# to ignore the channel. The orphan bucket already decided this case ("clear either way →
# no re-nag"); this is the missing other half.
#
#   name: atelier
#   publish: prompt
#   publish_overrides:
#     manual:
#       - BITACORA.mdx                  # why this path is listed goes right here
#       - docs/context-architecture.mdx
#
# Absent ⇒ today's behavior, byte for byte. Two properties are the whole point: it is
# EXPLICIT (someone had to type the path, and by convention the reason beside it) and it
# EXPIRES BY ITSELF (delete the line when the block lifts). No implicit suppression, ever.
#
# The shape is deliberately narrow, and every narrowing fails toward KEEPING THE NAG:
#
#   - Paths are EXACT and relative to the VAULT ROOT — the directory holding vault.yaml,
#     which is the same root the CLI walks up to when it derives a slug. One rule in both
#     places or they drift.
#   - NO GLOBS. An entry containing any of `* ? [ ] { } !` never matches, so the doc keeps
#     its vault policy. The guardrail IS that suppression costs someone an explicit line;
#     a glob lets one line silence a subtree nobody enumerated. Same bounded-shapes-or-
#     refuse stance `_bp_path_match()` takes below.
#   - All three policy words are accepted as keys (`manual`, `prompt`, `auto`), because
#     vault.yaml's vocabulary is three words and a key that means three things in one
#     place and one thing in another is a divergence waiting to happen. An unrecognized
#     key is IGNORED — its docs keep the vault policy, which fails toward nagging.
#   - BLOCK STYLE ONLY. `publish_overrides: {manual: [a]}` is not parsed; it reads as NO
#     overrides, so every doc keeps its vault policy and the hook keeps nagging.
#   - A vault.yaml that cannot be read, a doc outside the vault root, an empty block, a
#     capitalised key — all DELEGATE to vault_policy(), i.e. behave exactly as they did
#     before this existed.
#
# ⚠️ `auto` is accepted, so a listed path CAN newly reach stop.sh's auto bucket, which
# shells out to `basalt publish` — a real network write. Nothing about that bucket changes
# here; only WHICH files can reach it, and only when someone wrote the path explicitly.

# doc_policy <vault.yaml-path> <abs-doc-path>  ->  auto | prompt | manual
#   An override that names THIS doc wins (first matching entry, top to bottom); everything
#   else DELEGATES to vault_policy(). Non-regression is structural that way, not a
#   property we have to keep testing for.
doc_policy() {
  local v="$1" doc="$2" root rel line t val lead key="" entry hit="" in_block=1 kindent=""
  [ -f "$v" ] || { vault_policy "$v"; return 0; }
  root="$(dirname "$v")"
  case "$root" in
    /) rel="${doc#/}" ;;
    *) case "$doc" in
         "$root"/*) rel="${doc#"$root"/}" ;;
         *) vault_policy "$v"; return 0 ;;               # not under this root → no override
       esac ;;
  esac
  [ -n "$rel" ] || { vault_policy "$v"; return 0; }

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -ne 0 ]; then
      # Only a COLUMN-0 `publish_overrides:` with an empty value opens the block. A value
      # on the same line is flow style (or a scalar) → not parsed → no overrides at all.
      case "$line" in
        publish_overrides:*)
          val="$(_bp_trim "${line#publish_overrides:}")"
          case "$val" in ''|'#'*) in_block=0; key="" ;; esac ;;
      esac
      continue
    fi

    t="$(_bp_trim "$line")"
    [ -n "$t" ] || continue                              # blank lines do not end the block
    lead="${line%%[![:space:]]*}"
    [ "${#lead}" -gt 0 ] || break                        # indentation back to column 0 → over

    case "$t" in
      -*)
        [ -n "$key" ] || continue                        # entries under an ignored key
        entry="$(_bp_trim "${t#-}")"
        entry="$(_bp_strip_comment "$entry")"            # `- a.mdx  # the reason`
        entry="$(_bp_unquote "$(_bp_trim "$entry")")"
        entry="${entry#./}"
        [ -n "$entry" ] || continue
        case "$entry" in *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'!'*) continue ;; esac
        [ "$entry" = "$rel" ] && { hit="$key"; break; } ;;
      *:*)
        # `manual:` / `prompt:` / `auto:` open a list. Anything else — a capitalised or
        # misspelled word, a key carrying a same-line value, or a key NESTED one level
        # deeper than the first key in this block (`weird:` then `manual:` under it) —
        # leaves `key` empty, so its entries are skipped and those docs keep the vault
        # policy. The nesting check exists because without it an unrecognized key would
        # not ignore its subtree, and over-accepting here fails toward SILENCE.
        [ -n "$kindent" ] || kindent="${#lead}"
        val="$(_bp_trim "${t#*:}")"
        entry="$(_bp_trim "${t%%:*}")"
        key=""
        if [ "${#lead}" -eq "$kindent" ]; then
          case "$val" in
            ''|'#'*) case "$entry" in manual|prompt|auto) key="$entry" ;; esac ;;
          esac
        fi ;;
      *) key="" ;;
    esac
  done < "$v"

  case "$hit" in
    auto|prompt|manual) printf '%s' "$hit" ;;
    *) vault_policy "$v" ;;
  esac
  return 0
}

# =====================================================================================
# A2 — the dirty list is an APPEND-ONLY JOURNAL, not a read-modify-write
# =====================================================================================
# Two writers, both O_APPEND only:
#
#   Edit|Write → post-edit.sh    APPENDS a bare ABSOLUTE path      ("this doc was edited")
#   Bash       → post-publish.sh APPENDS a "-<operand>" tombstone   ("this doc published")
#   Stop       → stop.sh         REPLAYS the journal top-to-bottom  → the LIVE set
#
# `-` is unambiguous as a tombstone marker because a dirty entry is always an absolute
# path and starts with `/`.
#
# Why a journal and not a rewrite: subagent edits fire post-edit.sh under the PARENT's
# session id, so two appends can race. Under mktemp+mv one of them is LOST, and the
# direction of a lost update is SILENCE — the hook stops nagging for a doc nobody
# published. Appending removes the race by construction (no lock: `flock` is absent on
# macOS). It also makes ordering correct for free: `Write → publish → Edit → publish`
# lands right at every point, because each event is applied WHEN IT HAPPENED. A
# subtract-at-Stop design gets that sequence wrong.
#
# Tombstone matching, applied at replay where the whole ordering is visible:
#   "-/abs/path"   → EXACT match. post-publish.sh already resolved the operand against a
#                    base it could see (a `cd` in the command, else the payload's cwd).
#                    No exact match ⇒ drop NOTHING — there is no suffix fallback here,
#                    because suffix matching across two vaults sharing a basename is
#                    confident of the WRONG answer.
#   "-rel/path"    → the base was UNRESOLVABLE. Match by path SUFFIX, and only when
#                    exactly one live entry matches; 2+ candidates drop none. Ambiguity
#                    always resolves toward nagging, never toward silence.
#
# replay_journal <journal-file> -> prints the live set, one absolute path per line.
replay_journal() {
  local f="$1" line rest i n hit hits
  local -a live=()
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      -*)
        rest="${line#-}"
        [ -n "$rest" ] || continue
        hit=-1; hits=0; n=${#live[@]}
        for ((i = 0; i < n; i++)); do
          [ -n "${live[i]}" ] || continue
          case "$rest" in
            /*) [ "${live[i]}" = "$rest" ] && { hit=$i; hits=$((hits + 1)); } ;;
            *)  case "${live[i]}" in */"$rest") hit=$i; hits=$((hits + 1)) ;; esac ;;
          esac
        done
        [ "$hits" -eq 1 ] && live[$hit]=""
        ;;
      *)
        hit=0; n=${#live[@]}
        for ((i = 0; i < n; i++)); do
          [ "${live[i]}" = "$line" ] && { hit=1; break; }
        done
        [ "$hit" -eq 1 ] || live+=("$line")
        ;;
    esac
  done < "$f"
  n=${#live[@]}
  for ((i = 0; i < n; i++)); do
    [ -n "${live[i]}" ] && printf '%s\n' "${live[i]}"
  done
  return 0
}

# =====================================================================================
# Mechanism B — is this doc already on its way to publication via the repo's Action?
# =====================================================================================
# The #4 case: the mandated flow for a repo-backed vault is commit + push → the repo's
# GitHub Action publishes. Nothing local ever clears the dirty list, so the nag is
# UNCONDITIONAL. Everything below is local (string ops + `git` plumbing): zero network,
# zero added `basalt` invocations.
#
# WHAT THIS CLAIMS, EXACTLY: not a prediction of what the Action publishes, only
# *positive local evidence that a push of this file, on this branch, STARTS a Basalt
# publish workflow*. Everything downstream of the trigger (run-step filters, `if:`
# conditions, a workflow that starts and then fails) is declared invisible.
#
# EVERY failure and every ambiguity below resolves toward KEEPING THE NAG.

# --- small string helpers (no regex: ugrep and GNU grep disagree on `[^\n]`, recon F6) --
_bp_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_bp_unquote() {
  local s="$1"
  case "$s" in
    "'"*"'") s="${s#\'}"; s="${s%\'}" ;;
    '"'*'"') s="${s#\"}"; s="${s%\"}" ;;
  esac
  printf '%s' "$s"
}

# _bp_strip_comment <scalar> -> the scalar with a trailing YAML `# comment` removed.
# A comment starts at a `#` that OPENS the text or follows whitespace, so `a#b.md` stays a
# filename while `a.md # why` loses its tail. Used by doc_policy() for the reason someone
# writes next to an override entry — the convention that makes the block self-documenting.
# (A `#` inside a quoted scalar is cut too: that entry then matches nothing, which is the
# safe direction — it keeps the nag.)
_bp_strip_comment() {
  local s="$1" kept="" rest="$1" pre last
  while :; do
    case "$rest" in *'#'*) ;; *) break ;; esac
    pre="${rest%%'#'*}"
    if [ -n "$pre" ]; then last="${pre#"${pre%?}"}"      # char right before this `#`
    elif [ -n "$kept" ]; then last='#'                   # `##` — not a comment opener
    else last=' '                                        # `#` opens the whole scalar
    fi
    case "$last" in
      [[:space:]]) printf '%s' "$kept$pre"; return 0 ;;
    esac
    kept="$kept$pre#"
    rest="${rest#*'#'}"
  done
  printf '%s' "$kept$rest"
}

# _bp_path_match <github-paths-pattern> <repo-relative-path>
#   0 = matches · 1 = does not match · 2 = shape not supported (caller keeps the nag)
#
# BOUNDED shapes only, as `case` globs: `**.EXT` · `**/*.EXT` · `*.EXT` · `dir/**` ·
# `dir/**/*.EXT` · literal. Everything else is unsupported ON PURPOSE. `!` negation is
# the sharpest example: GitHub allows it in `paths:` and it INVERTS the filter, so
# guessing its direction yields silence on a doc nobody published.
_bp_path_match() {
  local p="$1" f="$2" ext dir
  case "$p" in
    ''|'!'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*) return 2 ;;
  esac
  case "$p" in
    '**.'*)
      ext="${p#'**'}"
      case "$ext" in *'*'*|*'/'*) return 2 ;; esac
      case "$f" in *"$ext") return 0 ;; *) return 1 ;; esac ;;
    '**/*.'*)
      ext="${p#'**/*'}"
      case "$ext" in *'*'*|*'/'*) return 2 ;; esac
      case "$f" in *"$ext") return 0 ;; *) return 1 ;; esac ;;
    '*.'*)
      ext="${p#'*'}"
      case "$ext" in *'*'*|*'/'*) return 2 ;; esac
      case "$f" in */*) return 1 ;; esac          # `*` does not cross a `/`
      case "$f" in *"$ext") return 0 ;; *) return 1 ;; esac ;;
    *'/**/*.'*)
      dir="${p%%'/**/*'*}"; ext="${p##*'/**/*'}"
      case "$dir" in *'*'*) return 2 ;; esac
      case "$ext" in *'*'*|*'/'*) return 2 ;; esac
      case "$f" in "$dir"/*) : ;; *) return 1 ;; esac
      case "$f" in *"$ext") return 0 ;; *) return 1 ;; esac ;;
    *'/**')
      dir="${p%'/**'}"
      case "$dir" in *'*'*) return 2 ;; esac
      case "$f" in "$dir"/*) return 0 ;; *) return 1 ;; esac ;;
    *'*'*) return 2 ;;
    *) [ "$p" = "$f" ] && return 0 || return 1 ;;
  esac
}

# workflow_triggers_publish <workflow-file> <current-branch> <repo-relative-doc-path>
#   0 when a push of this file on this branch STARTS this workflow. Conditions (5)–(8):
#     5. it has a `push:` trigger        (a schedule:/release:-only workflow never fires)
#     6. EVERY `branches:` list contains the current branch   (absent → pass)
#     7. EVERY `paths:` list matches the repo-relative path   (absent → pass)
#     8. NO `paths-ignore:` / `branches-ignore:` anywhere     (negation is not modelled)
#
# "EVERY list must match" sidesteps YAML nesting entirely — we never need to know which
# trigger owns which list — and being a conjunction it fails toward nagging.
workflow_triggers_publish() {
  local wf="$1" branch="$2" rel="$3"
  local line t lead rest pre val inner item key
  local in_on=1 push_seen=1
  local kind="" list_n=0 list_ok=1
  local -a parts=()

  [ -f "$wf" ] || return 1

  # (8) — negation is not modelled, in either direction.
  grep -Fq 'paths-ignore' "$wf" 2>/dev/null && return 1
  grep -Fq 'branches-ignore' "$wf" 2>/dev/null && return 1

  while IFS= read -r line || [ -n "$line" ]; do
    t="$(_bp_trim "$line")"
    case "$t" in '#'*) continue ;; esac

    # --- continuation of an open BLOCK sequence (`paths:` / `branches:` on its own line)
    if [ -n "$kind" ]; then
      case "$t" in
        '') continue ;;
        -*)
          item="$(_bp_unquote "$(_bp_trim "${t#-}")")"
          case "$item" in '!'*) return 1 ;; esac
          if [ "$kind" = branches ]; then
            [ "$item" = "$branch" ] && list_ok=0
          else
            _bp_path_match "$item" "$rel"
            case $? in 0) list_ok=0 ;; 2) return 1 ;; esac
          fi
          list_n=$((list_n + 1))
          continue ;;
        *)
          { [ "$list_n" -gt 0 ] && [ "$list_ok" -eq 0 ]; } || return 1
          kind=""; list_n=0; list_ok=1 ;;
      esac
    fi
    [ -n "$t" ] || continue

    # --- top-level key tracking: only the `on:` block is trigger configuration ---------
    lead="${line%%[![:space:]]*}"
    if [ "${#lead}" -eq 0 ]; then
      case "$t" in
        on:*|'"on":'*|"'on':"*) in_on=0 ;;
        *:*) in_on=1 ;;
      esac
    fi
    [ "$in_on" -eq 0 ] || continue

    # --- (5) a `push:` trigger --------------------------------------------------------
    case "$t" in
      push:|push:[[:space:]]*|push:'{'*|*' push:'*|*'{push:'*|*',push:'*) push_seen=0 ;;
    esac
    case "$t" in
      on:*)
        val="$(_bp_trim "${t#on:}")"
        case "$val" in
          ''|'{'*|'#'*) : ;;
          *) case "$val" in *push*) push_seen=0 ;; esac ;;
        esac ;;
    esac

    # --- (6)+(7) every `branches:` / `paths:` list, wherever it sits in the `on:` block -
    for key in branches: paths:; do
      rest="$t"
      while :; do
        case "$rest" in *"$key"*) ;; *) break ;; esac
        pre="${rest%%"$key"*}"
        rest="${rest#*"$key"}"
        # the key must START a mapping entry: line start, or after `{`, `,` or a space
        case "$pre" in ''|*' '|*'{'|*',') ;; *) continue ;; esac
        val="$(_bp_trim "$rest")"
        case "$val" in
          '['*)
            inner="${val#'['}"
            case "$inner" in *']'*) ;; *) return 1 ;; esac     # multi-line flow: unreadable
            inner="${inner%%]*}"
            list_ok=1; list_n=0
            IFS=',' read -ra parts <<< "$inner"
            for item in ${parts[@]+"${parts[@]}"}; do
              item="$(_bp_unquote "$(_bp_trim "$item")")"
              [ -n "$item" ] || continue
              case "$item" in '!'*) return 1 ;; esac
              if [ "${key%:}" = branches ]; then
                [ "$item" = "$branch" ] && list_ok=0
              else
                _bp_path_match "$item" "$rel"
                case $? in 0) list_ok=0 ;; 2) return 1 ;; esac
              fi
              list_n=$((list_n + 1))
            done
            { [ "$list_n" -gt 0 ] && [ "$list_ok" -eq 0 ]; } || return 1
            list_ok=1; list_n=0 ;;
          ''|'#'*)
            kind="${key%:}"; list_n=0; list_ok=1 ;;             # block sequence follows
          '}'*|','*) return 1 ;;                                # empty value: unreadable
          *)
            item="${val%%,*}"; item="${item%%\}*}"
            item="$(_bp_unquote "$(_bp_trim "$item")")"
            [ -n "$item" ] || return 1
            case "$item" in '!'*) return 1 ;; esac
            if [ "${key%:}" = branches ]; then
              [ "$item" = "$branch" ] || return 1
            else
              _bp_path_match "$item" "$rel" || return 1
            fi ;;
        esac
      done
    done
  done < "$wf"

  [ -z "$kind" ] || { [ "$list_n" -gt 0 ] && [ "$list_ok" -eq 0 ]; } || return 1
  [ "$push_seen" -eq 0 ] || return 1
  return 0
}

# git_path_committed_and_pushed <repo-root> <path>
#   0 when <path> is TRACKED, has no uncommitted changes, and the commit that last
#   touched it is an ancestor of the branch's upstream — i.e. it was PUSHED.
#
# THE SUBJECT IS LOAD-BEARING. This same predicate is applied to two different files:
#   - the DOC      → spec conditions (2) + (3)
#   - the WORKFLOW → spec condition (0)
# Read as "the same two git calls" without naming the subject, the next reader points
# both of them at the doc and reopens the hole the refute-pass found: `basalt onboard`
# writes an UNTRACKED workflow, the agent pushes only the doc, and every condition
# passes against a workflow that does not exist on the branch whose push was verified.
git_path_committed_and_pushed() {
  local root="$1" path="$2" st commit up
  git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || return 1
  st="$(git -C "$root" status --porcelain -- "$path" 2>/dev/null)" || return 1
  [ -z "$st" ] || return 1
  commit="$(git -C "$root" log -1 --format=%H -- "$path" 2>/dev/null)" || return 1
  [ -n "$commit" ] || return 1
  up="$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || return 1
  [ -n "$up" ] || return 1
  git -C "$root" merge-base --is-ancestor "$commit" "$up" 2>/dev/null || return 1
  return 0
}

# --- per-REPO half of the filter, memoised (resolved once per repo root, not per file) --
# bash 3.2 (macOS) has no associative arrays → two parallel arrays.
_BP_MEMO_ROOT=(); _BP_MEMO_WF=()

# _bp_compute_candidates <repo-root> -> newline-joined QUALIFIED candidate workflows
#   (1) the repo declares at least one candidate Basalt publish workflow
#       (`.github/workflows/*.y*ml` mentioning `basalt`)
#   (0) that candidate WORKFLOW FILE is itself tracked, clean and pushed
#   (4) the current branch IS the repo's default branch. Full stop, no disjunct:
#       `branches: [main]` ships in the canonical template (F7), so a permissive default
#       here goes quiet on a doc that will never publish, for every user.
_bp_compute_candidates() {
  local root="$1" def cur wf out=""
  def="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || return 0
  [ -n "$def" ] || return 0
  def="${def#origin/}"
  cur="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || return 0
  [ -n "$cur" ] || return 0                      # detached HEAD → keep the nag
  [ "$cur" = "$def" ] || return 0                # B3: not the default branch → keep it
  for wf in "$root"/.github/workflows/*.y*ml; do
    [ -f "$wf" ] || continue
    grep -Fq basalt "$wf" 2>/dev/null || continue                 # (1)
    git_path_committed_and_pushed "$root" "$wf" || continue       # (0) — the WORKFLOW
    out="$out$wf
"
  done
  printf '%s' "$out"
}

repo_publish_candidates() {
  local root="$1" i n out
  n=${#_BP_MEMO_ROOT[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_BP_MEMO_ROOT[i]}" = "$root" ]; then printf '%s' "${_BP_MEMO_WF[i]}"; return 0; fi
  done
  out="$(_bp_compute_candidates "$root")"
  _BP_MEMO_ROOT+=("$root"); _BP_MEMO_WF+=("$out")
  printf '%s' "$out"
}

# published_by_repo_action <abs-doc-path>
#   0 → drop it from the dirty list (a push of it starts a Basalt publish workflow)
#   1 → KEEP THE NAG (the default for every failure, every ambiguity, every gap)
published_by_repo_action() {
  local file="$1" root rel cands wf cur
  command -v git >/dev/null 2>&1 || return 1
  root="$(cd "$(dirname "$file")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  cands="$(repo_publish_candidates "$root")"
  [ -n "$cands" ] || return 1
  git_path_committed_and_pushed "$root" "$file" || return 1     # (2)+(3) — the DOC
  case "$file" in "$root"/*) rel="${file#"$root"/}" ;; *) return 1 ;; esac
  cur="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || return 1
  # C2: (5)–(8) are evaluated PER CANDIDATE; ONE qualifying candidate is enough. The
  # other reading (all must qualify) lets a single workflow_dispatch-only helper kill
  # Mechanism B repo-wide, silently, with every test green.
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    workflow_triggers_publish "$wf" "$cur" "$rel" && return 0
  done <<< "$cands"
  return 1
}
