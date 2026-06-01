#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/measure-phases.sh
#
# Phase-attributable profiling harness for the dsmr-mcp test suite.
#
# Emits four separate wall-clock numbers so a slow run can be attributed to
# the stage that owns the cost rather than reported as one opaque total:
#
#   setup    Quicklisp / ASDF bootstrap load (require :asdf + setup.lisp)
#   compile  asdf:load-system "dsmr-mcp"        (deps + system compiled+loaded)
#   leaves   asdf:load-system "dsmr-mcp/tests"  (the 65 test leaves loaded)
#   exec     asdf:test-system "dsmr-mcp/tests"  (assertions actually run)
#
# Each stage is timed by a separate fresh sbcl process so its cost is isolated;
# the cumulative loads upstream of a stage are re-paid inside that stage's
# process, so read the numbers as "wall-clock to reach the END of this stage
# from a cold image", and the per-stage marginal cost as the delta between
# consecutive stages.
#
# Cache isolation: by default the harness points XDG_CACHE_HOME at a fresh
# project-local temp dir, so a cold profiling run NEVER writes to or reads from
# the shared system cache (~/.cache/common-lisp). That shared cache is built
# with MARK-REGION-GC on this box; a naive fresh run against it can crash with
# INVALID-FASL-FEATURES when the running sbcl's GC flavor differs. Isolation
# sidesteps that hazard entirely and guarantees the "cold" numbers are genuinely
# cold (no warm fasls leaking in).
#
# Usage:
#   scripts/measure-phases.sh            # cold: fresh isolated cache, recompile
#   scripts/measure-phases.sh --warm     # warm: reuse the populated cache
#   scripts/measure-phases.sh --help
#
# Env (all optional):
#   SBCL             sbcl binary               (default: sbcl on PATH)
#   LISP_WORKSPACE   local-projects tree       (default ~/SourceCode/lisp/)
#   QUICKLISP_SETUP  quicklisp setup.lisp      (default ~/quicklisp/setup.lisp)
#   MEASURE_CACHE    cache dir to use/reuse     (default: a fresh mktemp dir)
#
# All diagnostic output goes to stderr; the machine-readable
#   phase=<name> seconds=<n>
# lines also go to stderr so the harness can be piped without a separate
# capture channel.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SBCL="${SBCL:-sbcl}"
LISP_WORKSPACE="${LISP_WORKSPACE:-${HOME}/SourceCode/lisp}"
QUICKLISP_SETUP="${QUICKLISP_SETUP:-${HOME}/quicklisp/setup.lisp}"

# Defensive tilde expansion. Some shell rc files set these to a literal
# '~/...' string (no expansion at assignment time); an unexpanded tilde
# survives [ -d ] as a non-directory and confuses asdf's source-registry.
LISP_WORKSPACE="${LISP_WORKSPACE/#\~/$HOME}"
QUICKLISP_SETUP="${QUICKLISP_SETUP/#\~/$HOME}"
LISP_WORKSPACE="${LISP_WORKSPACE%/}"

WARM=0
for arg in "$@"; do
  case "$arg" in
    --warm) WARM=1 ;;
    --help|-h)
      sed -n '4,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- Pre-flight checks ------------------------------------------------------

if ! command -v "$SBCL" >/dev/null 2>&1; then
  echo "ERROR: sbcl not found (looked for '$SBCL'; set SBCL to override)" >&2
  exit 1
fi

if [ ! -f "$QUICKLISP_SETUP" ]; then
  echo "ERROR: quicklisp setup.lisp not found at $QUICKLISP_SETUP" >&2
  echo "       (set QUICKLISP_SETUP env var to override)" >&2
  exit 1
fi

if [ ! -d "$LISP_WORKSPACE" ]; then
  echo "ERROR: LISP_WORKSPACE=$LISP_WORKSPACE does not exist" >&2
  exit 1
fi

if [ ! -f "$PROJECT_ROOT/dsmr-mcp.asd" ]; then
  echo "ERROR: dsmr-mcp.asd not found at $PROJECT_ROOT — is this the project root?" >&2
  exit 1
fi

# --- Cache isolation --------------------------------------------------------

# A fresh per-run cache for cold; a stable reused cache for --warm.
if [ "$WARM" -eq 1 ]; then
  CACHE_DIR="${MEASURE_CACHE:-${PROJECT_ROOT}/.measure-cache}"
  CACHE_OWNED=0
  if [ ! -d "$CACHE_DIR" ]; then
    echo "WARN: --warm but $CACHE_DIR does not exist; the first run will be cold." >&2
    mkdir -p "$CACHE_DIR"
  fi
else
  if [ -n "${MEASURE_CACHE:-}" ]; then
    CACHE_DIR="$MEASURE_CACHE"
    CACHE_OWNED=0
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
  else
    CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsmr-measure.XXXXXX")"
    CACHE_OWNED=1
  fi
fi

export XDG_CACHE_HOME="$CACHE_DIR"
export LISP_WORKSPACE QUICKLISP_SETUP

cleanup() {
  if [ "${CACHE_OWNED:-0}" -eq 1 ] && [ -n "${CACHE_DIR:-}" ]; then
    rm -rf "$CACHE_DIR"
  fi
}
trap cleanup EXIT

echo "[measure] sbcl            : $SBCL ($("$SBCL" --version 2>/dev/null || echo '?'))" >&2
echo "[measure] mode            : $([ "$WARM" -eq 1 ] && echo warm || echo cold)" >&2
echo "[measure] XDG_CACHE_HOME  : $XDG_CACHE_HOME" >&2
echo "[measure] LISP_WORKSPACE  : $LISP_WORKSPACE" >&2
echo "[measure] QUICKLISP_SETUP : $QUICKLISP_SETUP" >&2

# --- Source registry --------------------------------------------------------

# Point ASDF at the local checkouts the same way the dev runner does: a
# recursive source-registry rooted at LISP_WORKSPACE plus the project root.
export CL_SOURCE_REGISTRY="(:source-registry (:tree \"${LISP_WORKSPACE}/\") (:directory \"${PROJECT_ROOT}/\") :inherit-configuration)"

# --- Per-stage timing -------------------------------------------------------

# Run a single sbcl process whose body is the supplied --eval forms, and print
# a phase=<name> seconds=<n> line. All sbcl stdout/stderr is redirected to a
# per-stage log so the harness's own output stays clean; the log path is
# reported so a failing stage can be inspected.
run_stage() {
  local name="$1"; shift
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/dsmr-measure-${name}.XXXXXX.log")"

  local start end secs
  start="$(date +%s.%N)"
  # Each stage loads quicklisp first (the setup cost is intrinsic to every
  # downstream stage), then runs the stage-specific forms.
  if "$SBCL" --noinform --disable-debugger --non-interactive \
       --eval '(require :asdf)' \
       --load "$QUICKLISP_SETUP" \
       "$@" >"$log" 2>&1; then
    end="$(date +%s.%N)"
    secs="$(awk "BEGIN{printf \"%.1f\", $end - $start}")"
    echo "phase=${name} seconds=${secs}" >&2
  else
    end="$(date +%s.%N)"
    secs="$(awk "BEGIN{printf \"%.1f\", $end - $start}")"
    echo "phase=${name} seconds=${secs} STATUS=failed log=${log}" >&2
    echo "[measure] stage '${name}' FAILED — see ${log}" >&2
    tail -n 20 "$log" >&2 || true
    return 1
  fi
  rm -f "$log"
}

# setup: pay only the quicklisp/asdf bootstrap. The --load of setup.lisp is
# already in run_stage; this stage runs no further forms.
run_stage setup

# compile: load the system (deps + dsmr-mcp compiled and loaded).
run_stage compile \
  --eval '(asdf:load-system "dsmr-mcp")'

# leaves: load the test umbrella (all 65 test leaves compiled and loaded).
run_stage leaves \
  --eval '(asdf:load-system "dsmr-mcp/tests")'

# exec: run the assertions. The :perform errors on any failed leaf, which under
# --disable-debugger --non-interactive exits non-zero (reported STATUS=failed).
run_stage exec \
  --eval '(asdf:load-system "dsmr-mcp/tests")' \
  --eval '(asdf:test-system "dsmr-mcp/tests")'

echo "[measure] done." >&2
