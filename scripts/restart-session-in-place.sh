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
# General tooling with no fleet roster: the caller names the targets.

set -euo pipefail
# Byte-wise string handling: the prompt glyph is matched as bytes, and
# EPOCHREALTIME always uses a "." separator.
export LC_ALL=C

PROGNAME=${0##*/}
KITTEN=${DSMR_KITTEN:-kitten}

TIMEOUT=120
POLL=1
THEN_CMD=/worker
EXPECT=""
EXPECT_SET=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [options] TARGET...

Restart the Claude Code session running in each named kitty tab: type /clear,
wait for a new transcript and an idle prompt, then type a follow-up command and
wait for it to be answered. No new window is opened.

A TARGET is a tab title NAME, or a path. A name matches the one window whose tab
title is NAME and whose claude process runs in a directory called NAME, across
every kitty instance. A path (anything holding a slash) matches the window whose
claude process runs in exactly that directory and whose tab is titled with its
last component; use it when a name is ambiguous.

Options:
  --then CMD         follow-up command, default /worker. Must start with "/" and
                     hold no backslash or control character. '' clears only.
  --expect PATTERN   once the follow-up is answered, require PATTERN (a fixed
                     string) in the new transcript, else fail. Not allowed with
                     --then ''. File times are never consulted.
  --timeout SECONDS  bound on each wait, default 120
  --poll SECONDS     interval between checks, default 1
  -n, --dry-run      resolve and check every target, type nothing
  -h, --help         this text

Several targets are restarted strictly one at a time, in argument order. Every
target is resolved before anything is typed; each session is checked for an idle
prompt just before its own restart, and --dry-run checks them all. In a real run
the first refusal or failure stops it, and later targets are reported not-run.

A session is refused, with nothing typed, when it is the calling window, shows
a running-turn spinner, has background agents or a task panel open, shows no Claude
Code prompt frame, or holds typed text (dim suggestions do not count). Background
shells are not checked. The only keystrokes ever sent are a command and Enter.

Standard output, one line per target:
  NAME SOCKET WINDOW old=ID new=ID VERDICT
old is the newest transcript before the restart, new the one it started; "-"
marks an unknown field. VERDICT is one of:
  ok                restarted, follow-up ran (and PATTERN was found)
  would-restart     --dry-run: every check passed
  refused: REASON   nothing was typed
  failed: REASON    typing began and a stage did not complete
  not-run           an earlier target stopped the run

Exit status: 0 every target ok (would-restart under --dry-run), 1 any refused or
failed, 2 usage error or two targets resolving to one window, 3 unsupported environment
(no kitten, jq, or reachable kitty socket).

Environment: DSMR_KITTEN names the kitten binary, DSMR_KITTY_SOCKET_DIR the
directory searched for kitty-* sockets (default /tmp), CLAUDE_CONFIG_DIR the
Claude Code configuration root (default ~/.claude).
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
        -n|--dry-run)   DRY_RUN=1; shift ;;
        --timeout)      (($# >= 2)) || die_usage "$1 needs a value"; TIMEOUT=$2; shift 2 ;;
        --timeout=*)    TIMEOUT=${1#*=}; shift ;;
        --poll)         (($# >= 2)) || die_usage "$1 needs a value"; POLL=$2; shift 2 ;;
        --poll=*)       POLL=${1#*=}; shift ;;
        --then)         (($# >= 2)) || die_usage "$1 needs a value"; THEN_CMD=$2; shift 2 ;;
        --then=*)       THEN_CMD=${1#*=}; shift ;;
        --expect)       (($# >= 2)) || die_usage "$1 needs a value"; EXPECT=$2; EXPECT_SET=1; shift 2 ;;
        --expect=*)     EXPECT=${1#*=}; EXPECT_SET=1; shift ;;
        --)             shift; TARGETS+=("$@"); break ;;
        -*)             die_usage "unknown option: $1" ;;
        *)              TARGETS+=("$1"); shift ;;
    esac
done

is_number "$TIMEOUT" || die_usage "--timeout needs a number of seconds: $TIMEOUT"
is_number "$POLL" || die_usage "--poll needs a number of seconds: $POLL"
[[ $POLL =~ ^0*\.0[0-4] || $POLL =~ ^0+(\.0*)?$ ]] && die_usage "--poll must be at least 0.05 seconds: $POLL"
# kitty decodes backslash escapes in send-text, so a backslash in the command
# would not arrive as typed.
if [[ -n $THEN_CMD ]]; then
    [[ $THEN_CMD == /* ]] || die_usage "--then must start with / or be empty: $THEN_CMD"
    [[ $THEN_CMD != *\\* ]] || die_usage "--then must not contain a backslash"
    [[ ! $THEN_CMD =~ [[:cntrl:]] ]] || die_usage "--then must not contain a control character"
fi
if ((EXPECT_SET)); then
    [[ -n $THEN_CMD ]] || die_usage "--expect needs a follow-up command: --then '' writes no turn to check"
    [[ -n $EXPECT ]] || die_usage "--expect needs a non-empty pattern"
fi
((${#TARGETS[@]})) || die_usage "name at least one target (see --help)"
for ((i = 0; i < ${#TARGETS[@]}; i++)); do
    for ((j = i + 1; j < ${#TARGETS[@]}; j++)); do
        [[ ${TARGETS[i]} != "${TARGETS[j]}" ]] || die_usage "target named twice: ${TARGETS[i]}"
    done
done

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
RULE_CH=$'\xe2\x94\x80'
ELLIPSIS=$'\xe2\x80\xa6'
NBSP=$'\xc2\xa0'

# Remove terminal escape sequences from stdin.
strip_ansi() {
    sed -E 's/\x1b\[[0-9;:?]*[A-Za-z]//g; s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g'
}

# Remove escape sequences from stdin and drop text rendered dim (SGR 2): Claude
# Code paints its suggested next prompt that way, and it is not typed input.
visible_text() {
    awk '
    { s = $0; out = ""; dim = 0
      while (s != "") {
        if (match(s, /^\033\[[0-9;:]*m/)) {
            seq = substr(s, 3, RLENGTH - 3); s = substr(s, RLENGTH + 1)
            n = split(seq, p, ";")
            if (seq == "") dim = 0
            for (k = 1; k <= n; k++) {
                v = p[k]
                if (v ~ /:/) continue
                if (v == 38 || v == 48 || v == 58) { k += (p[k + 1] == 5) ? 2 : 4; continue }
                if (v == "" || v == 0 || v == 22) dim = 0
                else if (v == 2) dim = 1
            }
        } else if (match(s, /^\033\[[0-9;:?]*[A-Za-z]/)) {
            s = substr(s, RLENGTH + 1)
        } else if (match(s, /^\033\][^\007\033]*(\007|\033\\)/)) {
            s = substr(s, RLENGTH + 1)
        } else {
            if (!dim) out = out substr(s, 1, 1)
            s = substr(s, 2)
        }
      }
      print out }'
}

# Why window_idle last said no.
IDLE_WHY=""

# Succeeds when the window shows Claude Code's own idle prompt: a rule line, one
# prompt line holding nothing but dim suggestion text, a rule line, and nothing
# below them but the two status lines. A bare prompt glyph with no such frame is
# a shell, and a panel below the frame means agents or tasks are in flight, so
# both refuse. Anything doubtful refuses.
window_idle() {
    local addr=$1 win=$2 raw i j a b nb=0 line
    local -a rl=() pl=() rules=() ctx=()
    IDLE_WHY=""
    raw=$(kit "$addr" get-text --ansi --match "id:$win") || { IDLE_WHY="screen unreadable"; return 1; }
    mapfile -t rl <<<"$raw"
    mapfile -t pl < <(strip_ansi <<<"$raw")
    for ((i = 0; i < ${#pl[@]}; i++)); do
        [[ ${pl[i]} =~ ^[[:space:]]*(${RULE_CH}){10,}[[:space:]]*$ ]] && rules+=("$i")
    done
    if ((${#rules[@]} < 2)); then
        IDLE_WHY="no Claude Code prompt frame on screen"
        return 1
    fi
    a=${rules[-2]} b=${rules[-1]}
    if ((b - a != 2)) || [[ ! ${pl[a + 1]} =~ ^[[:space:]]*${PROMPT_GLYPH} ]]; then
        IDLE_WHY="no Claude Code prompt frame on screen"
        return 1
    fi
    # The twelve non-blank lines above the frame, nearest first.
    for ((j = a - 1; j >= 0 && ${#ctx[@]} < 12; j--)); do
        [[ -n ${pl[j]//[[:space:]]/} ]] && ctx+=("${pl[j]}")
    done
    # A running turn draws a spinner line: a glyph, a word ending in an
    # ellipsis, then a parenthesised timer. A todo list can sit between it and
    # the frame, and a spinner-shaped line in the conversation refuses too.
    for line in "${ctx[@]}"; do
        if [[ $line =~ ^[[:space:]]*[^[:space:][:alnum:]]{1,4}[[:space:]]+[^\(\)]{1,60}${ELLIPSIS}[[:space:]]+\( ]]; then
            IDLE_WHY="a turn is running"
            return 1
        fi
    done
    if ((${#ctx[@]})) && [[ ${ctx[0]} =~ Waiting\ for\ [0-9]+\ background\ agent ]]; then
        IDLE_WHY="background agents are running"
        return 1
    fi
    for line in "${pl[@]:b+1}"; do
        [[ -n ${line//[[:space:]]/} ]] && nb=$((nb + 1))
    done
    if ((nb > 2)); then
        IDLE_WHY="a task or agent panel is open"
        return 1
    fi
    line=$(visible_text <<<"${rl[a + 1]}")
    line=${line#*"$PROMPT_GLYPH"}
    line=${line//"$NBSP"/}
    line=${line//[[:space:]]/}
    if [[ -n $line ]]; then
        IDLE_WHY="the prompt holds typed input"
        return 1
    fi
    return 0
}

# Session cwd to the directory Claude Code keeps its transcripts in.
transcript_dir() {
    local cwd=$1
    printf '%s/projects/%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${cwd//[^A-Za-z0-9]/-}"
}

# Ancestor pids of this process, one per line, so the window this script runs in
# can be recognized whichever kitty instance it belongs to.
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

# jq: a foreground process is the claude session when argv[0] is claude, or when
# it is script(1) wrapping claude (optionally under "direnv exec DIR"). An
# argument that merely says "claude" (vim claude) does not count.
# shellcheck disable=SC2016  # jq program text; $ is not a shell expansion
JQ_CLAUDE='
def base: split("/") | map(select(length > 0)) | last // "";
def nz: if . == "" then "-" else . end;
def isclaude:
  (.cmdline // []) as $c
  | ($c[0] // "" | base) as $a0
  | if $a0 == "claude" then true
    elif $a0 == "script" then
      (($c | index("--")) as $d
       | if $d == null then false
         else ($c[$d + 1:]) as $r
           | (if ($r[0] // "" | base) == "direnv" and ($r[1] // "") == "exec" then $r[3:] else $r end)
           | ((.[0] // "") | base) == "claude"
         end)
    else false end;
'

# Window rows for one target across one socket's ls output, tab separated:
# candidate, match, title, window id, window pid, foreground pids, cwd, claude.
# $2 is a tab title for a name target (isp 0), or a directory for a path target
# (isp 1), whose tab title is that directory's last component.
window_rows() {
    local json=$1 key=$2 isp=$3
    jq -r --arg key "$key" --arg isp "$isp" "$JQ_CLAUDE"'
        def here($cwd): if $isp == "1" then $cwd == $key else ($cwd | base) == $key end;
        ($key | base) as $bn
        | .[] | .tabs[]? as $t | $t.windows[]? | . as $w
        | [ $w.foreground_processes[]? ] as $fg
        | [ $fg[] | select(isclaude) | .cwd ] as $cc
        | ($cc | first // "") as $ccwd
        | ($t.title // "") as $title
        | [ ($title == $bn or any($fg[]; here(.cwd // ""))),
            ($title == $bn and $ccwd != "" and here($ccwd)),
            ($title | nz), ($w.id | tostring), ($w.pid | tostring),
            ([ $fg[].pid | tostring ] | join(",") | nz),
            ($ccwd | if . == "" then ($fg[0].cwd // $w.cwd // "-") else . end),
            ($ccwd != "") ]
        | @tsv' <<<"$json"
}

# Succeeds when window $2 on socket $1 still has tab title $3 and the foreground
# processes $4 it had at resolution, and one of them is the claude session.
# Windows outlive their process: a claude started by hand from a shell leaves
# the shell behind when it exits, and typing /clear there would run it.
still_claude() {
    local addr=$1 win=$2 title=$3 fpids=$4 json
    json=$(kit "$addr" ls 2>/dev/null) || return 1
    jq -e --arg w "$win" --arg t "$title" --arg f "$fpids" "$JQ_CLAUDE"'
        [ .[] | .tabs[]? | (.title // "" | nz) as $tt | .windows[]? | select((.id | tostring) == $w)
          | { tt: $tt, fg: (.foreground_processes // []) } ] as $m
        | ($m | length) == 1 and $m[0].tt == $t
          and ([ $m[0].fg[].pid | tostring ] | join(",") | nz) == $f
          and ($m[0].fg | any(isclaude))' <<<"$json" >/dev/null
}

# Result of restart_target.
VERDICT="" OLD_ID="-" NEW_ID="-" STAGE=""

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
# Succeeds when the directory holds a *.jsonl absent from SNAPSHOT that records
# the /clear command. Another session in the same directory can start a
# transcript of its own at the same moment; only the command record ties a file
# to this window.
# shellcheck disable=SC2329  # run through wait_for
new_transcript_present() {
    local dir=$1 n
    NEW_FILES=()
    while IFS= read -r n; do
        [[ -n $n ]] || continue
        [[ $'\n'"$SNAPSHOT"$'\n' == *$'\n'"$n"$'\n'* ]] && continue
        if grep -aq -F -e '<command-name>/clear</command-name>' -- "$dir/$n"; then
            NEW_FILES+=("$n")
        fi
    done < <(jsonl_names "$dir")
    ((${#NEW_FILES[@]} > 0))
}

# Succeeds when transcript $1 records command $2 (its first word) and an
# assistant record follows. A turn the bus listener starts on its own writes an
# assistant record too, so the command record has to come first.
# shellcheck disable=SC2329  # run through wait_for
followup_answered() {
    local file=$1 name=${2%% *} n
    [[ -f $file ]] || return 1
    n=$(grep -an -F -m1 -e "<command-name>$name</command-name>" -- "$file" | cut -d: -f1) || true
    [[ -n $n ]] || return 1
    grep -aq -F -e '"type":"assistant"' <(tail -n +$((n + 1)) -- "$file")
}

SNAPSHOT=""

# Type /clear and the follow-up into the resolved window, waiting for each
# effect. Sets VERDICT, OLD_ID, NEW_ID and STAGE. The idle test and the
# foreground check run immediately before every keystroke.
restart_target() {
    local addr=$1 win=$2 dir=$3 title=$4 fpids=$5 file
    OLD_ID=- NEW_ID=- STAGE=""
    if ! window_idle "$addr" "$win"; then
        VERDICT="refused: session is not idle: $IDLE_WHY"
        return 1
    fi
    if ! still_claude "$addr" "$win" "$title" "$fpids"; then
        VERDICT="refused: foreground process changed since resolution"
        return 1
    fi
    SNAPSHOT=$(jsonl_names "$dir")
    OLD_ID=$(latest_stem "$dir")
    note "$title: typing /clear"
    STAGE="while /clear was being sent"
    kit "$addr" send-text --match "id:$win" '/clear\r' || { VERDICT="failed: send-text /clear (delivery unknown)"; return 1; }
    STAGE="after /clear was sent"
    if ! wait_for new_transcript_present "$dir"; then
        VERDICT="failed: no new transcript recording /clear within ${TIMEOUT}s"
        return 1
    fi
    if ((${#NEW_FILES[@]} > 1)); then
        VERDICT="failed: ${#NEW_FILES[@]} new transcripts recorded /clear, cannot attribute"
        return 1
    fi
    file=$dir/${NEW_FILES[0]}
    NEW_ID=${NEW_FILES[0]%.jsonl}
    if ! wait_for window_idle "$addr" "$win"; then
        VERDICT="failed: prompt not idle within ${TIMEOUT}s after /clear ($IDLE_WHY)"
        return 1
    fi
    if [[ -n $THEN_CMD ]]; then
        if ! still_claude "$addr" "$win" "$title" "$fpids"; then
            VERDICT="failed: foreground process changed after /clear, $THEN_CMD not sent"
            return 1
        fi
        note "$title: typing $THEN_CMD"
        STAGE="while $THEN_CMD was being sent"
        kit "$addr" send-text --match "id:$win" "$THEN_CMD"'\r' || { VERDICT="failed: send-text $THEN_CMD (delivery unknown)"; return 1; }
        STAGE="after $THEN_CMD was sent"
        if ! wait_for followup_answered "$file" "$THEN_CMD"; then
            VERDICT="failed: $THEN_CMD not answered in the new transcript within ${TIMEOUT}s"
            return 1
        fi
    fi
    if ((EXPECT_SET)) && ! grep -aq -F -e "$EXPECT" -- "$file"; then
        VERDICT="failed: expect pattern not found in transcript $NEW_ID"
        return 1
    fi
    VERDICT=ok
    return 0
}

# ---- resolve ----------------------------------------------------------------

declare -a socks=()
kitty_socket_paths socks
((${#socks[@]})) || unsupported "no kitty socket under ${DSMR_KITTY_SOCKET_DIR:-/tmp}; kitty remote control is required"

declare -A LS_JSON=()
reachable=0
for s in "${socks[@]}"; do
    if json=$(kit "unix:$s" ls 2>/dev/null); then
        LS_JSON["unix:$s"]=$json
        reachable=1
    else
        note "skipping unix:$s: ls failed"
    fi
done
((reachable)) || unsupported "no kitty socket answered ls"

# Per-target state, indexed like TARGETS.
T_SOCK=() T_WIN=() T_WPID=() T_FPIDS=() T_CWD=() T_TDIR=() T_TITLE=()
T_OLD=() T_NEW=() T_VERDICT=() T_STATE=()

# Resolve target $1 to a window, or record why it is refused. Candidate windows
# go to stderr when the match is not exactly one.
resolve_target() {
    local i=$1 target=${TARGETS[$1]} key isp=0 addr json match title win wpid fpids cwd claude cand
    local -a found=() cands=()
    T_SOCK[i]=- T_WIN[i]=- T_OLD[i]=- T_NEW[i]=-
    key=$target
    if [[ $target == */* ]]; then
        isp=1
        if ! key=$(cd -P -- "$target" 2>/dev/null && pwd -P); then
            T_STATE[i]=refused T_VERDICT[i]="refused: no such directory"
            return 0
        fi
    fi
    for addr in "${!LS_JSON[@]}"; do
        json=${LS_JSON[$addr]}
        while IFS=$'\t' read -r cand match title win wpid fpids cwd claude; do
            [[ $cand == true ]] || continue
            cands+=("  candidate: $addr window=$win tab=$title cwd=$cwd claude=$([[ $claude == true ]] && echo yes || echo no)")
            [[ $match == true ]] && found+=("$addr"$'\t'"$win"$'\t'"$wpid"$'\t'"$fpids"$'\t'"$cwd"$'\t'"$title")
        done < <(window_rows "$json" "$key" "$isp")
    done
    if ((${#found[@]} != 1)); then
        note "$target: ${#found[@]} matching sessions"
        ((${#cands[@]})) && printf '%s\n' "${cands[@]}" | sort >&2
        if ((${#found[@]} == 0)); then
            T_VERDICT[i]="refused: no matching session"
        else
            T_VERDICT[i]="refused: ${#found[@]} matching sessions"
        fi
        T_STATE[i]=refused
        return 0
    fi
    IFS=$'\t' read -r 'T_SOCK[i]' 'T_WIN[i]' 'T_WPID[i]' 'T_FPIDS[i]' 'T_CWD[i]' 'T_TITLE[i]' <<<"${found[0]}"
    if window_is_self "${T_SOCK[i]}" "${T_WIN[i]}" "${T_WPID[i]}" "${T_FPIDS[i]}"; then
        T_STATE[i]=refused T_VERDICT[i]="refused: this is the calling window"
        return 0
    fi
    T_TDIR[i]=$(transcript_dir "${T_CWD[i]}")
    if [[ ! -d ${T_TDIR[i]} ]]; then
        T_STATE[i]=refused T_VERDICT[i]="refused: no transcript directory ${T_TDIR[i]}"
        return 0
    fi
    T_STATE[i]=pending
}

emit() {
    local i=$1
    printf '%s %s %s old=%s new=%s %s\n' "${TARGETS[i]}" "${T_SOCK[i]}" "${T_WIN[i]}" \
        "${T_OLD[i]}" "${T_NEW[i]}" "${T_VERDICT[i]}"
}

count=${#TARGETS[@]}
for ((i = 0; i < count; i++)); do
    resolve_target "$i"
done

# One window cannot be restarted twice in a run.
for ((i = 0; i < count; i++)); do
    [[ ${T_STATE[i]} == pending ]] || continue
    for ((j = i + 1; j < count; j++)); do
        [[ ${T_STATE[j]} == pending ]] || continue
        if [[ ${T_SOCK[i]} == "${T_SOCK[j]}" && ${T_WIN[i]} == "${T_WIN[j]}" ]]; then
            die_usage "${TARGETS[i]} and ${TARGETS[j]} resolve to the same window"
        fi
    done
done

status=0
halted=0
for ((i = 0; i < count; i++)); do
    [[ ${T_STATE[i]} == refused ]] && halted=1
done
if ((halted)); then
    # Nothing is typed when any target fails to resolve.
    for ((i = 0; i < count; i++)); do
        if [[ ${T_STATE[i]} == pending ]]; then
            T_STATE[i]=notrun T_VERDICT[i]=not-run
        fi
        emit "$i"
    done
    exit 1
fi

if ((DRY_RUN)); then
    for ((i = 0; i < count; i++)); do
        if window_idle "${T_SOCK[i]}" "${T_WIN[i]}"; then
            T_OLD[i]=$(latest_stem "${T_TDIR[i]}")
            T_VERDICT[i]=would-restart
        else
            T_VERDICT[i]="refused: session is not idle: $IDLE_WHY"
            status=1
        fi
        emit "$i"
    done
    exit "$status"
fi

# A run killed mid-sequence still reports the target it was typing into and
# the ones it never reached, so a half-restarted window is never silent.
CUR=-1
# shellcheck disable=SC2329  # run by the trap
on_signal() {
    local k
    trap '' INT TERM HUP
    if ((CUR >= 0)); then
        T_OLD[CUR]=$OLD_ID T_NEW[CUR]=$NEW_ID
        T_VERDICT[CUR]="failed: interrupted ${STAGE:-before typing}"
        emit "$CUR"
        for ((k = CUR + 1; k < count; k++)); do
            T_VERDICT[k]=not-run
            emit "$k"
        done
    fi
    exit 1
}
trap on_signal INT TERM HUP

for ((i = 0; i < count; i++)); do
    if ((status)); then
        T_VERDICT[i]=not-run
        emit "$i"
        continue
    fi
    CUR=$i VERDICT="" OLD_ID=- NEW_ID=- STAGE=""
    if restart_target "${T_SOCK[i]}" "${T_WIN[i]}" "${T_TDIR[i]}" "${T_TITLE[i]}" "${T_FPIDS[i]}"; then :; else status=1; fi
    T_OLD[i]=$OLD_ID T_NEW[i]=$NEW_ID T_VERDICT[i]=$VERDICT
    CUR=-1
    emit "$i"
done
exit "$status"
