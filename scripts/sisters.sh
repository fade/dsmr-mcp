#!/usr/bin/env bash
#
# Start a fleet, named by the leader that holds it.
#
# The point of this wrapper is that each fleet's invocation lives in one place
# instead of being retyped from memory. Getting it wrong does not fail cleanly:
# the wrong --dir or a mistyped --extra brings up a partial fleet that looks
# like a whole one, and the missing sister is only noticed later by its silence.
#
#   sisters.sh <leader>          start that fleet
#   sisters.sh <leader> <any>    show what that would do, and do nothing
#   sisters.sh                   list the fleets named here, and do nothing
#
# Any argument after the leader means show-me. That is deliberate: this is the
# safety hatch, so it should never depend on spelling a particular flag
# correctly.
#
# There is more than one fleet now, so the leader is required rather than
# defaulted. A bare run used to start valis; it now lists and does nothing,
# because picking a fleet by habit is the mistake this file exists to prevent.

set -euo pipefail

# This file is deployed onto PATH, so it cannot find the launcher by sitting
# next to it. The default names the checkout this script is maintained in;
# override it when running against a clone somewhere else.
LAUNCHER=${DSMR_START_SISTERS:-~/SourceCode/lisp/dsmr-mcp/scripts/start-sisters.sh}

# The host check runs before anything starts. A fleet brought up on a host that
# was never provisioned does not fail: it comes up healthy-looking and unable to
# act, and it took four agents measuring separately to notice. Set
# DSMR_SKIP_PREFLIGHT=1 to launch anyway; the hatch is here because a check that
# can block the only entry point must be one you can get past.
PREFLIGHT=${DSMR_PREFLIGHT:-~/SourceCode/lisp/dsmr-mcp/scripts/preflight.sh}

usage() {
    cat >&2 <<'USAGE_EOF'
sisters.sh: name the fleet to start, by its leader.

  sisters.sh valis           the peer fleet, in SourceCode/lisp/DeepSkyV2
  sisters.sh dsmr-mcp        the tooling fleet, in SourceCode/lisp

Add any second argument to see what a run would do without starting anything:

  sisters.sh valis show
USAGE_EOF
}

leader=${1-}

# Each fleet names its own directory and its own launcher arguments. The
# stagger is spelled out per fleet rather than left to the launcher's default:
# the gap between sessions is what keeps a bring-up from arriving as a burst,
# and a default can be changed by someone editing the launcher for another
# reason; written here it changes only when these lines change.
#
# shellcheck disable=SC2054  # a comma-separated list is ONE argument to --extra
case $leader in
    valis)
        # DeepSkyV2 is a curated directory: everything in it is a member, so
        # scanning it is safe. boomer, zebra and xxx-pure-tls live outside it.
        #
        # Whistler joined 2026-09-05 and is spelled with a CAPITAL W. That is
        # the whole reason it took this long to arrive: it is named in
        # CONSTELLATION.org as a member, and the leader's roster sweep matched
        # lowercase names only, so a declared member was invisible to every
        # bring-up and the roster read as complete. Bare --extra names resolve
        # against $LISP_WORKSPACE, so the case here must match the directory on
        # disk exactly or the launcher dies naming it.
        FLEET_DIR=~/SourceCode/lisp/DeepSkyV2
        args=(--extra zebra,Whistler --exclude meta-bridge --stagger 3-10)
        # Named for the host check, which needs to know whose .envrc consent to
        # verify. The scanned members are added below; these are the ones that
        # live outside FLEET_DIR and so cannot be found by looking.
        MEMBERS=(zebra Whistler)
        SCAN_MEMBERS=1
        EXCLUDE_MEMBER=meta-bridge
        ;;
    dsmr-mcp)
        # The --no-scan here is required and is not a tuning choice. This
        # fleet's repositories sit in $LISP_WORKSPACE alongside a dozen that are
        # NOT members: dependency forks and retired checkouts carry .git and
        # .planning too, so a scan of this directory proposes all of them and
        # labels every one a worker. Membership is declared below, never found.
        FLEET_DIR=~/SourceCode/lisp
        args=(--no-scan --extra dsmr-mcp,mallet,boomer,xxx-pure-tls,sbcl --stagger 3-10)
        # Membership is declared, never found, for the same reason --no-scan is
        # set: this directory holds a dozen non-members that carry .git and
        # .planning too. Consenting to their .envrc files would be exactly the
        # blanket trust the host check is written to avoid.
        MEMBERS=(dsmr-mcp mallet boomer xxx-pure-tls sbcl)
        SCAN_MEMBERS=0
        EXCLUDE_MEMBER=
        ;;
    '')
        usage
        exit 1
        ;;
    *)
        printf 'sisters.sh: no fleet named %s\n\n' "$leader" >&2
        usage
        exit 1
        ;;
esac

# Naming the leader on the command line makes it an assertion, so a leader the
# filters exclude is an error rather than a note. A fleet coming up with no
# leader is the failure worth being loud about: every sister reports into
# nothing and reads as quiet rather than unheard.
args+=(--leader "$leader")

[[ -x $LAUNCHER ]] || { printf 'sisters.sh: launcher missing or not executable: %s\n' "$LAUNCHER" >&2; exit 1; }
[[ -d $FLEET_DIR ]] || { printf 'sisters.sh: fleet directory missing: %s\n' "$FLEET_DIR" >&2; exit 1; }

if (($# > 1)); then
    args+=(--dry-run)
    printf 'sisters.sh: DRY RUN of fleet %s, nothing will be started\n\n' "$leader"
fi

# A scanning fleet's members are whatever sits in its curated directory, so the
# host check is handed the same set the launcher will start rather than a second
# list that can drift from it.
if ((SCAN_MEMBERS)); then
    for d in "$FLEET_DIR"/*/; do
        n=$(basename "$d")
        [[ -d $d/.git && $n != "$EXCLUDE_MEMBER" ]] && MEMBERS+=("$n")
    done
fi

if [[ -x $PREFLIGHT && ${DSMR_SKIP_PREFLIGHT:-0} != 1 ]]; then
    preflight_args=(--fleet-dir "$FLEET_DIR")
    for n in "${MEMBERS[@]}"; do preflight_args+=(--repo "$n"); done
    # A dry run inspects and never changes anything, host included.
    (($# > 1)) && preflight_args+=(--check-only)
    if ! "$PREFLIGHT" "${preflight_args[@]}"; then
        printf '\nsisters.sh: host check failed, so fleet %s was NOT started.\n' "$leader" >&2
        printf 'Clear the items above, or set DSMR_SKIP_PREFLIGHT=1 to launch anyway.\n' >&2
        exit 1
    fi
    printf '\n'
elif [[ ${DSMR_SKIP_PREFLIGHT:-0} == 1 ]]; then
    printf 'sisters.sh: host check SKIPPED by DSMR_SKIP_PREFLIGHT=1\n\n' >&2
else
    printf 'sisters.sh: no host check at %s; starting unchecked\n\n' "$PREFLIGHT" >&2
fi

cd -- "$FLEET_DIR"
"$LAUNCHER" "${args[@]}"

# Only reached on a real start. The launcher reports skips in one line among
# many, and a skipped repository is a sister that did not start, so say it again
# here where it is the last thing on screen.
if (($# == 1)); then
    printf '\nRead the lines above for "skip": a skipped repository did NOT start.\n'
    printf 'Then confirm the fleet by rollcall, not by counting tabs.\n'
fi
