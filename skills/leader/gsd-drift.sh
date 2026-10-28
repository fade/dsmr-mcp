#!/usr/bin/env bash
# gsd-drift.sh [DIR]
#
# Report commits on the working branch that no GSD summary accounts for.
# Read-only: runs git log and reads files under .planning; writes nothing.
#
# Output lines:
#   anchor <sha12> <subject>          newest commit a *-SUMMARY.md names
#   window since <source> <iso8601>   time-window fallback when no summary names a commit
#   newest-artifact <path> <iso8601>  newest *-SUMMARY.md or STATE.md by mtime
#   state-last-activity <value>       STATE.md frontmatter last_activity, when present
#   in-flight <path>                  *-PLAN.md with no matching *-SUMMARY.md, newer than the anchor
#   OFF-PROCESS <sha12> <subject>     unaccounted commit, nothing in flight to own it
#   UNACCOUNTED <sha12> <subject> (an in-flight plan may own it)
#   drift=<n> in-flight=<m>
#
# Exit status: 0 no drift, 1 drift, 3 not a git work tree or no .planning.
set -u
export LC_ALL=C

dir=${1:-.}
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { echo "NO-GIT $dir"; exit 3; }
gsd=$top/.planning
if [ ! -e "$gsd" ]; then
  echo "NO-GSD $top: no .planning"
  exit 3
fi

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
rel() { printf '%s\n' "${1#"$top"/}"; }

# -L: .planning is normally a symlink out of the work tree.
summaries=$(find -L "$gsd" -name '*-SUMMARY.md' -type f 2>/dev/null)
state=$gsd/STATE.md

# Every lowercase hex word of 7..40 characters in any summary, as data.
tokens=$(printf '%s\n' "$summaries" | while IFS= read -r f; do
  [ -n "$f" ] && grep -ohE '\b[0-9a-f]{7,40}\b' -- "$f" 2>/dev/null
done | sort -u)

# Newest artifact by mtime among the summaries and STATE.md.
newest_path=""; newest_mtime=0
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
  if [ "$m" -gt "$newest_mtime" ]; then newest_mtime=$m; newest_path=$f; fi
done <<EOF
$summaries
$state
EOF

last_activity=""
if [ -f "$state" ]; then
  last_activity=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
    /^last_activity:/ { sub(/^last_activity:[ \t]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$state")
fi

# All parents: work that lands through a merge must be checked too, not only commits made on HEAD's branch.
commits=$(git -C "$top" log --no-merges -n 500 --format='%H%x09%ct%x09%s' HEAD 2>/dev/null)

# Walk newest-first. A commit is accounted when some prefix of length 7..40 of its
# sha is a token, so short and full shas both match and a stray hex word matching
# no commit is ignored. The first accounted commit is the anchor; stop there.
walk=$(printf '%s\n' "$tokens" | awk -F '\t' '
  FNR == NR { if ($0 != "") tok[$0] = 1; next }
  $1 == "" { next }
  {
    for (l = 7; l <= 40; l++) if (substr($1, 1, l) in tok) { print "A\t" $0; found = 1; exit }
    print "U\t" $0
  }
  END { if (!found) print "N" }' - <(printf '%s\n' "$commits"))

anchor_line=$(printf '%s\n' "$walk" | awk -F '\t' '$1 == "A"')
since=""
if [ -n "$anchor_line" ]; then
  since=$(printf '%s\n' "$anchor_line" | cut -f3)
  printf 'anchor %s %s\n' "$(printf '%s\n' "$anchor_line" | cut -c3-14)" "$(printf '%s\n' "$anchor_line" | cut -f4-)"
  unaccounted=$(printf '%s\n' "$walk" | awk -F '\t' '$1 == "U" { print $2 "\t" $3 "\t" $4 }')
else
  # Fallback only: mtimes are unreliable when .planning is synced between hosts,
  # which is why a sha named in a summary is preferred as the anchor.
  since=$newest_mtime; source=${newest_path:+$(rel "$newest_path")}
  if [ -n "$last_activity" ]; then
    stamp=$(printf '%s\n' "$last_activity" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?')
    if [ -n "$stamp" ] && la=$(date -d "$stamp" +%s 2>/dev/null) && [ "$la" -gt "$since" ]; then
      since=$la; source=last_activity
    fi
  fi
  printf 'window since %s %s\n' "${source:-none}" "$(iso "$since")"
  unaccounted=$(printf '%s\n' "$commits" | awk -F '\t' -v t="$since" '$1 != "" && $2 > t')
fi

if [ -n "$newest_path" ]; then
  printf 'newest-artifact %s %s\n' "$(rel "$newest_path")" "$(iso "$newest_mtime")"
fi
[ -n "$last_activity" ] && printf 'state-last-activity %s\n' "$last_activity"

# In-flight: a *-PLAN.md with no *-SUMMARY.md of the same prefix, newer than the anchor.
inflight=0
for sub in phases quick; do
  [ -d "$gsd/$sub" ] || continue
  while IFS= read -r -d '' p; do
    s=${p%-PLAN.md}-SUMMARY.md
    [ -e "$s" ] && continue
    m=$(stat -L -c %Y -- "$p" 2>/dev/null) || continue
    [ "$m" -gt "${since:-0}" ] || continue
    printf 'in-flight %s\n' "$(rel "$p")"
    inflight=$((inflight + 1))
  done < <(find -L "$gsd/$sub" -name '*-PLAN.md' -type f -print0 2>/dev/null | sort -z)
done

drift=0
while IFS="$(printf '\t')" read -r sha _ subject; do
  [ -n "$sha" ] || continue
  if [ "$inflight" -eq 0 ]; then
    printf 'OFF-PROCESS %s %s\n' "${sha:0:12}" "$subject"
  else
    printf 'UNACCOUNTED %s %s (an in-flight plan may own it)\n' "${sha:0:12}" "$subject"
  fi
  drift=$((drift + 1))
done <<EOF
$unaccounted
EOF

printf 'drift=%d in-flight=%d\n' "$drift" "$inflight"
[ "$drift" -eq 0 ]
