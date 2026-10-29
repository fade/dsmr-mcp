#!/usr/bin/env bash
#
# Out of band test of scripts/restart-session-in-place.sh, run by
# `make test-restart-session`. No kitty is involved: a stub `kitten` answers
# `ls`, `get-text` and `send-text` from fixture files, and a restart is observed
# through the stub's send log and the transcript files it creates.
#
# The stub refuses any socket outside the scratch socket directory, so a slip
# in this driver cannot reach a live kitty.
#
# Usage: tests/scripts/restart-session-in-place-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=${RSIP_SCRIPT:-$REPO_ROOT/scripts/restart-session-in-place.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rsip-test.XXXXXX")
# AF_UNIX paths are limited to 107 bytes, which a scratch TMPDIR can exceed.
SD=$(mktemp -d /tmp/rsip.XXXXXX)
trap 'rm -rf "$WORK" "$SD"' EXIT

PASSED=0
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }
note() { printf '\n%s\n' "$1"; }

# if/else rather than `cond && ok || bad`, which would also report the failure
# branch whenever the success branch returns non-zero.
try() {
    local label=$1 detail=$2
    shift 2
    if "$@"; then ok "$label"; else bad "$label" "$detail"; fi
}

unset KITTY_WINDOW_ID KITTY_LISTEN_ON
export DSMR_KITTY_SOCKET_DIR=$SD
export CLAUDE_CONFIG_DIR=$WORK/claude
export FX=$WORK/fx
mkdir -p "$WORK/bin"
export DSMR_KITTEN=$WORK/bin/kitten
export PATH=$WORK/bin:$PATH

GLYPH=$'\xe2\x9d\xaf'
NBSP=$'\xc2\xa0'

cat > "$WORK/bin/kitten" <<'STUB'
#!/usr/bin/env bash
# Stub kitten: `@ --to ADDRESS SUBCOMMAND [--match id:N] [TEXT]`, state under $FX.
set -u
[[ ${1:-} == @ && ${2:-} == --to ]] || exit 2
addr=$3
sub=$4
shift 4
sock=${addr#unix:}
case $sock in "$DSMR_KITTY_SOCKET_DIR"/*) ;; *) exit 1 ;; esac
sb=${sock##*/}
# get-text and send-text carry --match id:N after the subcommand name.
[[ ${1:-} == --ansi ]] && shift
win=${2:-}
win=${win#id:}
key=$sb-$win
busyf=$FX/state/$key.busy
case $sub in
    ls)
        [[ -f $FX/ls/$sb.json ]] || exit 1
        cat "$FX/ls/$sb.json"
        ;;
    get-text)
        # A foreground change that lands between the idle test and the send.
        if [[ -f $FX/lsonget/$key ]]; then
            cp "$FX/lsonget/$key" "$FX/ls/$sb.json"
            rm -f "$FX/lsonget/$key"
        fi
        if [[ -f $busyf ]]; then
            n=$(<"$busyf")
            if ((n > 0)); then
                echo $((n - 1)) > "$busyf"
                cat "$FX/busy-screen"
                exit 0
            fi
        fi
        cat "$FX/screen/$key"
        ;;
    send-text)
        text=$3
        busy=0
        [[ -f $busyf ]] && busy=$(<"$busyf")
        printf '%s %s %s %s\n' "$sb" "$win" "$busy" "$text" >> "$FX/sendlog"
        if [[ $text == '/clear\r' ]]; then
            if [[ ! -f $FX/notranscript/$key ]]; then
                uuid=$(</proc/sys/kernel/random/uuid)
                d=$(<"$FX/tdir/$key")
                printf '%s\n' '{"type":"mode"}' \
                    '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}' > "$d/$uuid.jsonl"
                echo "$d/$uuid.jsonl" > "$FX/state/$key.file"
                # A second session in the same directory starts its own transcript.
                [[ -f $FX/decoy/$key ]] && printf '{"type":"mode"}\n' > "$d/aaaa-decoy.jsonl"
                # A turn the session starts on its own, before the follow-up.
                if [[ -f $FX/wake/$key ]]; then
                    printf '%s\n' '{"type":"attachment","attachment":{"type":"instructions","content":"FIXTURE-INSTRUCTIONS-TEXT"}}' \
                        '{"type":"assistant","message":"wake"}' >> "$d/$uuid.jsonl"
                fi
            fi
            [[ -f $FX/afterclear/$key ]] && cp "$FX/afterclear/$key" "$busyf"
            [[ -f $FX/lsafterclear/$key ]] && cp "$FX/lsafterclear/$key" "$FX/ls/$sb.json"
        elif [[ ! -f $FX/noturn/$key && -f $FX/state/$key.file ]]; then
            f=$(<"$FX/state/$key.file")
            cmd=${text%'\r'}
            printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":\"<command-name>${cmd%% *}</command-name>\"}}" \
                '{"type":"attachment","attachment":{"type":"instructions","content":"FIXTURE-INSTRUCTIONS-TEXT"}}' \
                '{"type":"assistant","message":"y"}' >> "$f"
        fi
        exit 0
        ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/kitten"

# Start every case from nothing: no sockets, no fixtures, no transcripts.
reset() {
    rm -rf "$FX" "$CLAUDE_CONFIG_DIR" "$SD"/kitty-*
    mkdir -p "$FX"/{ls,screen,state,tdir,notranscript,noturn,afterclear,decoy,wake,lsafterclear,lsonget} \
        "$CLAUDE_CONFIG_DIR/projects"
    : > "$FX/sendlog"
    unset KITTY_WINDOW_ID KITTY_LISTEN_ON
    screen_with_busy_line > "$FX/busy-screen"
}

# Screens come from real captures: get-text --ansi on live Claude Code and zsh
# windows, and start-sisters session recordings replayed through a terminal
# emulator. Variants are cut from those captures; none is hand-drawn.
FIXTURES=$REPO_ROOT/tests/scripts/fixtures
PROMPT_EMPTY=$GLYPH$NBSP

# The idle capture with $1 appended after the empty prompt, in normal intensity.
screen_typed_text() {
    local c
    c=$(<"$FIXTURES/claude-idle.ansi")
    [[ $c == *"$PROMPT_EMPTY"$'\n'* ]] || { echo "fixture lost its prompt line" >&2; exit 1; }
    printf '%s\n' "${c/"$PROMPT_EMPTY"$'\n'/"$PROMPT_EMPTY$1"$'\n'}"
}

# A mid-turn capture, rendered from a recorded session: spinner line, empty
# prompt, no panel.
screen_with_busy_line() {
    cat "$FIXTURES/claude-turn-running.ansi"
}

# The leader capture cut to the waiting-for-agents line and the frame, with the
# panel below the status lines removed.
screen_with_waiting_line() {
    head -n 7 "$FIXTURES/claude-agents-running.ansi"
}

# The same capture without its waiting-for-agents line: a panel and nothing else.
screen_with_panel() {
    tail -n +2 "$FIXTURES/claude-agents-running.ansi"
}

mksock() {
    python3 -I -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SD/kitty-$1"
}

# mkls SOCK SPEC...: write the `ls` fixture for kitty-SOCK. SPEC is
# title|window-id|window-pid|cwd|kind[|self] with kind claude, sbcl, vim or shell.
mkls() {
    mkls_to "$FX/ls/kitty-$1.json" "${@:2}"
}

mkls_to() {
    local out=$1
    shift
    printf '%s\n' "$@" | jq -R -s '
        split("\n") | map(select(length > 0) | split("|"))
        | [ { id: 1, tabs: map({ title: .[0], windows: [ {
              id: (.[1] | tonumber), pid: (.[2] | tonumber), cwd: .[3],
              is_self: (.[5] == "self"),
              foreground_processes: [
                if .[4] == "claude" then
                  { pid: ((.[2] | tonumber) + 1), cwd: .[3],
                    cmdline: ["/usr/bin/script", "--quiet", "--flush", "--return",
                              "--log-timing", "/x/t", "--log-out", "/x/o", "--",
                              "direnv", "exec", .[3], "claude", "--permission-mode", "auto", "/worker"] }
                elif .[4] == "sbcl" then
                  { pid: ((.[2] | tonumber) + 1), cwd: .[3], cmdline: ["sbcl"] }
                elif .[4] == "vim" then
                  { pid: ((.[2] | tonumber) + 1), cwd: .[3], cmdline: ["vim", "claude"] }
                else
                  { pid: ((.[2] | tonumber) + 1), cwd: .[3], cmdline: ["-zsh"] }
                end ] } ] }) } ]' > "$out"
}

# seed SOCK WIN SLUG: transcript directory (slug written by hand) holding one
# older session, and an idle screen for the window.
seed() {
    local sock=$1 win=$2 slug=$3 d
    d=$CLAUDE_CONFIG_DIR/projects/$slug
    mkdir -p "$d"
    printf '{"type":"mode"}\n' > "$d/old-session.jsonl"
    touch -d '2 days ago' "$d/old-session.jsonl"
    echo "$d" > "$FX/tdir/kitty-$sock-$win"
    screen_idle "$sock" "$win"
}

screen_idle()   { cp "$FIXTURES/claude-idle.ansi" "$FX/screen/kitty-$1-$2"; }
screen_typed()  { screen_typed_text "$3" > "$FX/screen/kitty-$1-$2"; }
screen_from()   { cp "$FIXTURES/$3" "$FX/screen/kitty-$1-$2"; }
screen_busy()   { screen_with_busy_line > "$FX/screen/kitty-$1-$2"; }
screen_waiting() { screen_with_waiting_line > "$FX/screen/kitty-$1-$2"; }
screen_panel()  { screen_with_panel > "$FX/screen/kitty-$1-$2"; }

FAST=(--poll 0.05 --timeout 5)
OUT="" ERR="" RC=0
run() {
    RC=0
    "$SCRIPT" "$@" > "$WORK/out" 2> "$WORK/err" || RC=$?
    OUT=$(<"$WORK/out")
    ERR=$(<"$WORK/err")
}

sendlog() { cat "$FX/sendlog"; }
log_is() { [[ "$(sendlog)" == "$(printf '%s\n' "$@")" ]]; }
newfile_stem() {
    local f
    f=$(<"$FX/state/kitty-$1-$2.file")
    f=${f##*/}
    printf '%s\n' "${f%.jsonl}"
}

# One sister window on socket A with an old transcript.
one_sister() {
    reset
    mksock A
    mkls A "zebra|16|5000010|/h/lisp/zebra|claude"
    seed A 16 -h-lisp-zebra
}

note "restart"

one_sister
run "${FAST[@]}" zebra
new=$(newfile_stem A 16 2>/dev/null || echo none)
try "[happy-default] /clear then /worker typed, line reports ids" "rc=$RC err=$ERR out=$OUT log=$(sendlog)" \
    test "$RC" = 0 -a "$OUT" = "zebra unix:$SD/kitty-A 16 old=old-session new=$new ok" -a "$new" != none
try "[happy-default] send log holds exactly the two commands" "$(sendlog)" \
    log_is 'kitty-A 16 0 /clear\r' 'kitty-A 16 0 /worker\r'

reset
mksock A
mksock B
mkls A "sbcl|16|5000010|/h/lisp/sbcl|claude"
mkls B "sbcl|1|5000100|/h|sbcl"
seed A 16 -h-lisp-sbcl
seed B 1 -h
run "${FAST[@]}" sbcl
try "[resolve-sbcl-trap] sister window restarted, REPL untouched" "rc=$RC err=$ERR out=$OUT log=$(sendlog)" \
    test "$RC" = 0 -a -n "$(sendlog)" -a -z "$(grep ' kitty-B\|^kitty-B' "$FX/sendlog")"

one_sister
KITTY_LISTEN_ON=unix:$SD/kitty-A KITTY_WINDOW_ID=16 run "${FAST[@]}" zebra
try "[self-env] caller's own window refused, nothing typed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$OUT"

one_sister
mkls A "zebra|16|$$|/h/lisp/zebra|claude"
run "${FAST[@]}" zebra
try "[self-ancestry] window holding this process tree refused" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$OUT"

reset
mksock A
mksock B
mkls A "other|3|5000010|/h/lisp/other|claude"
mkls B "zebra|12|5000020|/h/lisp/zebra|claude|self"
seed B 12 -h-lisp-zebra
KITTY_LISTEN_ON=unix:$SD/kitty-A KITTY_WINDOW_ID=12 run "${FAST[@]}" zebra
try "[self-foreign-is-self] same window id on another socket is not the caller" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a -n "$(sendlog)"

one_sister
screen_busy A 16
run "${FAST[@]}" zebra
try "[busy-spinner] mid-turn with an empty prompt refused, nothing typed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'a turn is running' <<<"$OUT")"

one_sister
long_verb="Transmogrifying the entire quantum flux capacitor manifold in earnest"
sed "s/Transmogrifying/$long_verb/" "$FIXTURES/claude-turn-running.ansi" > "$FX/screen/kitty-A-16"
run "${FAST[@]}" zebra
try "[busy-spinner-long] a spinner phrase over 60 bytes still refuses" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'a turn is running' <<<"$OUT")" -a "${#long_verb}" -gt 64

for f in claude-turn-running-thinking.ansi claude-turn-running-hooks.ansi; do
    one_sister
    screen_from A 16 "$f"
    run "${FAST[@]}" zebra
    try "[busy-spinner] other glyph and wording ($f) refused" "rc=$RC err=$ERR out=$OUT" \
        test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'a turn is running' <<<"$OUT")"
done

one_sister
screen_typed A 16 "half typed"
run "${FAST[@]}" zebra
try "[busy-typed] half-typed prompt refused, nothing typed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)"

one_sister
screen_idle A 16
run "${FAST[@]}" zebra
try "[idle-nbsp] prompt holding only U+00A0 is idle" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a -n "$(sendlog)"

one_sister
echo 3 > "$FX/afterclear/kitty-A-16"
run "${FAST[@]}" zebra
try "[wait-after-clear] follow-up held until the prompt is idle" "rc=$RC err=$ERR out=$OUT log=$(sendlog)" \
    test "$RC" = 0
try "[wait-after-clear] busy screens consumed before /worker" "$(sendlog)" \
    log_is 'kitty-A 16 0 /clear\r' 'kitty-A 16 0 /worker\r'

reset
mksock A
mkls A "sys_scripts.d|7|5000010|/h/sys_scripts.d|claude"
seed A 7 -h-sys-scripts-d
run "${FAST[@]}" sys_scripts.d
new=$(newfile_stem A 7 2>/dev/null || echo none)
try "[slug-map] underscore and dot map to hyphens in the transcript directory" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a "$new" != none -a "$OUT" = "sys_scripts.d unix:$SD/kitty-A 7 old=old-session new=$new ok"

# Three sisters on one socket: alpha, beta, gamma.
three() {
    reset
    mksock A
    mkls A "alpha|11|5000010|/h/lisp/alpha|claude" "beta|12|5000020|/h/lisp/beta|claude" "gamma|13|5000030|/h/lisp/gamma|claude"
    seed A 11 -h-lisp-alpha
    seed A 12 -h-lisp-beta
    seed A 13 -h-lisp-gamma
}

note "options and refusals"

one_sister
run "${FAST[@]}" --then /leader zebra
try "[then-leader] follow-up replaced" "rc=$RC err=$ERR log=$(sendlog)" \
    test "$RC" = 0
try "[then-leader] log" "$(sendlog)" log_is 'kitty-A 16 0 /clear\r' 'kitty-A 16 0 /leader\r'

one_sister
run "${FAST[@]}" --then '' zebra
new=$(newfile_stem A 16 2>/dev/null || echo none)
try "[then-empty] clear only, new transcript still reported" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 0 -a "$new" != none -a "$OUT" = "zebra unix:$SD/kitty-A 16 old=old-session new=$new ok" \
    -a "$(sendlog)" = 'kitty-A 16 0 /clear\r'

one_sister
run "${FAST[@]}" --then worker zebra
rc1=$RC log1=$(sendlog)
run "${FAST[@]}" --then '/a\b' zebra
try "[then-invalid] no leading slash and a backslash both exit 2, nothing sent" "rc=$rc1/$RC log=$log1$(sendlog)" \
    test "$rc1" = 2 -a "$RC" = 2 -a -z "$log1$(sendlog)"

one_sister
touch "$FX/notranscript/kitty-A-16"
run --poll 0.05 --timeout 1 zebra
try "[no-new-transcript] failed at the stage, follow-up never sent" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a "$(sendlog)" = 'kitty-A 16 0 /clear\r' -a -n "$(grep 'failed: no new transcript' <<<"$OUT")"

one_sister
echo 100000 > "$FX/afterclear/kitty-A-16"
run --poll 0.05 --timeout 1 zebra
try "[timeout-idle] failed at the stage, follow-up never sent" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a "$(sendlog)" = 'kitty-A 16 0 /clear\r' -a -n "$(grep 'failed: prompt not idle' <<<"$OUT")"

one_sister
run "${FAST[@]}" --expect FIXTURE-INSTRUCTIONS-TEXT zebra
try "[expect-found] pattern present in the new transcript" "rc=$RC out=$OUT" test "$RC" = 0

one_sister
printf 'NOT-IN-TRANSCRIPT\n' > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
run "${FAST[@]}" --expect NOT-IN-TRANSCRIPT zebra
try "[expect-missing] a fresh file elsewhere does not satisfy the check" "rc=$RC out=$OUT" \
    test "$RC" = 1 -a -n "$(grep 'failed: expect pattern not found' <<<"$OUT")"

one_sister
run "${FAST[@]}" --expect X --then '' zebra
try "[expect-clear-only] exit 2, nothing sent" "rc=$RC err=$ERR" test "$RC" = 2 -a -z "$(sendlog)"

reset
mksock A
mkls A "zebra|16|5000010|/h/lisp/other|claude"
seed A 16 -h-lisp-other
run "${FAST[@]}" zebra
try "[zero-candidates] refused with the candidate listed, nothing sent" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" \
    -a "$(grep -c "candidate: unix:$SD/kitty-A window=16 tab=zebra cwd=/h/lisp/other claude=yes" <<<"$ERR")" = 1 \
    -a -n "$(grep 'refused: no matching session' <<<"$OUT")"

reset
mksock A
mksock B
mkls A "zebra|16|5000010|/h/lisp/zebra|claude"
mkls B "zebra|17|5000020|/h/lisp/zebra|claude"
seed A 16 -h-lisp-zebra
seed B 17 -h-lisp-zebra
run "${FAST[@]}" zebra
try "[several-candidates] ambiguous name refused with both listed, nothing sent" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" \
    -a "$(grep -c 'candidate:' <<<"$ERR")" = 2 \
    -a -n "$(grep 'refused: 2 matching sessions' <<<"$OUT")"

reset
mksock A
mksock B
mkdir -p "$WORK/d1/zebra" "$WORK/d2/zebra"
p1=$(cd -P "$WORK/d1/zebra" && pwd -P)
p2=$(cd -P "$WORK/d2/zebra" && pwd -P)
mkls A "zebra|16|5000010|$p1|claude"
mkls B "zebra|17|5000020|$p2|claude"
seed A 16 "$(printf '%s' "$p1" | tr -c 'A-Za-z0-9' '-')"
seed B 17 "$(printf '%s' "$p2" | tr -c 'A-Za-z0-9' '-')"
run "${FAST[@]}" "$p1"
try "[path-target] directory picks the one window of two same-named tabs" "rc=$RC err=$ERR out=$OUT log=$(sendlog)" \
    test "$RC" = 0 -a -n "$(sendlog)" -a -z "$(grep '^kitty-B' "$FX/sendlog")"

three
screen_typed A 12 "half typed"
run "${FAST[@]}" alpha beta gamma
try "[multi-sequential] stops at the first refusal, later target not-run" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a "$(sed -n 1p <<<"$OUT" | awk '{print $NF}')" = ok \
    -a -n "$(sed -n 2p <<<"$OUT" | grep '^beta .* refused: ')" \
    -a "$(sed -n 3p <<<"$OUT")" = "gamma unix:$SD/kitty-A 13 old=- new=- not-run" \
    -a "$(wc -l <<<"$OUT")" = 3 \
    -a "$(sendlog)" = "$(printf '%s\n' 'kitty-A 11 0 /clear\r' 'kitty-A 11 0 /worker\r')"

three
run "${FAST[@]}" alpha beta ghost
try "[multi-resolve-first] one unresolved target types nothing anywhere" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a -z "$(sendlog)" \
    -a -n "$(sed -n 1p <<<"$OUT" | grep ' not-run$')" \
    -a -n "$(sed -n 2p <<<"$OUT" | grep ' not-run$')" \
    -a -n "$(sed -n 3p <<<"$OUT" | grep '^ghost .* refused: no matching session$')"

three
run "${FAST[@]}" --dry-run alpha beta
try "[dry-run] every target would restart, nothing typed" "rc=$RC out=$OUT" \
    test "$RC" = 0 -a -z "$(sendlog)" -a "$(grep -c 'would-restart$' <<<"$OUT")" = 2 \
    -a -n "$(grep '^alpha .* old=old-session new=- would-restart$' <<<"$OUT")"

three
screen_typed A 12 "half typed"
run "${FAST[@]}" -n alpha beta
try "[dry-run-busy] the busy target is refused, nothing typed" "rc=$RC out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep '^beta .* refused: ' <<<"$OUT")" \
    -a -n "$(grep '^alpha .* would-restart$' <<<"$OUT")"

reset
run "${FAST[@]}" zebra
try "[unsupported-no-socket] no kitty socket exits 3" "rc=$RC err=$ERR" \
    test "$RC" = 3 -a -n "$(grep 'unsupported' <<<"$ERR" | grep kitty)"

one_sister
DSMR_KITTEN=$WORK/no-such-kitten run "${FAST[@]}" zebra
try "[unsupported-no-kitten] missing kitten exits 3, nothing sent" "rc=$RC err=$ERR" \
    test "$RC" = 3 -a -n "$(grep unsupported <<<"$ERR")" -a -z "$(sendlog)"

one_sister
mksock B
run "${FAST[@]}" zebra
try "[unreachable-socket] a dead socket is noted and skipped" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a -n "$(grep 'skipping.*kitty-B' <<<"$ERR")"

one_sister
run "${FAST[@]}" zebra zebra
try "[duplicate-target] same target twice exits 2, nothing sent" "rc=$RC err=$ERR" \
    test "$RC" = 2 -a -z "$(sendlog)"

note "installed layout"

one_sister
# BINDIR and LIBDIR in the environment must not redirect the install onto the
# operator's deployed copies.
mkdir -p "$WORK/decoy"
BINDIR=$WORK/decoy LIBDIR=$WORK/decoy make --no-print-directory -C "$REPO_ROOT" install-restart-session \
    PREFIX="$WORK/prefix" BINDIR="$WORK/prefix/bin" LIBDIR="$WORK/prefix/lib/dsmr-mcp" >"$WORK/make.out" 2>&1
"$WORK/prefix/bin/restart-session-in-place.sh" "${FAST[@]}" --dry-run zebra > "$WORK/out" 2> "$WORK/err"
RC=$?
OUT=$(<"$WORK/out")
ERR=$(<"$WORK/err")
try "[installed-layout] installed copy finds its library and runs" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a -f "$WORK/prefix/lib/dsmr-mcp/kitty-sockets.sh" -a -n "$(grep 'would-restart$' <<<"$OUT")" -a -z "$(sendlog)" -a -z "$(ls -A "$WORK/decoy")"

note "idle test against real captures"

one_sister
screen_from A 16 claude-idle-suggestion.ansi
run "${FAST[@]}" zebra
try "[ghost-suggestion-idle] a dim suggested prompt is not typed input" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a -n "$(sendlog)"

one_sister
screen_from A 16 zsh-prompt.ansi
run "${FAST[@]}" zebra
try "[zsh-prompt] a shell's bare prompt glyph is not an idle Claude prompt" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'no Claude Code prompt frame' <<<"$OUT")"

one_sister
screen_from A 16 claude-agents-running.ansi
run "${FAST[@]}" zebra
try "[agents-running] a session with agents in flight is refused" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)"

one_sister
screen_waiting A 16
run "${FAST[@]}" zebra
try "[waiting-line] the waiting-for-agents line alone refuses" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'background agents are running' <<<"$OUT")"

one_sister
screen_panel A 16
run "${FAST[@]}" zebra
try "[panel-open] a task panel under the status lines alone refuses" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'panel is open' <<<"$OUT")"

note "claude process guard"

for kind in sbcl shell vim; do
    reset
    mksock A
    mkls A "zebra|16|5000010|/h/lisp/zebra|$kind"
    seed A 16 -h-lisp-zebra
    run "${FAST[@]}" zebra
    try "[claude-guard-$kind] title and cwd match but the process is not claude" "rc=$RC err=$ERR out=$OUT" \
        test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'refused: no matching session' <<<"$OUT")"
done

one_sister
mkls_to "$FX/lsonget/kitty-A-16" "zebra|16|5000010|/h/lisp/zebra|shell"
run "${FAST[@]}" zebra
try "[foreground-recheck-first] window turned into a shell before /clear: refused" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)" -a -n "$(grep 'foreground process changed' <<<"$OUT")"

one_sister
mkls_to "$FX/lsafterclear/kitty-A-16" "zebra|16|5000010|/h/lisp/zebra|shell"
run "${FAST[@]}" zebra
try "[foreground-recheck-followup] window turned into a shell after /clear: follow-up never sent" "rc=$RC err=$ERR out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a "$(sendlog)" = 'kitty-A 16 0 /clear\r' -a -n "$(grep 'foreground process changed after /clear' <<<"$OUT")"

note "transcript attribution"

one_sister
touch "$FX/decoy/kitty-A-16"
run "${FAST[@]}" zebra
new=$(newfile_stem A 16 2>/dev/null || echo none)
try "[transcript-decoy] a transcript without the /clear record is not this window's" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0 -a "$new" != none -a "$OUT" = "zebra unix:$SD/kitty-A 16 old=old-session new=$new ok"

one_sister
touch "$FX/wake/kitty-A-16" "$FX/noturn/kitty-A-16"
run --poll 0.05 --timeout 1 zebra
try "[wake-turn-not-followup] a turn the session started itself does not confirm the follow-up" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -n "$(grep 'not answered' <<<"$OUT")"

one_sister
touch "$FX/wake/kitty-A-16"
run "${FAST[@]}" --expect FIXTURE-INSTRUCTIONS-TEXT zebra
try "[wake-turn-then-followup] the follow-up's own record after a wake turn is confirmed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 0

three
touch "$FX/notranscript/kitty-A-11"
run --poll 0.05 --timeout 1 alpha beta
try "[multi-failure-stops] a failure after typing stops the next target" "rc=$RC out=$OUT log=$(sendlog)" \
    test "$RC" = 1 -a "$(sendlog)" = 'kitty-A 11 0 /clear\r' \
    -a -n "$(sed -n 1p <<<"$OUT" | grep '^alpha .* failed: ')" \
    -a "$(sed -n 2p <<<"$OUT")" = "beta unix:$SD/kitty-A 12 old=- new=- not-run"

one_sister
KITTY_WINDOW_ID=16 run "${FAST[@]}" zebra
try "[self-env-no-listen] window id alone, with no socket named, refuses" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)"

one_sister
run "${FAST[@]}" --then $'/a\tb' zebra
try "[then-control-char] a control character in --then exits 2" "rc=$RC err=$ERR" test "$RC" = 2 -a -z "$(sendlog)"

note "interrupted run"

one_sister
echo 100000 > "$FX/afterclear/kitty-A-16"
"$SCRIPT" "${FAST[@]}" zebra > "$WORK/out" 2> "$WORK/err" &
pid=$!
for _ in $(seq 100); do
    grep -q '/clear' "$FX/sendlog" && break
    sleep 0.05
done
kill -TERM "$pid"
wait "$pid"
RC=$?
OUT=$(<"$WORK/out")
try "[interrupted] a killed run reports the half-restarted target" "rc=$RC out=$OUT" \
    test "$RC" = 1 -a -n "$(grep '^zebra .* failed: interrupted after /clear was sent$' <<<"$OUT")"

note "start-sisters socket discovery"

reset
mkdir -p "$WORK/fleet/solo/.git" "$WORK/fleet/solo/.planning"
sisters_dry() {
    "$REPO_ROOT/scripts/start-sisters.sh" --no-scan --extra "$WORK/fleet/solo" --no-direnv --no-stagger --dry-run 2>&1
}
mksock A
one=$(sisters_dry)
mksock B
two=$(sisters_dry)
rm -f "$SD"/kitty-*
none=$(sisters_dry)
try "[start-sisters-socket] one socket addressed, several and none left as placeholders" "one=$one two=$two none=$none" \
    test "$(grep -c -- "--to unix:$SD/kitty-A" <<<"$one")" -ge 1 \
    -a "$(grep -c -- '<several-sockets-found>' <<<"$two")" -ge 1 \
    -a "$(grep -c -- '<no-socket-found>' <<<"$none")" -ge 1

note "start-sisters without a checkout beside it"

reset
mkdir -p "$WORK/ss/bin" "$WORK/ss/lib/dsmr-mcp" "$WORK/lone"
cp "$REPO_ROOT/scripts/start-sisters.sh" "$WORK/lone/"
cp "$REPO_ROOT/scripts/start-sisters.sh" "$WORK/ss/bin/"
cp "$REPO_ROOT/scripts/kitty-sockets.sh" "$WORK/ss/lib/dsmr-mcp/"
mkdir -p "$WORK/fleet/solo/.git" "$WORK/fleet/solo/.planning"
ss_args=(--no-scan --extra "$WORK/fleet/solo" --no-direnv --no-stagger --dry-run)
lone_to=$(KITTY_LISTEN_ON=unix:$SD/kitty-A "$WORK/lone/start-sisters.sh" "${ss_args[@]}" 2>&1); lone_rc=$?
mksock A
lone_find=$("$WORK/lone/start-sisters.sh" "${ss_args[@]}" 2>&1); lone_find_rc=$?
inst=$("$WORK/ss/bin/start-sisters.sh" "${ss_args[@]}" 2>&1); inst_rc=$?
try "[start-sisters-no-library] a given socket needs no library" "rc=$lone_rc out=$lone_to" test "$lone_rc" = 0
try "[start-sisters-no-library] discovery without a library says so" "rc=$lone_find_rc out=$lone_find" \
    test "$lone_find_rc" != 0 -a -n "$(grep 'kitty-sockets.sh not found' <<<"$lone_find")"
try "[start-sisters-installed-layout] library found under ../lib/dsmr-mcp" "rc=$inst_rc out=$inst" \
    test "$inst_rc" = 0 -a -n "$(grep -- "--to unix:$SD/kitty-A" <<<"$inst")"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
