#!/usr/bin/env bash
# gsd-routing-gate.sh [--root DIR] [--apply]
#
# Report whether gsd-core's per-plan executor routing step carries the project
# executor default patch. ROOT defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
# The patch is read from ../patches/gsd-core/ relative to this script.
#
# Exit status:
#   0  patch present (or applied by --apply)
#   1  patch missing; with --apply, the patch did not apply and nothing changed
#   2  gsd-core is not installed under ROOT
set -u

root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "usage: $0 [--root DIR] [--apply]" >&2; exit 64; }; root=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    -h|--help) echo "usage: $0 [--root DIR] [--apply]"; exit 0 ;;
    *) echo "usage: $0 [--root DIR] [--apply]" >&2; exit 64 ;;
  esac
done

rel=gsd-core/workflows/execute-phase/steps/per-plan-executor-routing.md
target=$root/$rel
patch_file=$(dirname "$(readlink -f "$0")")/../patches/gsd-core/per-plan-executor-routing.patch

has_markers() {
  grep -qF 'dsmr-local: project executor default' "$target" &&
    grep -qF 'planning.agents.executor' "$target"
}

if [ ! -f "$target" ]; then
  echo "gsd-core absent at $target"
  exit 2
fi

if has_markers; then
  echo "Lisp routing patch present"
  exit 0
fi

echo "Lisp routing patch missing: $target"
[ "$apply" -eq 1 ] || exit 1

if [ ! -f "$patch_file" ]; then
  echo "patch file not found: $patch_file"
  exit 1
fi

# Dry run first: a hunk that no longer applies leaves the target untouched.
if ! out=$(patch -p1 --forward --dry-run -d "$root" < "$patch_file" 2>&1); then
  printf '%s\n' "$out"
  echo "patch does not apply cleanly; nothing changed"
  exit 1
fi

if ! out=$(patch -p1 --forward -b -z .pre-lisp-routing -d "$root" < "$patch_file" 2>&1); then
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out"

if has_markers; then
  echo "Lisp routing patch present"
  exit 0
fi
echo "Lisp routing patch missing after apply: $target"
exit 1
