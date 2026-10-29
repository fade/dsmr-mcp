#!/usr/bin/env bash
#
# Restart a running Claude Code session inside its existing kitty tab, by typing
# /clear and then a role command into it over kitty remote control.
#
# CLAUDE.md loads once per session and subagents inherit the parent's copy, so a
# configuration change reaches only new sessions. Launching new windows for a
# fleet is what start-sisters.sh does; this types into the windows that already
# exist instead, so no new tab is opened.
#
# The only keystrokes sent are a command followed by Enter. Nothing interrupts a
# turn, and a session that is busy or holds half-typed input is refused.
#
# This is general tooling and knows no fleet. The caller names the targets.

set -euo pipefail
# Byte-wise string handling: the prompt glyph is matched as bytes, and
# EPOCHREALTIME always uses a "." separator.
export LC_ALL=C

PROGNAME=${0##*/}
KITTEN=${DSMR_KITTEN:-kitten}

TIMEOUT=120
POLL=1
THEN_CMD=/worker

usage() {
    cat <<EOF
Usage: $PROGNAME [--timeout SECONDS] [--poll SECONDS] NAME

Restart the Claude Code session in the kitty tab titled NAME.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 2
}

unsupported() {
    printf '%s: unsupported: %s\n' "$PROGNAME" "$*" >&2
    exit 3
}

note() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
}

is_number() {
    [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

TARGETS=()
while (($#)); do
    case $1 in
        -h|--help)      usage; exit 0 ;;
        --timeout)      (($# >= 2)) || die_usage "$1 needs a value"; TIMEOUT=$2; shift 2 ;;
        --timeout=*)    TIMEOUT=${1#*=}; shift ;;
        --poll)         (($# >= 2)) || die_usage "$1 needs a value"; POLL=$2; shift 2 ;;
        --poll=*)       POLL=${1#*=}; shift ;;
        --)             shift; TARGETS+=("$@"); break ;;
        -*)             die_usage "unknown option: $1" ;;
        *)              TARGETS+=("$1"); shift ;;
    esac
done

is_number "$TIMEOUT" || die_usage "--timeout needs a number of seconds: $TIMEOUT"
is_number "$POLL" || die_usage "--poll needs a number of seconds: $POLL"
((${#TARGETS[@]} == 1)) || die_usage "name exactly one target"

# The shared socket library sits beside this script in a checkout and under
# ../lib/dsmr-mcp once installed.
self=$(readlink -f -- "${BASH_SOURCE[0]}")
selfdir=${self%/*}
lib=""
for cand in "$selfdir/kitty-sockets.sh" "$selfdir/../lib/dsmr-mcp/kitty-sockets.sh"; do
    if [[ -r $cand ]]; then lib=$cand; break; fi
done
if [[ -z $lib ]]; then
    note "kitty-sockets.sh not found at $selfdir/kitty-sockets.sh or $selfdir/../lib/dsmr-mcp/kitty-sockets.sh"
    exit 3
fi
# shellcheck source=/dev/null  # path is computed from this script's own location
source "$lib"

command -v "$KITTEN" >/dev/null 2>&1 || unsupported "$KITTEN not found; kitty remote control is required"
command -v jq >/dev/null 2>&1 || unsupported "jq not found"

# Run one kitty remote-control command. The command line is an array at every
# step: a string variable is not word-split under zsh, which sends nothing and
# reports nothing.
kit() {
    local addr=$1
    shift
    timeout 10 "$KITTEN" @ --to "$addr" "$@"
}

# Seconds as integer microseconds, from a validated decimal.
to_usec() {
    local int=${1%%.*} frac=""
    [[ $1 == *.* ]] && frac=${1#*.}
    frac=${frac}000000
    printf '%d\n' "$((10#$int * 1000000 + 10#${frac:0:6}))"
}

TIMEOUT_US=$(to_usec "$TIMEOUT")

# Run "$@" until it succeeds or TIMEOUT passes. Returns 0 on success.
wait_for() {
    local deadline now
    deadline=$((${EPOCHREALTIME/./} + TIMEOUT_US))
    while :; do
        if "$@"; then return 0; fi
        now=${EPOCHREALTIME/./}
        ((now < deadline)) || return 1
        sleep "$POLL"
    done
}

PROMPT_GLYPH=$'\xe2\x9d\xaf'
BOX_BAR=$'\xe2\x94\x82'
NBSP=$'\xc2\xa0'

# Succeeds when the window shows an empty prompt and no running turn.
# The prompt line is the last one whose first non-blank character, after an
# optional box-drawing bar, is the prompt glyph; anything after the glyph other
# than ASCII whitespace and U+00A0 is typed input.
window_idle() {
    local addr=$1 win=$2 text line
    text=$(kit "$addr" get-text --match "id:$win") || return 1
    [[ $text == *"esc to interrupt"* ]] && return 1
    line=$(grep -a -E -- "^[[:space:]]*(${BOX_BAR}[[:space:]]*)?${PROMPT_GLYPH}" <<<"$text" | tail -n 1) || true
    [[ -n $line ]] || return 1
    line=${line#*"$PROMPT_GLYPH"}
    line=${line//"$NBSP"/}
    line=${line//[[:space:]]/}
    [[ -z $line ]]
}

# Session cwd to the directory Claude Code keeps its transcripts in.
transcript_dir() {
    local cwd=$1
    printf '%s/projects/%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${cwd//[^A-Za-z0-9]/-}"
}

# Ancestor pids of this process, one per line, so the window this script runs in
# can be recognised whichever kitty instance it belongs to.
ancestry() {
    local pid=$$ stat
    while [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) && [[ -r /proc/$pid/stat ]]; do
        printf '%s\n' "$pid"
        stat=$(<"/proc/$pid/stat") || break
        stat=${stat##*) }
        # shellcheck disable=SC2086  # intentional split of "state ppid ..."
        set -- $stat
        pid=${2:-}
    done
}

# Succeeds when the window is the one this script was started from. kitty's
# is_self flag is not consulted: it is set on the same-numbered window of every
# instance, so a window is identified by its socket and id.
window_is_self() {
    local addr=$1 win=$2 wpid=$3 fpids=$4 p
    if [[ -n ${KITTY_WINDOW_ID:-} && $win == "$KITTY_WINDOW_ID" ]]; then
        if [[ -z ${KITTY_LISTEN_ON:-} ]] ||
            [[ $(kitty_socket_path "$KITTY_LISTEN_ON") == "$(kitty_socket_path "$addr")" ]]; then
            return 0
        fi
    fi
    [[ -d /proc ]] || return 1
    local -a mine
    mapfile -t mine < <(ancestry)
    local m
    for p in "$wpid" ${fpids//,/ }; do
        [[ -n $p ]] || continue
        for m in "${mine[@]}"; do
            [[ $m == "$p" ]] && return 0
        done
    done
    return 1
}

# Window rows for one target across one socket's ls output, tab separated:
# candidate, match, title, window id, window pid, foreground pids, cwd, claude.
window_rows() {
    local json=$1 name=$2
    jq -r --arg name "$name" '
        def base: split("/") | map(select(length > 0)) | last // "";
        .[] | .tabs[]? as $t | $t.windows[]? | . as $w
        | [ $w.foreground_processes[]? ] as $fg
        | [ $fg[] | select(any((.cmdline // [])[]; (split("/") | last) == "claude")) | .cwd ] as $cc
        | ($cc | first // "") as $ccwd
        | ($t.title // "") as $title
        | [ ($title == $name or any($fg[]; (.cwd // "" | base) == $name)),
            ($title == $name and $ccwd != "" and ($ccwd | base) == $name),
            $title, ($w.id | tostring), ($w.pid | tostring),
            ([ $fg[].pid | tostring ] | join(",")),
            ($ccwd | if . == "" then ($fg[0].cwd // $w.cwd // "-") else . end),
            ($ccwd != "") ]
        | @tsv' <<<"$json"
}

# Result of restart_target, set by the functions below.
VERDICT="" OLD_ID="-" NEW_ID="-" T_SOCK="-" T_WIN="-"

latest_stem() {
    local dir=$1 f best="" newest=0 m
    for f in "$dir"/*.jsonl; do
        [[ -f $f ]] || continue
        m=$(stat -c %Y -- "$f")
        if ((m >= newest)); then newest=$m; best=$f; fi
    done
    [[ -n $best ]] || { printf -- '-\n'; return 0; }
    best=${best##*/}
    printf '%s\n' "${best%.jsonl}"
}

# Names of *.jsonl files directly in $1, one per line.
jsonl_names() {
    local f
    for f in "$1"/*.jsonl; do
        [[ -f $f ]] && printf '%s\n' "${f##*/}"
    done
    return 0
}

NEW_FILES=()
# Succeeds when the directory holds at least one *.jsonl absent from SNAPSHOT.
# shellcheck disable=SC2329  # run through wait_for
new_transcript_present() {
    local dir=$1 n
    NEW_FILES=()
    while IFS= read -r n; do
        [[ -n $n ]] || continue
        [[ $'\n'"$SNAPSHOT"$'\n' == *$'\n'"$n"$'\n'* ]] || NEW_FILES+=("$n")
    done < <(jsonl_names "$dir")
    ((${#NEW_FILES[@]} > 0))
}

# shellcheck disable=SC2329  # run through wait_for
has_assistant_record() {
    [[ -f $1 ]] && grep -aq -F -e '"type":"assistant"' -- "$1"
}

SNAPSHOT=""

# Type /clear and the follow-up into the resolved window, waiting for each
# effect. Sets VERDICT and NEW_ID.
restart_target() {
    local addr=$1 win=$2 dir=$3 file
    window_idle "$addr" "$win" || { VERDICT="refused: session is busy or has typed input"; return 1; }
    SNAPSHOT=$(jsonl_names "$dir")
    OLD_ID=$(latest_stem "$dir")
    kit "$addr" send-text --match "id:$win" '/clear\r' || { VERDICT="failed: send-text /clear"; return 1; }
    if ! wait_for new_transcript_present "$dir"; then
        VERDICT="failed: no new transcript within ${TIMEOUT}s after /clear"
        return 1
    fi
    if ((${#NEW_FILES[@]} > 1)); then
        VERDICT="failed: ${#NEW_FILES[@]} new transcripts appeared after /clear, cannot attribute"
        return 1
    fi
    file=$dir/${NEW_FILES[0]}
    NEW_ID=${NEW_FILES[0]%.jsonl}
    if ! wait_for window_idle "$addr" "$win"; then
        VERDICT="failed: prompt not idle within ${TIMEOUT}s after /clear"
        return 1
    fi
    if [[ -n $THEN_CMD ]]; then
        kit "$addr" send-text --match "id:$win" "$THEN_CMD"'\r' || { VERDICT="failed: send-text $THEN_CMD"; return 1; }
        if ! wait_for has_assistant_record "$file"; then
            VERDICT="failed: no assistant record within ${TIMEOUT}s after $THEN_CMD"
            return 1
        fi
    fi
    VERDICT=ok
    return 0
}

# ---- resolve ----------------------------------------------------------------

name=${TARGETS[0]}
[[ $name != */* ]] || die_usage "path targets are not supported yet: $name"

declare -a socks=()
kitty_socket_paths socks
((${#socks[@]})) || unsupported "no kitty socket under ${DSMR_KITTY_SOCKET_DIR:-/tmp}; kitty remote control is required"

matches=()
reachable=0
for s in "${socks[@]}"; do
    addr=unix:$s
    if ! json=$(kit "$addr" ls 2>/dev/null); then
        note "skipping $addr: ls failed"
        continue
    fi
    reachable=1
    while IFS=$'\t' read -r _ match _ win wpid fpids cwd _; do
        [[ $match == true ]] || continue
        matches+=("$addr"$'\t'"$win"$'\t'"$wpid"$'\t'"$fpids"$'\t'"$cwd")
    done < <(window_rows "$json" "$name")
done
((reachable)) || unsupported "no kitty socket answered ls"

emit() {
    printf '%s %s %s old=%s new=%s %s\n' "$name" "$T_SOCK" "$T_WIN" "$OLD_ID" "$NEW_ID" "$VERDICT"
}

if ((${#matches[@]} != 1)); then
    VERDICT="refused: ${#matches[@]} matching sessions"
    emit
    exit 1
fi

IFS=$'\t' read -r T_SOCK T_WIN wpid fpids cwd <<<"${matches[0]}"

if window_is_self "$T_SOCK" "$T_WIN" "$wpid" "$fpids"; then
    VERDICT="refused: this is the calling window"
    emit
    exit 1
fi

tdir=$(transcript_dir "$cwd")
if [[ ! -d $tdir ]]; then
    VERDICT="refused: no transcript directory $tdir"
    emit
    exit 1
fi

if restart_target "$T_SOCK" "$T_WIN" "$tdir"; then
    emit
    exit 0
fi
emit
exit 1
