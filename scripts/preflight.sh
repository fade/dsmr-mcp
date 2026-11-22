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
# prebuilt core had been built on a different machine. It took independent
# measurements from several directions to see it at all, and the first diagnosis
# was wrong.
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
#   preflight.sh --check-release          run only the deployed-release check
#
# Exit status is the contract: 0 means a fleet may start, non-zero means it may
# not. `sisters.sh` refuses to launch on a non-zero answer.
#
# DSMR_HOME, SBCL, QLOT and CLAUDE_CONFIG are read as the Makefile reads them.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CONSTELLATION="$REPO_ROOT/docs/CONSTELLATION.org"

# dsmr_home, physical_dir, inside_work_tree and release_refusal: the checks the
# release launcher and `make register` refuse with, so preflight cannot pass a
# release either would refuse.
# shellcheck source=release-paths.sh
. "$REPO_ROOT/scripts/release-paths.sh"

CHECK_ONLY=0
SELF_TEST=0
RELEASE_ONLY=0
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
        --check-release) RELEASE_ONLY=1 ;;
        --fleet-dir)  FLEET_DIR=${2-}; shift ;;
        --repo)       REPOS+=("${2-}"); shift ;;
        -h|--help)    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'preflight.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Binaries. Present is not the same as reachable: a tool installed into a
# directory that is not on PATH reads as "not installed" to every caller and as
# "installed" to the person who installed it, so that case is reported with its
# own remedy. qlot is the exception: a deploy runs it by path, never from PATH,
# so the check is that the path the Makefile uses is executable.
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
        "jq:sudo pacman -S jq"
    do
        name=${entry%%:*}; remedy=${entry#*:}
        if path=$(command -v "$name" 2>/dev/null); then
            ok "$name -> $path"
            continue
        fi
        local found=""
        for cand in "$HOME/.local/bin/$name" "/usr/local/bin/$name"; do
            [ -x "$cand" ] && { found=$cand; break; }
        done
        if [ -n "$found" ]; then
            bad "$name is installed at $found but is not on PATH" \
                "add $(dirname "$found") to PATH in your shell profile"
        else
            bad "$name not found" "$remedy"
        fi
    done
    local workspace=${LISP_WORKSPACE:-$HOME/SourceCode/lisp}
    local qlot=${QLOT:-$workspace/qlot/bin/qlot}
    if [ -x "$qlot" ]; then
        ok "qlot -> $qlot"
    else
        bad "qlot not found at $qlot, so make deploy cannot take its dependencies" \
            "clone fade/qlot into $workspace/qlot, then run LISP=sbcl scripts/setup.sh there"
    fi
}

# ---------------------------------------------------------------------------
# The MCP server. This check cannot become an MCP verb: when the answer is no,
# the verb does not exist to be called.
#
# The registration names <DSMR_HOME>/current/bin/dsmr-mcp-launch, the release
# launcher through current, so a deploy or rollback needs no new registration.
# A registration that names a launcher inside a git work tree starts the server
# from a checkout and is blocked.
# ---------------------------------------------------------------------------

# registered_command
# Print the command of the user-scope dsmr-mcp entry in
# ${CLAUDE_CONFIG:-$HOME/.claude.json}, or nothing when there is none or jq
# cannot read the file.
registered_command() {
    jq -r '.mcpServers["dsmr-mcp"].command // empty' \
       "${CLAUDE_CONFIG:-$HOME/.claude.json}" 2>/dev/null
}

# registration_problem COMMAND
# Print a reason and return 1 when COMMAND's physical directory is inside a git
# work tree; print nothing and return 0 otherwise.
registration_problem() {
    local command=$1 dir
    dir=$(physical_dir "$(dirname "$(readlink -f "$command" 2>/dev/null || printf '%s' "$command")")") \
        || return 0
    if inside_work_tree "$dir"; then
        printf 'dsmr-mcp is registered at %s, inside a checkout\n' "$command"
        return 1
    fi
    return 0
}

check_mcp() {
    head2 "MCP server"
    local home launcher command problem
    home=$(dsmr_home) || { bad "no deploy home can be named" "set HOME, or DSMR_HOME to an absolute path"; return; }
    launcher="$home/current/bin/dsmr-mcp-launch"
    if ! command -v claude >/dev/null 2>&1; then
        bad "claude CLI not found, so the server cannot be registered" \
            "install Claude Code, then re-run"
        return
    fi
    if claude mcp list 2>/dev/null | grep -q '^dsmr-mcp:'; then
        command=$(registered_command)
        if [ -z "$command" ]; then
            note "dsmr-mcp is registered, but no user-scope command was read from ${CLAUDE_CONFIG:-$HOME/.claude.json}"
        elif problem=$(registration_problem "$command"); then
            ok "dsmr-mcp registered at $command"
        else
            bad "${problem%$'\n'}" "make register"
        fi
        return
    fi
    if [ ! -x "$launcher" ]; then
        bad "no deployed release; registering would name a missing launcher" \
            "make deploy REF=<sha>, then make register"
        return
    fi
    if ((CHECK_ONLY)); then
        bad "dsmr-mcp is not registered, so no session gets bus, Lisp or test verbs" \
            "make register"
        return
    fi
    # `claude mcp add` writes the CLI's own config, $HOME/.claude.json: only the
    # account's own release goes there, and a CLAUDE_CONFIG naming any other
    # file is left to make register, which writes the file it names.
    if ! host_home_p "$home"; then
        bad "deploy home $home is a scratch home; preflight registers only the account's own release" \
            "make register DSMR_HOME=$home CLAUDE_CONFIG=<scratch file>"
        return
    fi
    if [ -n "${CLAUDE_CONFIG:-}" ] && ! host_config_p "$CLAUDE_CONFIG"; then
        bad "CLAUDE_CONFIG is $CLAUDE_CONFIG, which claude mcp add does not write" \
            "make register CLAUDE_CONFIG=$CLAUDE_CONFIG"
        return
    fi
    # User scope on purpose: one entry serves every project and therefore every
    # fleet on the host.
    if claude mcp add dsmr-mcp --scope user \
           -e DSMR_MODE=auto -e DSMR_TRANSPORT=stdio \
           -- "$launcher" >/dev/null 2>&1
    then
        fixed "registered dsmr-mcp at user scope (serves every fleet on this host)"
        note "already-running sessions do NOT pick this up; they need a restart"
    else
        bad "could not register dsmr-mcp" "make register"
    fi
}

# ---------------------------------------------------------------------------
# The deployed release. Checked in two steps, and never rebuilt here.
#
# First release_refusal, the function the release launcher and `make register`
# refuse with: HOME set, no git work tree around the release, ownership and
# write permission of every path the release's code or cores can be replaced
# through (release_path_problem), the core and its manifests present, the
# core's recorded SBCL version equal to the running SBCL's, and a boot probe.
# Then worker_core_withheld, the launcher's own test of the worker core, which a
# deploy always builds, so a withheld one is a failure. Then the release guard,
# booted from the release's own server core with the release root and launcher
# the launcher would pass, which reports any loaded system or launcher tied to
# a checkout or outside the release, and whether the image is sealed.
#
# Booting is the only reliable test. A recorded SBCL version cannot tell one
# build from another of the same version, and a truncated or interrupted image
# passes every file check; only SBCL loading the image catches those. A rebuild
# takes minutes and is a deploy, which the operator runs.
# ---------------------------------------------------------------------------

# release_guard ROOT
# Boot ROOT's server core and print the guard report (release-root, sealed, tie
# and ties lines). Return the guard's status: 0 when green.
release_guard() {
    local root=$1
    DSMR_RELEASE_ROOT="$root/" DSMR_LAUNCHER_PATH="$root/bin/dsmr-mcp-launch" \
        timeout "${DSMR_GUARD_TIMEOUT:-120}" "${SBCL:-sbcl}" --core "$root/core/dsmr.core" \
        --noinform --non-interactive --no-sysinit --no-userinit \
        --eval '(dsmr-mcp/src/release:guard-main)' </dev/null 2>/dev/null
}

# worker_core_remedy PROBLEM
# Print the remedy for a worker_core_withheld reason. A path another user owns
# or others can write is restored in place. Anything else needs a new worker
# core, and the only build is a deploy of a commit with no release yet: a
# deploy of the commit that is current runs the host steps and builds nothing.
worker_core_remedy() {
    case $1 in
        *" is not owned by "*)
            printf 'restore ownership and permissions of %s' "${1% is not owned by *}" ;;
        *" is group or world writable")
            printf 'restore ownership and permissions of %s' "${1% is group or world writable}" ;;
        *)
            printf 'make deploy REF=<sha of a commit that has no release yet>; a commit that already has a release is reused, so its worker core is not rebuilt' ;;
    esac
}

check_release() {
    head2 "Deployed release"
    local home root problem report commit
    home=$(dsmr_home) || { bad "no deploy home can be named" "set HOME, or DSMR_HOME to an absolute path"; return; }
    if [ ! -e "$home/current" ]; then
        bad "no deployed release at $home/current" "make deploy REF=<sha>"
        return
    fi
    if ! root=$(physical_dir "$home/current"); then
        bad "$home/current does not name a directory" "make deploy REF=<sha>"
        return
    fi
    if ! problem=$(release_refusal "$root"); then
        bad "${problem%%; *}" "${problem#*; }"
        return
    fi
    if problem=$(worker_core_withheld "$root"); then
        bad "worker core withheld: $problem; every hermetic worker would refuse to spawn" \
            "$(worker_core_remedy "$problem")"
        return
    fi
    if report=$(release_guard "$root"); then
        commit=$(awk '/^commit /{print $2; exit}' "$root/MANIFEST" 2>/dev/null)
        ok "release ${commit:-$root} boots and is untied"
        say "$(grep -m1 '^ties ' <<<"$report")"
    else
        bad "deployed release $root is tied to a checkout or unsealed" \
            "make deploy REF=<sha> from a clean, pushed commit"
        while IFS= read -r line; do
            case $line in sealed*|tie\ *|ties\ *) say "$line" ;; esac
        done <<<"$report"
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
        local stamp
        stamp="$SEEN_DIR/$(printf '%s' "$d" | sha256sum | cut -c1-32)"
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

    # A deploy home with no release.
    mkdir -p "$tmp/empty-home"
    if DSMR_HOME="$tmp/empty-home" "$0" --check-release >/dev/null 2>&1; then
        printf '  FAIL  release check passed a home with no release\n'; status=1
    else printf '  pass  release check fires on a home with no release\n'; fi

    # A release whose core is not a core, otherwise complete. The launcher's own
    # check must refuse it at the boot probe.
    local rel="$tmp/fake-home/releases/fake"
    mkdir -p "$rel/core" "$rel/bin" "$rel/scripts"
    chmod -R go-w "$tmp/fake-home"
    printf 'not a core' > "$rel/core/dsmr.core"
    printf 'sbcl-version %s\n' "$(running_sbcl_version)" > "$rel/core/dsmr.core.manifest"
    printf 'commit 0000000\n' > "$rel/MANIFEST"
    printf '#!/bin/sh\n' > "$rel/bin/dsmr-mcp-launch"
    : > "$rel/scripts/release-paths.sh"
    chmod -R go-w "$rel"
    local boot_problem
    if boot_problem=$(release_refusal "$rel"); then
        printf '  FAIL  release check accepted a core that does not boot\n'; status=1
    elif [[ $boot_problem != *"does not boot"* ]]; then
        printf '  FAIL  release check refused the unbootable core for another reason: %s\n' "$boot_problem"; status=1
    else printf '  pass  release check fires on a core that does not boot\n'; fi

    # A deploy home others can write is refused by the launcher, so the release
    # check must block it too. The control is the same home with sound
    # permissions passing, which needs a core that boots: a stub SBCL reports
    # the version the manifest records and exits 0 for the probe and the guard.
    local sbin="$tmp/sbcl-bin" dhome="$tmp/deploy-home" drel
    drel="$dhome/releases/r"
    mkdir -p "$sbin" "$drel/core" "$drel/bin" "$drel/scripts"
    printf '#!/bin/sh\ncase " $* " in *" --version "*) echo "SBCL 9.9.9" ;; esac\nexit 0\n' \
        > "$sbin/sbcl"
    chmod +x "$sbin/sbcl"
    printf 'core' > "$drel/core/dsmr.core"
    printf 'sbcl-version 9.9.9\n' > "$drel/core/dsmr.core.manifest"
    printf 'commit 0000000\n' > "$drel/MANIFEST"
    printf '#!/bin/sh\n' > "$drel/bin/dsmr-mcp-launch"
    chmod +x "$drel/bin/dsmr-mcp-launch"
    cp "$REPO_ROOT/scripts/release-paths.sh" "$drel/scripts/release-paths.sh"
    printf 'worker core' > "$drel/core/dsmr.core.worker"
    printf 'sbcl-version 9.9.9\n' > "$drel/core/dsmr.core.worker.manifest"
    ln -s releases/r "$dhome/current"
    chmod -R go-w "$dhome"
    checks_release() {
        SBCL="$sbin/sbcl" DSMR_HOME="$dhome" "$0" --check-release >/dev/null 2>&1
    }
    if checks_release; then
        printf '  pass  release check passes a sound release\n'
    else printf '  FAIL  release check refused a sound release\n'; status=1; fi
    chmod g+w "$dhome"
    if checks_release; then
        printf '  FAIL  release check passed a deploy home others can write\n'; status=1
    else printf '  pass  release check fires on a deploy home others can write\n'; fi
    chmod g-w "$dhome"

    # The launcher also refuses a release root inside a git work tree and an
    # empty HOME, which release_problem alone does not check.
    git init -q "$dhome" 2>/dev/null
    if checks_release; then
        printf '  FAIL  release check passed a release root inside a git work tree\n'; status=1
    else printf '  pass  release check fires on a release root inside a git work tree\n'; fi
    rm -rf "$dhome/.git"
    if HOME='' checks_release; then
        printf '  FAIL  release check passed with HOME empty\n'; status=1
    else printf '  pass  release check fires with HOME empty\n'; fi

    # A worker core the launcher withholds fails every hermetic spawn: o+w
    # manifest, then no worker core at all.
    local remedy
    chmod o+w "$drel/core/dsmr.core.worker.manifest"
    if checks_release; then
        printf '  FAIL  release check passed a worker core the launcher withholds\n'; status=1
    else printf '  pass  release check fires on a worker core the launcher withholds\n'; fi
    remedy=$(SBCL="$sbin/sbcl" DSMR_HOME="$dhome" "$0" --check-release 2>&1 | grep 'remedy:')
    if [[ $remedy == *"restore ownership and permissions of $drel/core/dsmr.core.worker.manifest"* ]]; then
        printf '  pass  a writable worker manifest names a permission repair\n'
    else printf '  FAIL  a writable worker manifest names no repair: %s\n' "$remedy"; status=1; fi
    chmod o-w "$drel/core/dsmr.core.worker.manifest"
    # A path holding " is " is named whole in the repair.
    local spaced='/srv/this is home/releases/x/core/dsmr.core.worker'
    remedy=$(worker_core_remedy "$spaced is group or world writable")
    if [[ $remedy == "restore ownership and permissions of $spaced" ]]; then
        printf '  pass  a repair names a writable path containing " is " whole\n'
    else printf '  FAIL  repair for a writable path containing " is " reads: %s\n' "$remedy"; status=1; fi
    remedy=$(worker_core_remedy "$spaced is not owned by uid 1000")
    if [[ $remedy == "restore ownership and permissions of $spaced" ]]; then
        printf '  pass  a repair names a foreign-owned path containing " is " whole\n'
    else printf '  FAIL  repair for a foreign-owned path containing " is " reads: %s\n' "$remedy"; status=1; fi
    mv "$drel/core/dsmr.core.worker" "$drel/core/dsmr.core.worker.away"
    if checks_release; then
        printf '  FAIL  release check passed a release with no worker core\n'; status=1
    else printf '  pass  release check fires on a release with no worker core\n'; fi
    # The remedy must name a step that removes the cause: a repair for a mode,
    # a deploy of a new commit for a missing core, never a redeploy of current.
    remedy=$(SBCL="$sbin/sbcl" DSMR_HOME="$dhome" "$0" --check-release 2>&1 | grep 'remedy:')
    if [[ $remedy == *"no release yet"* ]]; then
        printf '  pass  a missing worker core names a deploy of a new commit\n'
    else printf '  FAIL  a missing worker core names no rebuild: %s\n' "$remedy"; status=1; fi
    mv "$drel/core/dsmr.core.worker.away" "$drel/core/dsmr.core.worker"

    # A file the launcher requires cannot be missing. Each case moves one out
    # of the sound release above and restores it.
    local gone
    for gone in scripts/release-paths.sh bin/dsmr-mcp-launch; do
        mv "$drel/$gone" "$drel/$gone.away"
        if checks_release; then
            printf '  FAIL  release check passed a release missing %s\n' "$gone"; status=1
        else printf '  pass  release check fires on a release missing %s\n' "$gone"; fi
        mv "$drel/$gone.away" "$drel/$gone"
    done

    # A registration naming a launcher inside a checkout is flagged; one outside
    # every work tree is not, or the check is stuck on red.
    mkdir -p "$tmp/checkout/scripts" "$tmp/release/bin"
    git init -q "$tmp/checkout" 2>/dev/null
    if registration_problem "$tmp/checkout/scripts/dsmr-mcp-launch.sh" >/dev/null; then
        printf '  FAIL  registration check passed a launcher inside a checkout\n'; status=1
    else printf '  pass  registration check fires on a launcher inside a checkout\n'; fi
    if registration_problem "$tmp/release/bin/dsmr-mcp-launch" >/dev/null; then
        printf '  pass  registration check passes a launcher outside every checkout\n'
    else printf '  FAIL  registration check flagged a launcher outside every checkout\n'; status=1; fi

    # Registering writes the CLI's own config, so it must happen only for the
    # account's own deploy home and only when CLAUDE_CONFIG names that config.
    # A stub `claude` on PATH reports no entry and records every call; the real
    # CLI never runs.
    local cbin="$tmp/claude-bin" clog="$tmp/claude.log" acct="$tmp/account"
    mkdir -p "$cbin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$clog" > "$cbin/claude"
    chmod +x "$cbin/claude"
    plant_launcher() {
        mkdir -p "$1/current/bin"
        printf '#!/bin/sh\n' > "$1/current/bin/dsmr-mcp-launch"
        chmod +x "$1/current/bin/dsmr-mcp-launch"
    }
    plant_launcher "$tmp/scratch-home"
    plant_launcher "$tmp/xdg/dsmr-mcp"
    plant_launcher "$acct/.local/share/dsmr-mcp"
    # registers VAR=value...: run check_mcp with HOME at $acct and the given
    # variables; succeed when it called `claude mcp add`.
    registers() {
        rm -f "$clog"
        (
            unset DSMR_HOME XDG_DATA_HOME CLAUDE_CONFIG
            export PATH="$cbin:$PATH" HOME="$acct"
            local kv
            for kv in "$@"; do export "${kv?}"; done
            CHECK_ONLY=0
            check_mcp
        ) >/dev/null 2>&1
        grep -q '^mcp add' "$clog" 2>/dev/null
    }
    if registers DSMR_HOME="$tmp/scratch-home"; then
        printf '  FAIL  registration ran for a scratch DSMR_HOME\n'; status=1
    else printf '  pass  registration refuses a scratch DSMR_HOME\n'; fi
    if registers XDG_DATA_HOME="$tmp/xdg"; then
        printf '  FAIL  registration ran for a scratch XDG_DATA_HOME\n'; status=1
    else printf '  pass  registration refuses a scratch XDG_DATA_HOME\n'; fi
    if registers CLAUDE_CONFIG="$tmp/other.json"; then
        printf '  FAIL  registration ran while CLAUDE_CONFIG names another file\n'; status=1
    else printf '  pass  registration refuses a CLAUDE_CONFIG that claude mcp add does not write\n'; fi
    if registers && registers CLAUDE_CONFIG="$acct/.claude.json"; then
        printf '  pass  registration runs for the account'"'"'s own home and config\n'
    else printf '  FAIL  registration cannot run for the account'"'"'s own home\n'; status=1; fi
    # A hard link is the account's config by identity, whatever its name.
    : > "$acct/.claude.json"
    ln "$acct/.claude.json" "$tmp/hard.json"
    if registers CLAUDE_CONFIG="$tmp/hard.json"; then
        printf '  pass  registration runs for a hard link to the account'"'"'s config\n'
    else printf '  FAIL  registration refused a hard link to the account'"'"'s config\n'; status=1; fi
    if registers DSMR_HOME="$tmp/scratch-home" CLAUDE_CONFIG="$tmp/hard.json"; then
        printf '  FAIL  registration ran for a scratch home through a hard link\n'; status=1
    else printf '  pass  registration refuses a scratch home through a hard link\n'; fi
    rm -f "$tmp/hard.json" "$acct/.claude.json"

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

if ((RELEASE_ONLY)); then
    check_release
    ((${#blocked[@]} == 0)); exit $?
fi

printf 'preflight: host %s\n' "$(hostname)"
check_binaries
check_release
check_mcp
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
