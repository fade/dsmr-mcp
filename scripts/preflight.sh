#!/usr/bin/env bash
#
# Check that this host can actually run a fleet, and establish what is safe to
# establish, before any session starts.
#
# I wrote this after starting both fleets on a new machine for the first time.
# Every instrument said healthy: the roster was green, every park sha matched
# live HEAD, every watcher answered `live` on the right bus. Thirteen agents
# came up and not one of them could publish a message, edit a line of Lisp or
# run a test, because the MCP server was not registered on the host and the
# prebuilt core had been built on a different machine. It took four agents
# measuring independently to see it, and the first diagnosis was wrong.
#
# The lesson is not that provisioning was missing. It is that a first run on an
# unprovisioned host SUCCEEDS INTO a fleet that cannot act, and nothing in the
# normal bring-up can tell that from a healthy one. So the job here is to make
# that case fail loudly at the start. Installing things is a convenience on top.
#
#   preflight.sh                          check the host, establish what is safe
#   preflight.sh --check-only             report only, change nothing
#   preflight.sh --fleet-dir D --repo N   also check repo N's direnv consent
#   preflight.sh --self-test              prove every check can report red
#
# Exit status is the contract: 0 means a fleet may start, non-zero means it may
# not. `sisters.sh` refuses to launch on a non-zero answer.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CORE="$REPO_ROOT/dsmr.core"
LAUNCHER="$REPO_ROOT/scripts/dsmr-mcp-launch.sh"
CONSTELLATION="$REPO_ROOT/docs/CONSTELLATION.org"

CHECK_ONLY=0
SELF_TEST=0
FLEET_DIR=""
REPOS=()

# What the run found. `blocked` is the only one that decides the exit status;
# `established` and `noted` are reported so a silent success is still legible.
established=()
blocked=()
noted=()

say()   { printf '  %s\n' "$*"; }
head2() { printf '\n%s\n' "$*"; }

ok()    { established+=("$1"); printf '  ok        %s\n' "$1"; }
fixed() { established+=("$1"); printf '  ESTABLISH %s\n' "$1"; }
note()  { noted+=("$1");       printf '  note      %s\n' "$1"; }
bad()   { blocked+=("$1|$2");  printf '  BLOCKED   %s\n' "$1"; printf '            remedy: %s\n' "$2"; }

while (($#)); do
    case $1 in
        --check-only) CHECK_ONLY=1 ;;
        --self-test)  SELF_TEST=1 ;;
        --fleet-dir)  FLEET_DIR=${2-}; shift ;;
        --repo)       REPOS+=("${2-}"); shift ;;
        -h|--help)    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'preflight.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Binaries. Present is not the same as reachable, and the difference is not
# cosmetic: roswell installs qlot into ~/.roswell/bin, so a correct `ros install
# fukamachi/qlot` leaves a working qlot that no shell can find. That reads as
# "not installed" to every caller and as "installed" to the person who installed
# it, and nothing reports the disagreement until a suite fails with status 127.
# ---------------------------------------------------------------------------
check_binaries() {
    head2 "Binaries"
    local name path remedy
    # Each entry is name:remedy. A remedy is a command the operator can paste,
    # never a description of one.
    for entry in \
        "sbcl:build or install SBCL, then re-run" \
        "git:sudo pacman -S git" \
        "make:sudo pacman -S make" \
        "direnv:sudo pacman -S direnv" \
        "gh:sudo pacman -S github-cli" \
        "qlot:sudo pacman -S roswell && ros install fukamachi/qlot"
    do
        name=${entry%%:*}; remedy=${entry#*:}
        if path=$(command -v "$name" 2>/dev/null); then
            ok "$name -> $path"
            continue
        fi
        # Found on disk but not on PATH is a different failure with a different
        # remedy, so say which one it is rather than reporting a bare absence.
        local found=""
        for cand in "$HOME/.roswell/bin/$name" "$HOME/.local/bin/$name" "/usr/local/bin/$name"; do
            [ -x "$cand" ] && { found=$cand; break; }
        done
        if [ -n "$found" ]; then
            bad "$name is installed at $found but is not on PATH" \
                "add $(dirname "$found") to PATH in your shell profile"
        else
            bad "$name not found" "$remedy"
        fi
    done
}

# ---------------------------------------------------------------------------
# The MCP server. This check cannot ever become an MCP verb: if the answer is
# no, the verb does not exist to be called. It stays shell permanently, and so
# does the core check below it.
# ---------------------------------------------------------------------------
check_mcp() {
    head2 "MCP server"
    if ! command -v claude >/dev/null 2>&1; then
        bad "claude CLI not found, so the server cannot be registered" \
            "install Claude Code, then re-run"
        return
    fi
    if claude mcp list 2>/dev/null | grep -q '^dsmr-mcp:'; then
        ok "dsmr-mcp registered"
        return
    fi
    if ((CHECK_ONLY)); then
        bad "dsmr-mcp is not registered, so no session gets bus, Lisp or test verbs" \
            "make preflight (without --check-only), or claude mcp add dsmr-mcp --scope user ..."
        return
    fi
    # User scope on purpose: one entry serves every project and therefore every
    # fleet on the host. Registering per project is the version of this that
    # looks right and has to be redone for each repo anyone adds.
    if claude mcp add dsmr-mcp --scope user \
           -e DSMR_MODE=auto -e DSMR_TRANSPORT=stdio \
           -- "$LAUNCHER" >/dev/null 2>&1
    then
        fixed "registered dsmr-mcp at user scope (serves every fleet on this host)"
        note "already-running sessions do NOT pick this up; they need a restart"
    else
        bad "could not register dsmr-mcp" \
            "claude mcp add dsmr-mcp --scope user -e DSMR_MODE=auto -e DSMR_TRANSPORT=stdio -- $LAUNCHER"
    fi
}

# ---------------------------------------------------------------------------
# The core. Verify that it BOOTS; never rebuild it here.
#
# The launcher decides staleness from the recorded sbcl-version, which cannot
# tell one host's SBCL from another's of the same version. A core carried over
# on a synced $HOME therefore grades FRESH, gets exec'd, and dies on SBCL's
# runtime-identity check, with the source-load fallback and the background
# rebuild both sitting in the branch that never runs. That is a permanent
# hard-down that repeats identically on every start.
#
# Booting it is the only honest test, because a freshness check is a prediction
# and the class of cores that pass one and then die is not empty: a truncated
# image and an interrupted `make core` land in exactly the same place.
#
# Rebuilding is deliberately NOT done here. `make core` takes minutes and bakes
# whatever is checked out into the deployed image, so a preflight that rebuilt
# on every launch would silently ship a mid-work feature branch to the fleet.
# ---------------------------------------------------------------------------
check_core() {
    head2 "Prebuilt core"
    if [ ! -f "$CORE" ]; then
        note "no core at $CORE; the launcher will source-load, which is slower but correct"
        return
    fi
    local err
    err=$(sbcl --core "$CORE" --noinform --disable-debugger --no-userinit --eval '(quit)' 2>&1)
    if (($? == 0)); then
        ok "core boots on this host"
        return
    fi
    if grep -q 'core was built for runtime' <<<"$err"; then
        bad "core at $CORE was built by a different SBCL than this host's" \
            "make core"
        say "  $(grep -o 'core was built for runtime.*' <<<"$err" | head -1)"
    else
        bad "core at $CORE does not boot" "make core"
    fi
}

# ---------------------------------------------------------------------------
# direnv consent.
#
# A repo's .envrc is what sets DSMR_BUS_SELECTOR and DSMR_BUS_AGENT, so a sister
# without consent has no bus identity. The launcher starts each session under
# `direnv exec`, which FAILS CLOSED on an unconsented .envrc: it refuses with a
# non-zero status rather than running with an empty environment. So the sister
# does not start, and nothing comes up on the wrong bus by this route.
#
# That is the correct behaviour and it is why this check is about toil and a
# legible message rather than about silent corruption. I first wrote the comment
# here the other way round, claiming a sister would arm quietly on the shared
# host-wide bus, and measured it afterwards: it does not. What actually happens
# is that a first run on a new host stops one repo at a time, and the operator
# visits thirteen terminals to clear it by hand.
#
# ⚠ The quiet-wrong-bus case is real but narrower than that: it needs a watcher
# armed from a shell that never loaded direnv, where an unset selector takes the
# watcher's documented default of the shared host-wide bus. `direnv exec` is not
# that path.
#
# Consent is granted only for repositories NAMED on the fleet's map or passed in
# by the caller. `direnv allow` is a trust gate, and allowing every .envrc found
# on the disk would delete the gate rather than satisfy it. Each grant is
# printed, so a run that consents to something is a run that says so.
#
# A repo whose .envrc CHANGED since it was last allowed is refused, not
# re-allowed: direnv blocking on an edit is the gate working, and quietly
# re-consenting would suppress the one signal it exists to raise. Telling the
# two apart needs a record of what was allowed before, which this keeps beside
# direnv's own store.
# ---------------------------------------------------------------------------
SEEN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/preflight/consented"

# Answer for the directory ASKED ABOUT, which is harder than it looks.
#
# `direnv status` prints two separate blocks. "Loaded RC" is whatever the
# CALLING shell already has loaded, which on any run started from a project
# directory is a DIFFERENT .envrc that is almost always allowed. "Found RC" is
# the one at the directory being asked about. Matching `allowed 0` loosely picks
# up the caller's own consent and reports every target as allowed, including
# targets that have never been consented to at all.
#
# I shipped exactly that bug here and the self-test caught it. So: read only the
# Found block, and require its path to be the .envrc asked for, because a
# directory with no .envrc of its own reports an ancestor's under the same
# heading.
envrc_allowed() {
    local dir=$1 want status
    want="$(cd "$dir" 2>/dev/null && pwd)/.envrc"
    status=$( cd "$dir" 2>/dev/null && direnv status 2>/dev/null ) || return 1
    [ "$(grep -m1 '^Found RC path ' <<<"$status" | cut -d' ' -f4-)" = "$want" ] || return 1
    [ "$(grep -m1 '^Found RC allowed ' <<<"$status" | awk '{print $4}')" = "0" ]
}

check_direnv_consent() {
    head2 "direnv consent"
    local candidates=() d name
    for name in "${REPOS[@]:-}"; do
        [ -n "$name" ] || continue
        if [ -d "$name" ]; then d=$name
        elif [ -n "$FLEET_DIR" ] && [ -d "$FLEET_DIR/$name" ]; then d="$FLEET_DIR/$name"
        elif [ -d "${LISP_WORKSPACE:-$HOME/SourceCode/lisp}/$name" ]; then
            d="${LISP_WORKSPACE:-$HOME/SourceCode/lisp}/$name"
        else
            bad "repo named for this fleet does not exist on disk: $name" \
                "correct the fleet's member list, or clone it"
            continue
        fi
        candidates+=("$(cd "$d" && pwd)")
    done

    if ((${#candidates[@]} == 0)); then
        note "no repositories named, so nothing to consent to (pass --repo)"
        return
    fi

    mkdir -p "$SEEN_DIR" 2>/dev/null
    for d in "${candidates[@]}"; do
        name=$(basename "$d")
        if [ ! -f "$d/.envrc" ]; then
            note "$name has no .envrc, so it carries no bus identity of its own"
            continue
        fi
        local stamp="$SEEN_DIR/$(printf '%s' "$d" | sha256sum | cut -c1-32)"
        local now; now=$(sha256sum "$d/.envrc" | cut -d' ' -f1)

        if envrc_allowed "$d"; then
            ok "$name .envrc allowed"
            printf '%s %s\n' "$now" "$d" > "$stamp"
            continue
        fi
        # Not allowed. Whether that is a first run or a changed file decides
        # whether consenting is safe, and only a prior record can tell them
        # apart.
        if [ -f "$stamp" ] && [ "$(cut -d' ' -f1 "$stamp")" != "$now" ]; then
            bad "$name .envrc CHANGED since it was last consented to" \
                "read the diff, then run: direnv allow $d"
            continue
        fi
        if ((CHECK_ONLY)); then
            bad "$name .envrc has no consent, so that sister would arm on the wrong bus" \
                "direnv allow $d"
            continue
        fi
        if direnv allow "$d" >/dev/null 2>&1; then
            fixed "consented to $name .envrc ($d)"
            printf '%s %s\n' "$now" "$d" > "$stamp"
        else
            bad "could not consent to $name .envrc" "direnv allow $d"
        fi
    done
}

# ---------------------------------------------------------------------------
# Prove the checks can report red.
#
# A checker that cannot fail reports the same clean answer whether the host is
# healthy or the check is broken, and this whole file exists because a green
# reading was believed once already. Each case below plants a condition and
# asserts the corresponding check reports it, so a clean preflight is a
# measurement rather than a hope.
# ---------------------------------------------------------------------------
self_test() {
    local tmp status=0
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    printf 'proving each check can report red\n'

    # A binary that cannot exist.
    if PATH=/nonexistent command -v sbcl >/dev/null 2>&1; then
        printf '  FAIL  binary check did not notice an empty PATH\n'; status=1
    else printf '  pass  binary check fires on a missing binary\n'; fi

    # A core that is not a core.
    printf 'not a core' > "$tmp/fake.core"
    if sbcl --core "$tmp/fake.core" --noinform --disable-debugger --no-userinit \
            --eval '(quit)' >/dev/null 2>&1; then
        printf '  FAIL  core check accepted a file that is not a core\n'; status=1
    else printf '  pass  core check fires on an unbootable image\n'; fi

    # A directory whose .envrc has never been consented to.
    mkdir -p "$tmp/repo"; printf 'export PREFLIGHT_SELF_TEST=1\n' > "$tmp/repo/.envrc"
    if envrc_allowed "$tmp/repo"; then
        printf '  FAIL  consent check called an unconsented .envrc allowed\n'; status=1
    else printf '  pass  consent check fires on an unconsented .envrc\n'; fi

    # And the same check must say yes when consent IS present, or it is stuck
    # on no and proves nothing.
    if direnv allow "$tmp/repo" >/dev/null 2>&1 && envrc_allowed "$tmp/repo"; then
        printf '  pass  consent check answers yes once consent is given\n'
    else
        printf '  FAIL  consent check cannot report an allowed .envrc\n'; status=1
    fi
    direnv deny "$tmp/repo" >/dev/null 2>&1

    # The roster extractor must match this repo's table format, and must not be
    # case-blind. Whistler is spelled with a capital and was invisible to a
    # lowercase pattern for months.
    if [ -f "$CONSTELLATION" ]; then
        local n
        n=$(grep -cE '^\| *[A-Za-z0-9-]+ *\|' "$CONSTELLATION")
        if ((n > 0)); then printf '  pass  roster extractor matches %d rows in CONSTELLATION.org\n' "$n"
        else printf '  FAIL  roster extractor matched 0 rows; it cannot report a missing member\n'; status=1; fi
    fi

    return $status
}

if ((SELF_TEST)); then
    self_test; exit $?
fi

printf 'preflight: host %s\n' "$(hostname)"
check_binaries
check_mcp
check_core
check_direnv_consent

head2 "Summary"
printf '  established %d, noted %d, blocked %d\n' \
       "${#established[@]}" "${#noted[@]}" "${#blocked[@]}"

if ((${#blocked[@]})); then
    printf '\nThis host is not ready and no fleet should start on it.\n'
    printf 'Outstanding:\n'
    for b in "${blocked[@]}"; do
        printf '  - %s\n' "${b%%|*}"
        printf '      %s\n' "${b#*|}"
    done
    exit 1
fi

printf '\nHost is ready.\n'
exit 0
