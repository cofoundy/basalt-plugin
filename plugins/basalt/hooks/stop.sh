#!/usr/bin/env bash
# stop.sh — Stop hook (fires after EVERY assistant turn). Closes the turn based on the
# session dirty-list + each vault's `publish:` policy. Silence by default.
#
#   stop_hook_active == true         → exit 0 SILENT (loop guard — VERIFIED it fires here).
#   dirty-list empty / missing       → exit 0 SILENT (the common case).
#   dirty file, policy `manual`      → ignored, silent.
#   dirty file, policy `prompt`(def) → {"decision":"block","reason":"…"} → the model offers
#                                      to publish (VERIFIED: the reason reaches the model and
#                                      it acts; the next Stop fires with stop_hook_active=true
#                                      and we exit silent → no loop).
#   dirty file, policy `auto`        → `basalt publish` those files ONCE (diff-aware, server
#                                      sha-skips no-ops). Success → plain receipt line (no model
#                                      turn). Failure / no CLI → degrade to the prompt nudge.
#
# The dirty-list is CLEARED after we speak, so a subsequent turn with no NEW edits stays
# silent (no per-turn nagging). Batching-at-close, never push-on-edit (IRT NO-GO).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

payload="$(cat)"

# 1) Loop guard FIRST — never re-enter after we've already blocked once this stop.
[ "$(json_get "$payload" "stop_hook_active")" = "true" ] && exit 0

sid="$(json_get "$payload" "session_id")"
[ -n "$sid" ] || sid="nosession"
df="$(dirty_file "$sid")"
of="$(orphan_file "$sid")"
[ -f "$df" ] || [ -f "$of" ] || exit 0                 # nothing tracked → silent

# 2) Bucket the (existing, deduped) dirty files by their nearest vault's policy.
auto_files=(); prompt_n=0
if [ -f "$df" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(vault_policy "$(find_vault "$f")")" in
      auto)   auto_files+=("$f") ;;
      manual) : ;;                                     # explicitly silent
      *)      prompt_n=$((prompt_n + 1)) ;;            # prompt (default)
    esac
  done < "$df"
fi

# 2b) Orphan bucket: docs edited in a repo with NO vault.yaml. Only speak when the CLI is
# actually installed — without it the user is not publishing from here and the warning is
# noise. Silence for a real user beats a warning for a hypothetical one.
orphan_root=""
if [ -f "$of" ] && command -v basalt >/dev/null 2>&1; then
  orphan_root="$(head -1 "$of")"
fi
rm -f "$of" 2>/dev/null                                # clear either way → no re-nag

# 3) Auto bucket: one diff-aware publish. Failure / no CLI → degrade into the prompt count.
published_n=0
if [ "${#auto_files[@]}" -gt 0 ]; then
  if command -v basalt >/dev/null 2>&1 && basalt publish "${auto_files[@]}" >/dev/null 2>&1; then
    published_n=${#auto_files[@]}
  else
    prompt_n=$((prompt_n + ${#auto_files[@]}))
  fi
fi

emit_block() {   # $1 = reason (≤200B); model gets it and acts, guarded against looping
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{decision:"block", reason:$r}'
  else
    local e=${1//\\/\\\\}; e=${e//\"/\\\"}
    printf '{"decision":"block","reason":"%s"}' "$e"
  fi
}

rm -f "$df" 2>/dev/null                                # clear AFTER reading → no re-nag

# 4) Speak once, ≤200 bytes, prompt-before-receipt (a pending decision beats a confirmation).
if [ "$prompt_n" -gt 0 ]; then
  if [ "$published_n" -gt 0 ]; then
    emit_block "Basalt: auto-published $published_n doc(s); $prompt_n other vault doc(s) edited but unpublished — publish them too? (push to the repo Action, or \`basalt publish\`)."
  else
    emit_block "Basalt: $prompt_n vault doc(s) edited but unpublished. Publish now? (push to the repo's Action, or \`basalt publish\` the changed files)."
  fi
elif [ "$published_n" -gt 0 ]; then
  printf 'Basalt: auto-published %d edited vault doc(s). Share the canonical URL(s) with the reader.\n' "$published_n"
elif [ -n "$orphan_root" ]; then
  # The silent-failure sensor. Says the CONSEQUENCE, not the config detail — "no
  # vault.yaml" means nothing to a reader who has never hit this; "goes to the wrong
  # space without erroring" is why they should care before the first publish.
  emit_block "Basalt: docs edited in $(basename "$orphan_root"), which has no vault.yaml — publishing from here silently lands in the wrong space (exit 0). Run \`basalt onboard\` for the fix."
fi
exit 0
