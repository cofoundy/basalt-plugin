#!/usr/bin/env bash
# mutate.sh — the mutation pass. OPT-IN, not CI.
#
# A suite that has never gone red proves nothing: a guard whose mutant still passes is
# NOT TESTED. So each guard is broken on purpose and the suite must go red.
#
# AND THE MUTANT IS AN ENVIRONMENT TOO. Before a mutant's verdict is read this proves the
# mutant actually mutated — the pattern was found and replaced, `bash -n` passes, and a
# smoke run of every hook still exits 0. Otherwise "the test does not catch it" is
# indistinguishable from "the mutant never ran", which is exactly the conclusion one is
# fishing for.
#
# The set is a RECIPE, not a count: one named mutant per Mechanism B condition (0)–(8),
# plus one per gate-introduced guard (the C3 dedup, the A1b metacharacter precondition,
# the base-resolution rule), plus the A1 segment-trust and A3 --dry-run guards.
#
#   bash plugins/basalt/hooks/tests/mutate.sh            # all mutants
#   bash plugins/basalt/hooks/tests/mutate.sh M0 M9      # named mutants only
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(dirname "$HERE")"
command -v python3 >/dev/null 2>&1 || { echo "mutate.sh needs python3 for literal-exact patching"; exit 2; }

survived=0; killed=0; broken=0

# apply <mutant-dir> <file> <old> <new>  — literal-exact replacement; fails if absent.
apply() {
  BP_FILE="$1/$2" BP_OLD="$3" BP_NEW="$4" python3 -c '
import os, sys
p, old, new = os.environ["BP_FILE"], os.environ["BP_OLD"], os.environ["BP_NEW"]
s = open(p).read()
if old not in s:
    sys.stderr.write("pattern NOT FOUND in %s\n" % p); sys.exit(3)
open(p, "w").write(s.replace(old, new))
sys.stdout.write(str(s.count(old)))
'
}

# mutate <id> <mutant-dir> — the mutation table. Every OLD string is verbatim source.
mutate() {
  local id="$1" d="$2"
  case "$id" in
    M0) apply "$d" lib.sh \
        '    git_path_committed_and_pushed "$root" "$wf" || continue       # (0) — the WORKFLOW' \
        '    true || continue' ;;
    M1) apply "$d" lib.sh \
        '    grep -Fq basalt "$wf" 2>/dev/null || continue                 # (1)' \
        '    true || continue' ;;
    M2) apply "$d" lib.sh \
        '  [ -z "$st" ] || return 1' \
        '  [ -z "$st" ] || :' ;;
    M3) apply "$d" lib.sh \
        '  git -C "$root" merge-base --is-ancestor "$commit" "$up" 2>/dev/null || return 1' \
        '  git -C "$root" merge-base --is-ancestor "$commit" "$up" 2>/dev/null || :' ;;
    M4) apply "$d" lib.sh \
        '  [ "$cur" = "$def" ] || return 0                # B3: not the default branch → keep it' \
        '  [ "$cur" = "$def" ] || :' ;;
    M5) apply "$d" lib.sh \
        '  [ "$push_seen" -eq 0 ] || return 1' \
        '  [ "$push_seen" -eq 0 ] || :' ;;
    M6) apply "$d" lib.sh \
        '[ "$item" = "$branch" ] && list_ok=0' \
        'list_ok=0' ;;
    M7) apply "$d" lib.sh \
        'case $? in 0) list_ok=0 ;; 2) return 1 ;; esac' \
        'list_ok=0' ;;
    M8) apply "$d" lib.sh \
        "  grep -Fq 'paths-ignore' \"\$wf\" 2>/dev/null && return 1
  grep -Fq 'branches-ignore' \"\$wf\" 2>/dev/null && return 1" \
        '  :' ;;
    # The '!' guard is defended in three places — the matcher's shape list and both list
    # readers. Removing one layer leaves the other two standing, so the mutant has to
    # take all of them or it reports "not tested" about a guard that IS tested.
    M8b) { apply "$d" lib.sh \
            "    ''|'!'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*) return 2 ;;" \
            "    ''|*'?'*|*'['*|*']'*|*'{'*|*'}'*) return 2 ;;" \
          && printf '+' \
          && apply "$d" lib.sh \
            "case \"\$item\" in '!'*) return 1 ;; esac" \
            ':' ; } ;;
    M9) apply "$d" post-edit.sh \
        '  printf '"'"'%s\n'"'"' "$file" >> "$(dirty_file "$sid")"      # under a vault → publishable' \
        '  append_once "$(dirty_file "$sid")" "$file"' ;;
    M10) apply "$d" post-publish.sh \
        "case \"\$cmd\" in
  *\\'*|*\\\"*|*\\\\*) exit 0 ;;
esac" \
        ':' ;;
    M11) apply "$d" post-publish.sh \
        '      *)  if [ -n "$rbase" ]; then target="$rbase/$op"; else target="$op"; fi ;;' \
        '      *)  target="$op" ;;' ;;
    M12) apply "$d" post-publish.sh \
        '  seg_trusted "$k" || continue' \
        '  true || continue' ;;
    M13) apply "$d" post-publish.sh \
        '    [ "${toks[j]}" = "--dry-run" ] && return 1' \
        '    [ "${toks[j]}" = "--never-a-real-flag" ] && return 1' ;;
    *) echo "unknown mutant: $id"; return 9 ;;
  esac
}

describe() {
  case "$1" in
    M0)  echo "condition (0) — the candidate WORKFLOW must be tracked, clean and pushed" ;;
    M1)  echo "condition (1) — the workflow must mention basalt to be a candidate" ;;
    M2)  echo "condition (2) — no uncommitted changes (subject: DOC, and WORKFLOW via (0))" ;;
    M3)  echo "condition (3) — last commit is an ancestor of upstream, i.e. PUSHED" ;;
    M4)  echo "condition (4) — the current branch IS the repo's default branch (B3)" ;;
    M5)  echo "condition (5) — the workflow has a push: trigger" ;;
    M6)  echo "condition (6) — every branches: list contains the current branch" ;;
    M7)  echo "condition (7) — every paths: list matches the repo-relative path" ;;
    M8)  echo "condition (8) — no paths-ignore:/branches-ignore: anywhere" ;;
    M8b) echo "condition (8) — a '!'-negated pattern is unsupported, not guessed" ;;
    M9)  echo "C3 dedup — restore append_once on the DIRTY list (B1's wrong fix)" ;;
    M10) echo "A1b — the metacharacter precondition" ;;
    M11) echo "base resolution (ii) — resolved base + no exact match clears NOTHING" ;;
    M12) echo "A1 — segment trust (only the last segment, or an all-&& chain)" ;;
    M13) echo "A3 — --dry-run publishes nothing" ;;
  esac
}

IDS=("$@")
[ "${#IDS[@]}" -gt 0 ] || IDS=(M0 M1 M2 M3 M4 M5 M6 M7 M8 M8b M9 M10 M11 M12 M13)

BASE_TMP="$(mktemp -d)"; trap 'rm -rf "$BASE_TMP"' EXIT

for id in "${IDS[@]}"; do
  d="$BASE_TMP/$id"; mkdir -p "$d"
  cp -R "$HOOKS/." "$d/"
  printf '\n══ %s — %s\n' "$id" "$(describe "$id")"

  # 1) the mutation must actually land
  if ! n="$(mutate "$id" "$d" 2>&1)"; then
    printf '   BROKEN  mutation did not apply: %s\n' "$n"; broken=$((broken+1)); continue
  fi
  printf '   applied at %s site(s)\n' "$n"

  # 2) the mutant must be a RUNNABLE environment
  synok=1
  for s in "$d"/*.sh; do bash -n "$s" 2>/dev/null || { printf '   BROKEN  bash -n failed on %s\n' "$(basename "$s")"; synok=0; }; done
  [ "$synok" -eq 1 ] || { broken=$((broken+1)); continue; }
  smoke=1
  printf '{}' | bash "$d/stop.sh"        >/dev/null 2>&1 || smoke=0
  printf '{}' | bash "$d/post-edit.sh"   >/dev/null 2>&1 || smoke=0
  printf '{}' | bash "$d/post-publish.sh" >/dev/null 2>&1 || smoke=0
  [ "$smoke" -eq 1 ] || { printf '   BROKEN  smoke run of a hook exited non-zero\n'; broken=$((broken+1)); continue; }
  printf '   mutant is live (bash -n + smoke run of all three hooks: OK)\n'

  # 3) the suite must go RED
  out="$(bash "$d/tests/run.sh" 2>&1)"
  tally="$(printf '%s' "$out" | grep -E '^pass=' || echo 'pass=? fail=?')"
  if printf '%s' "$out" | grep -q '^  FAIL '; then
    killed=$((killed+1))
    printf '   KILLED  (%s) — catching assertions:\n' "$tally"
    printf '%s' "$out" | grep '^  FAIL ' | sed 's/^  FAIL /     · /'
  else
    survived=$((survived+1))
    printf '   SURVIVED (%s) — NO catching assertion. This is a condition the suite does NOT test.\n' "$tally"
  fi
done

printf '\n─────────────────────────────────────────────────────────────\n'
printf 'mutants=%d killed=%d survived=%d broken=%d\n' "${#IDS[@]}" "$killed" "$survived" "$broken"
{ [ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]; } || exit 1
