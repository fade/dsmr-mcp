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
SCRIPT=$REPO_ROOT/scripts/restart-session-in-place.sh
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
RULE=$'\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80'

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
win=${2:-}; win=${win#id:}
key=$sb-$win
busyf=$FX/state/$key.busy
case $sub in
    ls)
        [[ -f $FX/ls/$sb.json ]] || exit 1
        cat "$FX/ls/$sb.json"
        ;;
    get-text)
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
                printf '{"type":"mode"}\n' > "$d/$uuid.jsonl"
                echo "$d/$uuid.jsonl" > "$FX/state/$key.file"
            fi
            [[ -f $FX/afterclear/$key ]] && cp "$FX/afterclear/$key" "$busyf"
        elif [[ ! -f $FX/noturn/$key && -f $FX/state/$key.file ]]; then
            f=$(<"$FX/state/$key.file")
            printf '%s\n' '{"type":"user","message":"x"}' \
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
    mkdir -p "$FX"/{ls,screen,state,tdir,notranscript,noturn,afterclear} "$CLAUDE_CONFIG_DIR/projects"
    : > "$FX/sendlog"
    unset KITTY_WINDOW_ID KITTY_LISTEN_ON
    screen_busy_template
}

screen_busy_template() {
    printf '%s\n' 'working' "$RULE" "${GLYPH}${NBSP}" "$RULE" '  esc to interrupt' > "$FX/busy-screen"
}

mksock() {
    python3 -I -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SD/kitty-$1"
}

# mkls SOCK SPEC...: write the `ls` fixture for kitty-SOCK. SPEC is
# title|window-id|window-pid|cwd|kind[|self] with kind claude, sbcl or shell.
mkls() {
    local sock=$1
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
                else
                  { pid: ((.[2] | tonumber) + 1), cwd: .[3], cmdline: ["-zsh"] }
                end ] } ] }) } ]' > "$FX/ls/kitty-$sock.json"
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

screen_idle() {
    printf '%s\n' 'earlier output' "$RULE" "${GLYPH}${NBSP}" "$RULE" '  status line' > "$FX/screen/kitty-$1-$2"
}

screen_text() {
    printf '%s\n' 'earlier output' "$RULE" "$3" "$RULE" '  status line' > "$FX/screen/kitty-$1-$2"
}

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
screen_text A 16 "${GLYPH}${NBSP}"
printf '%s\n' 'working' "$RULE" "${GLYPH}${NBSP}" "$RULE" '  esc to interrupt' > "$FX/screen/kitty-A-16"
run "${FAST[@]}" zebra
try "[busy-esc] running turn refused, nothing typed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)"

one_sister
screen_text A 16 "${GLYPH}${NBSP}half typed"
run "${FAST[@]}" zebra
try "[busy-typed] half-typed prompt refused, nothing typed" "rc=$RC err=$ERR out=$OUT" \
    test "$RC" = 1 -a -z "$(sendlog)"

one_sister
screen_text A 16 "${GLYPH}${NBSP}"
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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
