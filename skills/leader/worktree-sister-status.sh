#!/usr/bin/env bash
# worktree-sister-status.sh [DIR]
#
# Report each worktree sister registered in DIR's planning bucket, park state
# against her worktree's HEAD. Read-only: runs git and reads the bucket's
# sisters directory; writes nothing.
#
# Output, one line per sister registered as sisters/<name>/WORKTREE in the
# planning bucket:
#   <name> <state> worktree=<path> branch=<branch> parked=<sha12> live=<sha12> left=<yes|no>
# where state is one of:
#   OK            PARK.md names a sha of at least 7 characters that prefixes HEAD
#   MISMATCH      PARK.md names another commit
#   SCHEMA        PARK.md holds other than exactly one line matching ^sha:
#   NO-PARK-FILE  no PARK.md yet; unresolved, not a failure
#   NO-WORKTREE   the worktree is absent, or git does not list it
# Then, for each non-empty BLOCKED.md:
#   == <name> BLOCKED (<path>)
#   <its content>
#
# Exit status: 0 nothing to act on, 1 a MISMATCH, SCHEMA or NO-WORKTREE state
# or an open BLOCKED.md, 3 DIR has no .planning.
set -u
export LC_ALL=C

dir=${1:-.}
if [ ! -d "$dir/.planning" ]; then
  echo "NO-GSD $dir"
  exit 3
fi

bucket=$(readlink -f -- "$dir/.planning")
shopt -s nullglob
regs=("$bucket"/sisters/*/WORKTREE)
if [ ${#regs[@]} -eq 0 ]; then
  echo "no worktree sisters registered"
  exit 0
fi

field() { awk -v k="$2:" '$1 == k { print $2; exit }' "$1"; }

listed=$(git -C "$dir" worktree list --porcelain 2>/dev/null)
status=0
blocked=()
for reg in "${regs[@]}"; do
  sdir=${reg%/WORKTREE}
  name=$(field "$reg" name)
  [ -n "$name" ] || name=${sdir##*/}
  wt=$(field "$reg" worktree)
  branch=$(field "$reg" branch)
  parked=-
  live=-
  left=no
  [ -s "$sdir/LEFT" ] && left=yes
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! grep -qxF "worktree $wt" <<<"$listed"; then
    state=NO-WORKTREE
  elif [ ! -e "$sdir/PARK.md" ]; then
    state=NO-PARK-FILE
    live=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo -)
  else
    live=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo -)
    if [ "$(grep -c '^sha:' "$sdir/PARK.md")" != 1 ]; then
      state=SCHEMA
    else
      parked=$(awk '/^sha:/ { print $2 }' "$sdir/PARK.md")
      if [ ${#parked} -ge 7 ] && [ "${live#"$parked"}" != "$live" ]; then
        state=OK
      else
        state=MISMATCH
      fi
      [ -n "$parked" ] || parked=-
    fi
  fi
  case $state in MISMATCH|SCHEMA|NO-WORKTREE) status=1 ;; esac
  printf '%-24s %-12s worktree=%s branch=%s parked=%.12s live=%.12s left=%s\n' \
    "$name" "$state" "${wt:--}" "${branch:--}" "$parked" "$live" "$left"
  if [ -s "$sdir/BLOCKED.md" ]; then
    blocked+=("$name|$sdir/BLOCKED.md")
    status=1
  fi
done

for b in "${blocked[@]}"; do
  printf '== %s BLOCKED (%s)\n' "${b%%|*}" "${b#*|}"
  cat -- "${b#*|}"
done
exit $status
