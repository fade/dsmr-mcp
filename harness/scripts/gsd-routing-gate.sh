#!/usr/bin/env bash
# gsd-routing-gate.sh [--root DIR] [--apply | --self-test]
#
# Report whether gsd-core carries the local routing patches, one unit per file
# in ../patches/gsd-core/ relative to this script. ROOT defaults to
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
#
# Units (patch basename, target under gsd-core, backup suffix):
#   per-plan-executor-routing     project executor default for execute-phase plans
#   quick-executor-routing        /gsd-quick routes to the executor its plan names
#   specialist-executor-model     a specialist executor keeps its own model
#   quick-batch-executor-routing  /gsd-quick-batch items route as /gsd-quick does
#
# --apply dry-runs every missing unit first and writes nothing unless all fit;
# each target is then backed up with its unit's suffix. --self-test runs the
# gate against scratch copies of ROOT (read-only) and checks every case below.
#
# Exit status:
#   0  every unit present (or applied by --apply); self-test passed
#   1  a unit is missing or its target absent; with --apply, nothing changed
#   2  gsd-core is not installed under ROOT (no unit target exists)
#  64  usage
set -u

usage() { echo "usage: $0 [--root DIR] [--apply | --self-test]"; }

root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
apply=0
selftest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage >&2; exit 64; }; root=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    --self-test) selftest=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[ "$apply" -eq 0 ] || [ "$selftest" -eq 0 ] || { usage >&2; exit 64; }

self=$(readlink -f "$0")
patch_dir=$(dirname "$self")/../patches/gsd-core

# unit|target under gsd-core|marker 1|marker 2|backup suffix
# shellcheck disable=SC2016 # a marker 2 holding ${...} is literal template text, never expanded
units=(
  'per-plan-executor-routing|gsd-core/workflows/execute-phase/steps/per-plan-executor-routing.md|dsmr-local: project executor default|planning.agents.executor|.pre-lisp-routing'
  'quick-executor-routing|gsd-core/workflows/quick.md|dsmr-local: quick executor routing|subagent_type="${EXECUTOR_TYPE}"|.pre-quick-executor-routing'
  'specialist-executor-model|gsd-core/workflows/execute-phase.md|dsmr-local: specialist executor model|EXECUTOR_TYPE != "gsd-executor"|.pre-specialist-executor-model'
  'quick-batch-executor-routing|gsd-core/workflows/quick-batch/steps/worktree-dispatch.md|dsmr-local: quick-batch executor routing|subagent_type="${EXECUTOR_TYPE}"|.pre-quick-batch-executor-routing'
)

# unit_field ROW N: print field N (1-based) of a unit row.
unit_field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }

# unit_state ROOT ROW: print present, missing, or absent.
unit_state() {
  local t m1 m2
  t=$1/$(unit_field "$2" 2); m1=$(unit_field "$2" 3); m2=$(unit_field "$2" 4)
  [ -f "$t" ] || { echo absent; return; }
  if grep -qF -- "$m1" "$t" && grep -qF -- "$m2" "$t"; then echo present; else echo missing; fi
}

# manifest DIR: sha256 of every file under DIR, sorted by path.
manifest() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }

# check ROOT: print one line per unit and the summary; return 0, 1 or 2.
check() {
  local r=$1 row name target st nabsent=0 nbad=0
  for row in "${units[@]}"; do
    name=$(unit_field "$row" 1); target=$(unit_field "$row" 2)
    st=$(unit_state "$r" "$row")
    case "$st" in
      present) printf 'present  %s\n' "$name" ;;
      missing) printf 'missing  %s: %s\n' "$name" "$r/$target"; nbad=$((nbad + 1)) ;;
      absent)  printf 'absent   %s: %s\n' "$name" "$r/$target"; nabsent=$((nabsent + 1)); nbad=$((nbad + 1)) ;;
    esac
  done
  if [ "$nabsent" -eq "${#units[@]}" ]; then
    echo "gsd-core absent under $r"
    return 2
  fi
  if [ "$nbad" -eq 0 ]; then
    echo "Lisp routing patch present"
    return 0
  fi
  echo "Lisp routing patch missing: $nbad of ${#units[@]} units"
  return 1
}

# apply_all ROOT: dry-run every missing unit, then apply them; return 0 or 1.
apply_all() {
  local r=$1 row name pf out todo=()
  for row in "${units[@]}"; do
    name=$(unit_field "$row" 1)
    case "$(unit_state "$r" "$row")" in
      absent) echo "cannot apply $name: target absent; nothing changed"; return 1 ;;
      missing)
        pf=$patch_dir/$name.patch
        [ -f "$pf" ] || { echo "patch file not found: $pf"; return 1; }
        if ! out=$(patch -p1 --forward --dry-run -d "$r" < "$pf" 2>&1); then
          printf '%s\n' "$out"
          echo "patch does not apply cleanly ($name); nothing changed"
          return 1
        fi
        todo+=("$row") ;;
    esac
  done
  for row in "${todo[@]}"; do
    name=$(unit_field "$row" 1)
    if ! out=$(patch -p1 --forward -b -z "$(unit_field "$row" 5)" -d "$r" < "$patch_dir/$name.patch" 2>&1); then
      printf '%s\n' "$out"
      return 1
    fi
    printf '%s\n' "$out"
  done
  return 0
}

# run_self_test ROOT: exercise the gate on scratch copies of ROOT; ROOT is only read.
run_self_test() {
  local src=$1 work ok=0 bad=0 before after rc row name sfx
  [ -d "$src/gsd-core" ] || { echo "gsd-core absent under $src" >&2; return 2; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/gsd-routing-gate.XXXXXX") || return 1
  # shellcheck disable=SC2064 # work is local; expand it now, not at exit
  trap "rm -rf '$work'" EXIT
  local src_before src_after
  src_before=$(manifest "$src/gsd-core")

  pass() { printf 'ok %s\n' "$1"; ok=$((ok + 1)); }
  fail() { printf 'FAIL %s: %s\n' "$1" "$2"; bad=$((bad + 1)); }

  # fresh NAME: copy the source into $work/NAME and reverse every present unit.
  fresh() {
    local d=$work/$1 r
    mkdir -p "$d" && cp -a "$src/gsd-core" "$d/" || return 1
    for r in "${units[@]}"; do
      if [ "$(unit_state "$d" "$r")" = present ]; then
        patch -p1 -R -s -d "$d" < "$patch_dir/$(unit_field "$r" 1).patch" >/dev/null 2>&1 || return 1
      fi
    done
  }

  # absent
  mkdir -p "$work/empty"
  "$self" --root "$work/empty" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then pass absent; else fail absent "exit $rc, want 2"; fi

  if ! fresh pristine; then
    fail pristine "cannot derive pristine targets"
  else
    cp -a "$work/pristine" "$work/orig"

    # missing
    out=$("$self" --root "$work/pristine" 2>&1); rc=$?
    n=$(printf '%s\n' "$out" | grep -c '^missing  ')
    if [ "$rc" -eq 1 ] && [ "$n" -eq "${#units[@]}" ]; then pass missing; else fail missing "exit $rc, $n missing lines"; fi

    # apply
    "$self" --root "$work/pristine" --apply >/dev/null 2>&1; rc=$?
    why=""
    [ "$rc" -eq 0 ] || why="exit $rc"
    for row in "${units[@]}"; do
      name=$(unit_field "$row" 2); sfx=$(unit_field "$row" 5)
      cmp -s "$work/orig/$name" "$work/pristine/$name$sfx" || why="$why; backup differs: $name$sfx"
    done
    [ -z "$(find "$work/pristine" \( -name '*.rej' -o -name '*.orig' \) -print -quit)" ] || why="$why; stray .rej/.orig"
    if [ -z "$why" ]; then pass apply; else fail apply "$why"; fi

    # idempotent
    before=$(manifest "$work/pristine/gsd-core")
    "$self" --root "$work/pristine" --apply >/dev/null 2>&1; rc=$?
    after=$(manifest "$work/pristine/gsd-core")
    if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then pass idempotent; else fail idempotent "exit $rc or tree changed"; fi
  fi

  # upgrade: only the first unit applied
  if ! fresh upgrade; then
    fail upgrade "cannot derive pristine targets"
  else
    row=${units[0]}
    patch -p1 -s -d "$work/upgrade" < "$patch_dir/$(unit_field "$row" 1).patch" >/dev/null 2>&1
    before=$(cat "$work/upgrade/$(unit_field "$row" 2)")
    out=$("$self" --root "$work/upgrade" 2>&1); rc=$?
    n=$(printf '%s\n' "$out" | grep -c '^missing  ')
    "$self" --root "$work/upgrade" --apply >/dev/null 2>&1; rc2=$?
    after=$(cat "$work/upgrade/$(unit_field "$row" 2)")
    if [ "$rc" -eq 1 ] && [ "$n" -eq $((${#units[@]} - 1)) ] && [ "$rc2" -eq 0 ] && [ "$before" = "$after" ]; then
      pass upgrade
    else
      fail upgrade "check exit $rc ($n missing), apply exit $rc2, first unit changed=$([ "$before" = "$after" ] && echo no || echo yes)"
    fi
  fi

  # drift: alter hunk anchor in quick.md; apply must refuse and change nothing
  if ! fresh drift; then
    fail drift "cannot derive pristine targets"
  else
    sed -i 's/subagent_type="gsd-executor",/subagent_type="gsd-executor-x",/' "$work/drift/gsd-core/workflows/quick.md"
    before=$(manifest "$work/drift/gsd-core")
    out=$("$self" --root "$work/drift" --apply 2>&1); rc=$?
    after=$(manifest "$work/drift/gsd-core")
    if [ "$rc" -eq 1 ] && [ "$before" = "$after" ] && printf '%s\n' "$out" | grep -q 'nothing changed'; then
      pass drift
    else
      fail drift "exit $rc, tree changed=$([ "$before" = "$after" ] && echo no || echo yes)"
    fi
  fi

  # source-untouched
  src_after=$(manifest "$src/gsd-core")
  if [ "$src_before" = "$src_after" ]; then pass source-untouched; else fail source-untouched "source tree changed"; fi

  printf 'self-test: %d ok, %d failed\n' "$ok" "$bad"
  [ "$bad" -eq 0 ]
}

if [ "$selftest" -eq 1 ]; then
  run_self_test "$root"
  exit $?
fi

check "$root"; rc=$?
if [ "$apply" -eq 0 ] || [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then exit "$rc"; fi

apply_all "$root" || exit 1
echo "-- after apply"
check "$root"
exit $?
