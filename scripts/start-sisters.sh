#!/usr/bin/env bash
#
# Open one kitty tab per sister repository, each titled with the sister's name
# and running claude in it.
#
# A sister is a directory holding both .git and .planning. That pair is the
# discriminator: .git alone matches ordinary checkouts that carry no agent.
#
# Sisters are found by scanning a base directory, which defaults to the current
# one. Repositories that live elsewhere but belong to the same fleet are named
# individually with --extra.
#
# This is general tooling and knows nothing about any particular fleet. Which
# directory holds a fleet, and which of its members leads, are inputs: --dir and
# either --leader or a .fleet-leader file sitting beside the repositories. Keep
# it that way. A fleet's membership and its leader both change, and a name baked
# in here would outlive both.
#
# Each session runs under `direnv exec`, so it comes up with its repository's own
# environment. See needs_direnv below for why the working directory alone is not
# enough.

set -euo pipefail

PROGNAME=${0##*/}
# The directory to scan defaults to where the caller is standing, NOT to where
# this script lives: it ships with the harness and is run against whichever
# fleet directory is meant.
BASE_DIR=$PWD
EXTRA_ROOT=${LISP_WORKSPACE:-}

CLAUDE_BIN=claude
DIRENV_BIN=direnv
USE_DIRENV=1
PERMISSION_MODE=auto
KITTY_SOCKET=${KITTY_LISTEN_ON:-}
ONLY=()
EXCLUDE=()
EXTRA=()
LEADER=""
LEADER_FILE=.fleet-leader
LEADER_FROM_FILE=0
LEADER_CMD="/leader"
WORKER_CMD="/worker"
FLEET_TAG=""
DRY_RUN=0
LIST_ONLY=0
FORCE=0
NEW_WINDOW=0
NO_SCAN=0

usage() {
    cat <<EOF
$PROGNAME - open a kitty tab per sister repository, running claude in each.

Usage:
  $PROGNAME [options]

A sister is a directory containing both .git and .planning. Each one gets a
kitty tab named after it, with its own directory as the working directory.

Scanning:
  -d, --dir DIR         Directory holding the fleet's repositories
                        (default: the current directory, now $BASE_DIR)
  -e, --extra LIST      Comma-separated repositories outside that directory to
                        include as well. Each is either a path, or a bare name
                        resolved against --extra-root. Same .git plus .planning
                        requirement applies, and a name that fails it is an
                        error rather than a silent omission.
      --extra-root DIR  Where bare --extra names are resolved
                        (default: \$LISP_WORKSPACE${EXTRA_ROOT:+, currently $EXTRA_ROOT})
  -S, --no-scan         Do not scan --dir at all; use only what --extra names
  -o, --only LIST       Comma-separated names to include, excluding all others
  -x, --exclude LIST    Comma-separated names to skip

Ordering:
  -L, --leader NAME     Bring this one up FIRST, so the leader is running before
                        the sisters that report to it. Named on the command line
                        it is an assertion, so a name not found is an error.
      --leader-file F   File in the scanned directory naming the leader
                        (default: $LEADER_FILE). One name, first line. A leader
                        from the file is a default, so if a filter excludes it
                        the run continues with a note instead of failing.

Roles:
  Each tab opens with a starting prompt so the session comes up in its role: the
  leader tab gets $LEADER_CMD, every other tab gets $WORKER_CMD. Both are slash
  commands resolved by claude itself.
      --leader-cmd CMD  Starting prompt for the leader tab (default: $LEADER_CMD)
      --worker-cmd CMD  Starting prompt for every other tab (default: $WORKER_CMD)
      --fleet-tag TAG   Appended to the worker prompt, e.g. "$WORKER_CMD TAG".
                        Omit to let each repo's own .envrc select its bus.
      --no-role         Open a bare session with no starting prompt at all

Launching:
  -p, --permission-mode MODE
                        Value passed to claude --permission-mode
                        (default: $PERMISSION_MODE)
  -c, --command BIN     Program to run in each tab (default: $CLAUDE_BIN)
      --no-direnv       Start each session without its repository's .envrc.
                        The environment a repository's .envrc exports is how its
                        session finds its own bus identity and its own image, so
                        only pass this for a fleet that keeps that elsewhere.
  -w, --window          Put the tabs in a new OS window instead of this one
  -t, --to SOCKET       kitty remote control socket, e.g. unix:/tmp/kitty-1234
                        (default: \$KITTY_LISTEN_ON, else auto-discovered)
  -f, --force           Open a tab even if one with that title already exists

Reporting:
  -l, --list            List the sisters that would be used, then exit
  -n, --dry-run         Print the commands instead of running them
  -h, --help            Show this help

Examples:
  $PROGNAME --list                     # fleet in the current directory
  $PROGNAME --dir ~/src/some-fleet --list
  $PROGNAME --extra boomer,zebra --list
  $PROGNAME --extra boomer,zebra
  $PROGNAME --leader valis
  $PROGNAME --only valis,seven
  $PROGNAME --no-scan --extra boomer,zebra
  $PROGNAME --extra /path/to/elsewhere/repo --dry-run
  $PROGNAME --no-scan --extra myrepo --leader myrepo   # a one-repo fleet

Requires kitty remote control. If the script cannot reach kitty, check that
kitty.conf sets 'allow_remote_control yes' and a 'listen_on' socket, or pass
--to explicitly.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

# Split a comma-separated option value into the named array.
split_into() {
    local -n target=$1
    local IFS=,
    # shellcheck disable=SC2034  # written through the nameref, read by the caller
    read -r -a target <<<"$2"
}

contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

# A repository's .envrc is what makes its session that sister rather than a
# generic one: the bus identity it answers to and the image it drives are both
# exported there. direnv loads such a file from a shell hook, and kitty execs the
# command with no shell in between, so a tab opened in the right directory still
# comes up with none of it. `direnv exec DIR` reads the file directly, which is
# the same environment the hook would have produced.
needs_direnv() {
    ((USE_DIRENV)) || return 1
    [[ -e ${1%/}/.envrc ]] || return 1
    return 0
}

is_sister_dir() {
    local dir=${1%/}
    [[ -e $dir/.git ]] || return 1
    # -e follows the symlink and -L catches it when its target is missing, so a
    # sister whose planning link is broken is still found rather than hidden.
    [[ -e $dir/.planning || -L $dir/.planning ]] || return 1
    return 0
}

# Long options taking a value accept both "--opt value" and "--opt=value". The
# two forms are interchangeable in most tools, so rejecting one reads as the
# option not existing at all rather than as a spelling to correct.
# An unrecognised name is left alone so the parser below reports it as the typo
# it is, rather than as a good option used wrongly.
VALUED_OPTS=(--dir --extra --extra-root --only --exclude --leader --leader-file
             --leader-cmd --worker-cmd --fleet-tag --permission-mode --command --to)
FLAG_OPTS=(--no-role --no-direnv --no-scan --window --force --list --dry-run --help)

while [[ $# -gt 0 ]]; do
    if [[ $1 == --*=* ]]; then
        if contains "${1%%=*}" "${VALUED_OPTS[@]}"; then
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
        elif contains "${1%%=*}" "${FLAG_OPTS[@]}"; then
            die "${1%%=*} takes no value (try --help)"
        fi
    fi
    case $1 in
        -d|--dir)              [[ $# -ge 2 ]] || die "$1 needs a value"; BASE_DIR=$2; shift 2 ;;
        -e|--extra)            [[ $# -ge 2 ]] || die "$1 needs a value"; split_into EXTRA "$2"; shift 2 ;;
        --extra-root)          [[ $# -ge 2 ]] || die "$1 needs a value"; EXTRA_ROOT=$2; shift 2 ;;
        -o|--only)             [[ $# -ge 2 ]] || die "$1 needs a value"; split_into ONLY "$2"; shift 2 ;;
        -x|--exclude)          [[ $# -ge 2 ]] || die "$1 needs a value"; split_into EXCLUDE "$2"; shift 2 ;;
        -L|--leader)           [[ $# -ge 2 ]] || die "$1 needs a value"; LEADER=$2; shift 2 ;;
        --leader-file)         [[ $# -ge 2 ]] || die "$1 needs a value"; LEADER_FILE=$2; shift 2 ;;
        --leader-cmd)          [[ $# -ge 2 ]] || die "$1 needs a value"; LEADER_CMD=$2; shift 2 ;;
        --worker-cmd)          [[ $# -ge 2 ]] || die "$1 needs a value"; WORKER_CMD=$2; shift 2 ;;
        --fleet-tag)           [[ $# -ge 2 ]] || die "$1 needs a value"; FLEET_TAG=$2; shift 2 ;;
        --no-role)             LEADER_CMD=""; WORKER_CMD=""; shift ;;
        -p|--permission-mode)  [[ $# -ge 2 ]] || die "$1 needs a value"; PERMISSION_MODE=$2; shift 2 ;;
        -c|--command)          [[ $# -ge 2 ]] || die "$1 needs a value"; CLAUDE_BIN=$2; shift 2 ;;
        --no-direnv)           USE_DIRENV=0; shift ;;
        -t|--to)               [[ $# -ge 2 ]] || die "$1 needs a value"; KITTY_SOCKET=$2; shift 2 ;;
        -S|--no-scan)          NO_SCAN=1; shift ;;
        -w|--window)           NEW_WINDOW=1; shift ;;
        -f|--force)            FORCE=1; shift ;;
        -l|--list)             LIST_ONLY=1; shift ;;
        -n|--dry-run)          DRY_RUN=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        --)                    shift; break ;;
        -*)                    die "unknown option: $1 (try --help)" ;;
        *)                     die "unexpected argument: $1 (try --help)" ;;
    esac
done

names=()
paths=()

# Register one sister, applying the include and exclude filters. A name already
# present wins, so a scanned sister is never displaced by an --extra of the same
# name and no repository gets two tabs.
add_sister() {
    local name=$1 path=$2
    ((${#ONLY[@]})) && ! contains "$name" "${ONLY[@]}" && return 0
    ((${#EXCLUDE[@]})) && contains "$name" "${EXCLUDE[@]}" && return 0
    ((${#names[@]})) && contains "$name" "${names[@]}" && return 0
    names+=("$name")
    paths+=("$path")
    return 0
}

if ((!NO_SCAN)); then
    [[ -d $BASE_DIR ]] || die "not a directory: $BASE_DIR"
    BASE_DIR=$(cd -- "$BASE_DIR" && pwd)
    for dir in "$BASE_DIR"/*/; do
        is_sister_dir "$dir" || continue
        name=${dir%/}
        add_sister "${name##*/}" "${name}"
    done
fi

# Repositories outside the scanned directory. Unlike a scan, where a directory
# that does not qualify is simply not a sister, a name given here was asked for
# by hand, so failing to qualify is reported rather than skipped.
for spec in ${EXTRA[@]+"${EXTRA[@]}"}; do
    [[ -n $spec ]] || continue
    if [[ $spec == */* || $spec == /* ]]; then
        path=$spec
    else
        [[ -n $EXTRA_ROOT ]] ||
            die "--extra '$spec' is a bare name but no --extra-root is set and LISP_WORKSPACE is empty"
        path="${EXTRA_ROOT%/}/$spec"
    fi
    [[ -d $path ]] || die "--extra '$spec' is not a directory: $path"
    path=$(cd -- "$path" && pwd)
    is_sister_dir "$path" ||
        die "--extra '$spec' is not a sister: $path lacks .git or .planning"
    add_sister "${path##*/}" "$path"
done

if ((${#names[@]} == 0)); then
    if ((NO_SCAN)); then
        die "--no-scan was given and --extra named nothing usable"
    fi
    die "no sisters found in $BASE_DIR (a sister needs both .git and .planning)"
fi

# The leader comes up first, so it is running before the sisters that report to
# it. Who leads is DATA, never baked into this script: a fleet's membership and
# its leader change, and a name compiled in here would outlive both.
if [[ -z $LEADER && -r "$BASE_DIR/$LEADER_FILE" ]]; then
    LEADER=$(head -n1 -- "$BASE_DIR/$LEADER_FILE" | tr -d '[:space:]')
    LEADER_FROM_FILE=1
fi

if [[ -n $LEADER ]]; then
    if contains "$LEADER" "${names[@]}"; then
        lead_names=("$LEADER")
        lead_paths=()
        for i in "${!names[@]}"; do
            [[ ${names[i]} == "$LEADER" ]] && lead_paths=("${paths[i]}")
        done
        for i in "${!names[@]}"; do
            if [[ ${names[i]} != "$LEADER" ]]; then
                lead_names+=("${names[i]}")
                lead_paths+=("${paths[i]}")
            fi
        done
        names=("${lead_names[@]}")
        paths=("${lead_paths[@]}")
    elif ((LEADER_FROM_FILE)); then
        # A leader named by the file is a default, and a filter that excludes it
        # is a deliberate act, so proceed rather than argue with the caller.
        printf '%s: note: leader %s is not in this set; continuing without it\n' \
            "$PROGNAME" "$LEADER" >&2
    else
        # A leader named on the command line is an assertion, so failing to find
        # it is an error, exactly as for --only.
        die "--leader '$LEADER' is not among the sisters found (try --list)"
    fi
fi

# Names given to --only that matched nothing are almost always a typo, and
# silently starting a smaller fleet than asked for is the failure worth catching.
if ((${#ONLY[@]})); then
    missing=()
    for want in "${ONLY[@]}"; do
        contains "$want" "${names[@]}" || missing+=("$want")
    done
    ((${#missing[@]})) && die "requested but not found: ${missing[*]}"
fi

if ((LIST_ONLY)); then
    for i in "${!names[@]}"; do
        mark=""
        if [[ -n $LEADER && ${names[i]} == "$LEADER" ]]; then
            mark=" (leader, first)${LEADER_CMD:+ -> $LEADER_CMD}"
        else
            mark="${WORKER_CMD:+ -> $WORKER_CMD${FLEET_TAG:+ $FLEET_TAG}}"
        fi
        printf '%-16s %s%s\n' "${names[i]}" "${paths[i]}" "$mark"
    done
    exit 0
fi

# Resolve the remote control socket. Inside kitty this is already set; outside,
# kitty appends its pid to the configured listen_on path, so a single running
# instance can be identified but several cannot be told apart from here.
#
# A dry run must work with no kitty at all, since its whole purpose is to show
# what would happen before committing to it, often from somewhere else entirely.
if [[ -z $KITTY_SOCKET ]]; then
    candidates=()
    for sock in /tmp/kitty-*; do
        [[ -S $sock ]] && candidates+=("$sock")
    done
    case ${#candidates[@]} in
        1)
            KITTY_SOCKET="unix:${candidates[0]}"
            ;;
        0)
            if ((DRY_RUN)); then
                KITTY_SOCKET='<no-socket-found>'
            else
                die "cannot find a kitty socket; run this from kitty or pass --to"
            fi
            ;;
        *)
            if ((DRY_RUN)); then
                KITTY_SOCKET='<several-sockets-found>'
            else
                die "several kitty sockets found; choose one with --to: ${candidates[*]}"
            fi
            ;;
    esac
fi

command -v kitten >/dev/null || die "kitten not found on PATH"

# An .envrc that was never approved makes `direnv exec` refuse to run the command
# at all, so the tab would open and die. Check every repository before opening
# anything: a fleet half up, with the other half's tabs gone by the time anyone
# looks, is the state that costs an afternoon to understand.
if ((!DRY_RUN)) && ((USE_DIRENV)); then
    needs_direnv_any=0
    for path in "${paths[@]}"; do
        needs_direnv "$path" && needs_direnv_any=1
    done
    if ((needs_direnv_any)) && ! command -v "$DIRENV_BIN" >/dev/null; then
        die "$DIRENV_BIN not found on PATH, and these repositories carry a .envrc.
Without it each session starts without its own bus identity and image settings.
Install direnv, or pass --no-direnv if this fleet keeps that elsewhere."
    fi
    # A repository with no .envrc is not an error here, since a fleet may keep its
    # settings elsewhere, but it is worth saying: nothing distinguishes that
    # session from any other, so it reaches no bus and drives no image of its own.
    bare=()
    for i in "${!names[@]}"; do
        [[ -e ${paths[i]}/.envrc ]] || bare+=("${names[i]}")
    done
    ((${#bare[@]})) &&
        printf '%s: note: no .envrc, so no environment of their own: %s\n' \
            "$PROGNAME" "${bare[*]}" >&2

    blocked=()
    for i in "${!names[@]}"; do
        needs_direnv "${paths[i]}" || continue
        "$DIRENV_BIN" exec "${paths[i]}" true >/dev/null 2>&1 || blocked+=("${names[i]}")
    done
    if ((${#blocked[@]})); then
        printf '%s: these repositories have a .envrc that direnv will not load:\n' "$PROGNAME" >&2
        for name in "${blocked[@]}"; do
            for i in "${!names[@]}"; do
                [[ ${names[i]} == "$name" ]] && printf '  direnv allow %s\n' "${paths[i]}" >&2
            done
        done
        die "approve them and run again, or pass --no-direnv to start without them"
    fi
fi

kitty_rc() { kitten @ --to "$KITTY_SOCKET" "$@"; }

if ((!DRY_RUN)); then
    kitty_rc ls >/dev/null 2>&1 ||
        die "kitty remote control is not answering on $KITTY_SOCKET"
fi

# Titles of tabs that already exist, so a second run does not duplicate them.
existing=""
if ((!FORCE && !DRY_RUN)); then
    existing=$(kitty_rc ls 2>/dev/null |
        grep -o '"title": "[^"]*"' |
        sed 's/.*: "//; s/"$//' || true)
fi

launched=0
skipped=0
for i in "${!names[@]}"; do
    name=${names[i]}
    path=${paths[i]}

    if ((!FORCE)) && [[ -n $existing ]] && grep -qxF -- "$name" <<<"$existing"; then
        printf 'skip   %s (a tab with that title is already open; --force to add another)\n' "$name"
        ((skipped++)) || true
        continue
    fi

    launch_args=(launch --type=tab --tab-title "$name" --cwd "$path")
    # The first tab may open a new OS window; the rest join whatever window the
    # run is targeting, or they would each get one of their own.
    if ((NEW_WINDOW && launched == 0)); then
        launch_args=(launch --type=os-window --tab-title "$name" --cwd "$path")
    fi
    # The role prompt. kitty execs argv directly with no shell between, so a
    # leading slash reaches claude literally and resolves as a slash command.
    role_prompt=""
    if [[ -n $LEADER && $name == "$LEADER" ]]; then
        role_prompt=$LEADER_CMD
    else
        role_prompt=$WORKER_CMD
        [[ -n $role_prompt && -n $FLEET_TAG ]] && role_prompt="$role_prompt $FLEET_TAG"
    fi

    launch_args+=(--)
    needs_direnv "$path" && launch_args+=("$DIRENV_BIN" exec "$path")
    launch_args+=("$CLAUDE_BIN" --permission-mode "$PERMISSION_MODE")
    [[ -n $role_prompt ]] && launch_args+=("$role_prompt")

    if ((DRY_RUN)); then
        printf 'kitten @ --to %s %s\n' "$KITTY_SOCKET" "${launch_args[*]}"
    else
        kitty_rc "${launch_args[@]}" >/dev/null
        printf 'opened %s\n' "$name"
    fi
    ((launched++)) || true
done

if ((DRY_RUN)); then
    printf '\n%d tab(s) would be opened\n' "$launched"
else
    printf '\n%d opened, %d skipped\n' "$launched" "$skipped"
fi
