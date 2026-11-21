#!/usr/bin/env bash
#
# Out of band test of scripts/worktree-sister.sh and
# skills/leader/worktree-sister-status.sh, run by `make test-worktree-sister`.
#
# git runs for real in scratch repositories. direnv and kitten are stubs that
# log their argv; kitten exits 1 and must never be called. The bus watcher is a
# stub that replays answers recorded from the real binary. The fleet launcher
# is the real scripts/start-sisters.sh, run only with --dry-run against an
# empty socket directory. Nothing reaches kitty, a session or a bus.
#
# Usage: tests/scripts/worktree-sister-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=${WST_SCRIPT:-$REPO_ROOT/scripts/worktree-sister.sh}
ORIG_HOME=$HOME
PLAN=.planning
STATUS=$REPO_ROOT/skills/leader/worktree-sister-status.sh

# Isolation: no DSMR_ setting, kitty socket or git configuration from the
# calling shell. Without the git isolation the host's excludes file already
# ignores .planning and .envrc, and its template directory copies hooks into
# every scratch repository.
for v in $(env | sed -n 's/^\(DSMR_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset KITTY_LISTEN_ON KITTY_WINDOW_ID GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
WORK=$(mktemp -d "${TMPDIR:-/tmp}/worktree-sister-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
export HOME=$WORK/home XDG_STATE_HOME=$WORK/state XDG_CONFIG_HOME=$WORK/config XDG_CACHE_HOME=$WORK/cache
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$WORK/gitconfig
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Fixture
	email = fixture@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[advice]
	detachedHead = false
EOF

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

# Stubs. Each logs under $WST_LOGS, which every case group points at its own
# directory.
STUBS=$WORK/bin
mkdir -p "$STUBS"
cat >"$STUBS/direnv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WST_LOGS/direnv.log"
case $1 in
    exec)  exit "$(cat "$WST_LOGS/direnv-exec-status" 2>/dev/null || echo 0)" ;;
    *)     exit 0 ;;
esac
EOF
cat >"$STUBS/kitten" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WST_LOGS/kitten.log"
exit 1
EOF
cat >"$STUBS/start-sisters-dry" <<EOF
#!/usr/bin/env bash
mkdir -p "\$WST_LOGS/sockets"
DSMR_KITTY_SOCKET_DIR=\$WST_LOGS/sockets bash "$REPO_ROOT/scripts/start-sisters.sh" "\$@" --dry-run >>"\$WST_LOGS/launch.out" 2>&1
EOF
# The bus watcher stub prints the recorded answer named in $WST_LOGS/checklive
# (live, dead or unknown; default dead) and exits with the status the real
# binary gave for it. Recorded 2026-11-21 from ~/.local/bin/dsmr-bus-watch,
# sha256 dacded8b9f81, stdout only:
#   live     exit 0  --check-live --bus dsmr-mcp --agent dsmr-mcp
#                      --namespace /home/fade/SourceCode/lisp/dsmr-mcp/
#                    (the leader's identity, armed while the fleet was up)
#   dead     exit 1  --check-live --bus dsmr-mcp --agent worktree-sister-capture
#                      --namespace /nonexistent/
#   unknown  exit 2  env -u DSMR_BUS_AGENT dsmr-bus-watch --check-live --bus dsmr-mcp
FIXTURES=$REPO_ROOT/tests/scripts/fixtures
cat >"$STUBS/dsmr-bus-watch" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$WST_LOGS/buswatch.log"
answer=\$(cat "\$WST_LOGS/checklive" 2>/dev/null || echo dead)
case \$answer in live) rc=0 ;; dead) rc=1 ;; *) rc=2 ;; esac
cat "$FIXTURES/bus-watch-check-live-\$answer.out"
exit \$rc
EOF
chmod 755 "$STUBS"/*
export PATH=$STUBS:$PATH

# Fixture: G/origin.git (bare), G/repo (the main checkout, .planning linked to
# G/bucket holding a STATE.md sentinel, an untracked .envrc), G/scratch (the
# scratch root). Sets G for the helpers below.
fixture() {
    G=$WORK/$1
    mkdir -p "$G/bucket" "$G/scratch" "$G/logs"
    export WST_LOGS=$G/logs
    git init -q --bare "$G/origin.git"
    git clone -q "$G/origin.git" "$G/repo" 2>/dev/null
    printf 'sentinel\n' >"$G/bucket/STATE.md"
    printf 'leader park\n' >"$G/bucket/PARK.md"
    printf 'leader block\n' >"$G/bucket/BLOCKED.md"
    printf 'leader context\n' >"$G/bucket/CURRENT-CONTEXT.md"
    printf 'hidden\n' >"$G/bucket/.continue-here.md"
    mkdir -p "$G/bucket/codebase"
    ln -s "$G/bucket" "$G/repo/.planning"
    printf 'fixture\n' >"$G/repo/README"
    git -C "$G/repo" add README
    git -C "$G/repo" commit -qm 'Add README'
    git -C "$G/repo" push -q -u origin main 2>/dev/null
    cat >"$G/repo/.envrc" <<'EOF'
export FIXTURE_MARKER=1
export DSMR_BUS_AGENT="${DSMR_BUS_AGENT:-repo}"
export DSMR_MODE=auto
export DSMR_SLYNK_ATTACH=127.0.0.1:1
export DSMR_RELATED_PROJECTS=/fixture/related/
EOF
}

# Run the helper against fixture G; sets OUT (stdout and stderr) and RC.
ws() {
    OUT=$(DSMR_SCRATCH_ROOT=${WST_SCRATCH:-$G/scratch} DSMR_START_SISTERS=$STUBS/start-sisters-dry \
          bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

# Everything a refused or dry run must leave unchanged.
snapshot() {
    git -C "$G/repo" worktree list --porcelain
    ls -A "$G/scratch"
    find "$G/bucket" -path '*sisters*' | sort
    cat "$(git -C "$G/repo" rev-parse --path-format=absolute --git-path info/exclude)" 2>/dev/null
}

repo_state() {
    git -C "$G/repo" symbolic-ref --short HEAD
    git -C "$G/repo" rev-parse HEAD
    git -C "$G/repo" status --porcelain --untracked-files=no
}

exclude_file() { git -C "$G/repo" rev-parse --path-format=absolute --git-path info/exclude; }
count_line()   { grep -cxF -- "$2" "$1" 2>/dev/null; }
logged()       { grep -qF -- "$2" "$G/logs/$1" 2>/dev/null; }
not_logged()   { ! logged "$@"; }
empty_log()    { [[ ! -s $G/logs/$1 ]]; }
same()         { [[ $1 == "$2" ]]; }
has()          { [[ $1 == *"$2"* ]]; }
field()        { awk -v k="$2:" '$1 == k { print $2; exit }' "$1"; }

# Evaluate the worktree's .envrc in a clean environment holding a foreign
# DSMR_BUS_AGENT, and print the settings it leaves.
envrc_values() {
    # shellcheck disable=SC2016  # expanded by the inner shell
    env -i HOME="$HOME" PATH="$PATH" DSMR_BUS_AGENT=leader bash -c '
        cd "$1" && source ./.envrc >/dev/null 2>&1
        for v in DSMR_BUS_AGENT DSMR_WORKTREE_SISTER DSMR_BUS_SELECTOR \
                 DSMR_BUS_DIRECT_ADDRESSING DSMR_MODE FIXTURE_MARKER DSMR_RELATED_PROJECTS; do
            printf "%s=%s\n" "$v" "${!v-}"
        done
        printf "DSMR_SLYNK_ATTACH=%s\n" "${DSMR_SLYNK_ATTACH-<unset>}"' _ "$1"
}

# ---------------------------------------------------------------------------
note "create: end to end"
fixture create
before=$(repo_state)
ws create --bus testbus "$G/repo" feature/thing
WT=$G/scratch/repo-thing
try "create exits 0" "rc=$RC out=$OUT" same "$RC" 0
try "the worktree is listed by git" "$(git -C "$G/repo" worktree list --porcelain)" \
    grep -qxF "worktree $WT" <(git -C "$G/repo" worktree list --porcelain)
try "the worktree is on feature/thing" "" \
    same "$(git -C "$WT" symbolic-ref --short HEAD 2>&1)" feature/thing
try ".planning resolves to the sister's view in the bucket" "" \
    same "$(readlink -f "$WT/.planning")" "$(readlink -f "$G/repo/.planning")/sisters/repo-integration"
try "git status in the worktree is empty" "$(git -C "$WT" status --porcelain 2>&1)" \
    same "$(git -C "$WT" status --porcelain 2>&1)" ""
try ".planning is in the exclude file once" "" same "$(count_line "$(exclude_file)" .planning)" 1
try ".envrc is in the exclude file once" "" same "$(count_line "$(exclude_file)" .envrc)" 1
vals=$(envrc_values "$WT")
for want in DSMR_BUS_AGENT=repo-integration DSMR_WORKTREE_SISTER=repo-integration \
            DSMR_BUS_SELECTOR=testbus DSMR_BUS_DIRECT_ADDRESSING=1 DSMR_MODE=hermetic \
            DSMR_SLYNK_ATTACH='<unset>' FIXTURE_MARKER=1 \
            "DSMR_RELATED_PROJECTS=$WT/:/fixture/related/"; do
    try ".envrc sets $want" "$vals" grep -qxF -- "$want" <<<"$vals"
done
REG=$G/bucket/sisters/repo-integration/WORKTREE
try "the registration exists" "" test -s "$REG"
for kv in "name repo-integration" "repo $G/repo" "worktree $WT" "branch feature/thing" "bus testbus"; do
    try "the registration records ${kv%% *}" "$(cat "$REG" 2>&1)" same "$(field "$REG" "${kv%% *}")" "${kv#* }"
done
try "the registration records a UTC creation time" "$(cat "$REG" 2>&1)" \
    grep -qE '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$REG"
dl=$(cat "$G/logs/direnv.log" 2>/dev/null)
try "direnv checks the repository before approving the worktree" "$dl" \
    same "$dl" "$(printf 'exec %s true\nallow %s' "$G/repo" "$WT")"
lo=$(cat "$G/logs/launch.out" 2>/dev/null)
for want in "--tab-title repo-thing" "--cwd $WT" "direnv exec $WT" \
            "claude --permission-mode auto /worker" "1 tab(s) would be opened"; do
    try "the launcher shows $want" "$lo" has "$lo" "$want"
done
try "kitten is never called" "$(cat "$G/logs/kitten.log" 2>/dev/null)" empty_log kitten.log
try "the main checkout's branch, HEAD and tracked files are unchanged" "$(repo_state)" \
    same "$(repo_state)" "$before"
try "the final output says how she comes up" "$OUT" has "$OUT" "RESUMED repo-integration"

ws create --bus testbus --name other "$G/repo" feature/other
try "a second create exits 0" "rc=$RC out=$OUT" same "$RC" 0
try "a second create adds no second .planning line" "" same "$(count_line "$(exclude_file)" .planning)" 1
try "a second create adds no second .envrc line" "" same "$(count_line "$(exclude_file)" .envrc)" 1

# ---------------------------------------------------------------------------
note "create: the planning view"
fixture view
ws create --no-launch --bus testbus "$G/repo" feature/thing
WT=$G/scratch/repo-thing
VIEW=$G/bucket/sisters/repo-integration
try "the view holds the sister's registration as a real file" "" test -f "$VIEW/WORKTREE" -a ! -L "$VIEW/WORKTREE"
for e in STATE.md codebase .continue-here.md sisters; do
    try "the view links the shared entry $e" "$(ls -la "$VIEW" 2>&1)" test -L "$VIEW/$e"
done
for e in PARK.md BLOCKED.md CURRENT-CONTEXT.md LEFT; do
    try "the view holds no copy of the leader's $e" "" test ! -e "$VIEW/$e" -a ! -L "$VIEW/$e"
done
try "a shared entry resolves to the leader's file" "" same "$(cat "$WT/$PLAN/STATE.md" 2>&1)" sentinel
try "the registration resolves through the sisters link in the view" "" \
    test -f "$WT/$PLAN/sisters/repo-integration/WORKTREE"
for e in PARK.md BLOCKED.md CURRENT-CONTEXT.md; do
    printf 'sister %s\n' "$e" >"$WT/$PLAN/$e"
done
try "her PARK.md write leaves the leader's alone" "" same "$(cat "$G/bucket/PARK.md")" "leader park"
try "her BLOCKED.md write leaves the leader's alone" "" same "$(cat "$G/bucket/BLOCKED.md")" "leader block"
try "her CURRENT-CONTEXT.md write leaves the leader's alone" "" \
    same "$(cat "$G/bucket/CURRENT-CONTEXT.md")" "leader context"
try "her writes land in her view" "" same "$(cat "$VIEW/PARK.md" 2>&1)" "sister PARK.md"

# The SessionStart hook relinks any .planning that does not point at the path it
# computes for the project root, so that path must lead to the view.
HOOKD=$(readlink "$WT/.planning")
try ".planning links to a path under the cache's project directory" "$HOOKD" \
    grep -qE "^$XDG_CACHE_HOME/opencode/projects/repo-thing_[0-9a-f]{8}/planning$" <<<"$HOOKD"
try "the hook path is a link to the view" "$(ls -la "${HOOKD%/*}" 2>&1)" \
    test -L "$HOOKD" -a "$(readlink "$HOOKD")" = "$VIEW"
HOOK_JS=$ORIG_HOME/.claude/hooks/gsd-planning-symlinks.js
IDENT_JS=$ORIG_HOME/.claude/scripts/project-identity.js
if command -v node >/dev/null && [[ -f $HOOK_JS && -f $IDENT_JS ]]; then
    want=$(cd "$WT" && node -e 'console.log(require(process.argv[1]).resolveProjectIdentity(process.cwd()).planningDir)' "$IDENT_JS" 2>&1)
    try "the hook path is the one the SessionStart hook computes" "hook=$want ours=$HOOKD" same "$HOOKD" "$want"
    (cd "$WT" && node "$HOOK_JS" >/dev/null 2>&1)
    try "after the hook runs .planning still resolves to the view" "$(readlink -f "$WT/.planning")" \
        same "$(readlink -f "$WT/.planning")" "$VIEW"
    try "after the hook runs her own PARK.md is still hers" "" same "$(cat "$WT/$PLAN/PARK.md")" "sister PARK.md"
    # Control: a .planning linked straight at the view, as an unfixed create left
    # it, is relinked by the hook to an empty bucket.
    CTL=$G/scratch/repo-control
    git -C "$G/repo" worktree add -q "$CTL" -b control 2>/dev/null
    ln -s "$VIEW" "$CTL/.planning"
    (cd "$CTL" && node "$HOOK_JS" >/dev/null 2>&1)
    try "control: a direct link to the view is reset by the hook" "$(readlink -f "$CTL/.planning")" \
        test "$(readlink -f "$CTL/.planning")" != "$VIEW"
else
    ok "(skipped) the SessionStart hook is not installed here; the hook path is not compared with it"
fi

# ---------------------------------------------------------------------------
note "create: refusals change nothing"

# refused LABEL WANT-RC ARGS...: run in fixture G and require RC and no change.
refused() {
    local label=$1 want=$2
    shift 2
    local snap
    snap=$(snapshot)
    ws "$@"
    try "$label exits $want" "rc=$RC out=$OUT" same "$RC" "$want"
    try "$label changes nothing" "$(snapshot)" same "$(snapshot)" "$snap"
}

fixture refuse-nobus
refused "no bus" 1 create "$G/repo" feature/thing
fixture refuse-names
refused "a name with a slash" 1 create --bus b --name 'a/b' "$G/repo" feature/thing
refused "a name longer than 32" 1 create --bus b --name "$(printf 'n%.0s' {1..33})" "$G/repo" feature/thing
refused "a reserved name" 1 create --bus b --name roster "$G/repo" feature/thing
refused "a bus with a space" 1 create --bus 'x y' "$G/repo" feature/thing
refused "a reserved bus" 1 create --bus default "$G/repo" feature/thing
refused "the repository's own name" 1 create --bus b --name repo "$G/repo" feature/thing
refused "an invalid branch" 1 create --bus b "$G/repo" 'bad..branch'
refused "no arguments" 2 create
refused "an unknown option" 2 create --bogus "$G/repo" feature/thing
fixture refuse-registered
mkdir -p "$G/bucket/sisters/repo-integration"
printf 'worktree: /elsewhere\n' >"$G/bucket/sisters/repo-integration/WORKTREE"
refused "a name already registered" 1 create --bus b "$G/repo" feature/thing
try "the refusal names the teardown command" "$OUT" has "$OUT" "teardown"
fixture refuse-stale
mkdir -p "$G/bucket/sisters/repo-integration"
printf 'left: 2026-01-01T00:00:00Z\n' >"$G/bucket/sisters/repo-integration/LEFT"
refused "a sister directory without a registration" 1 create --bus b "$G/repo" feature/thing
try "the stale LEFT is kept" "" test -s "$G/bucket/sisters/repo-integration/LEFT"
try "the refusal says where to move it" "$OUT" has "$OUT" "sisters-retired"
fixture refuse-dest
mkdir "$G/scratch/repo-thing"
refused "an existing destination" 1 create --bus b "$G/repo" feature/thing
fixture refuse-space
mkdir -p "$G/scratch root"
WST_SCRATCH="$G/scratch root" refused "a destination with whitespace" 1 create --bus b "$G/repo" feature/thing
unset WST_SCRATCH
fixture refuse-noplanning
rm "$G/repo/.planning"
refused "a repository without .planning" 1 create --bus b "$G/repo" feature/thing
fixture refuse-linked
git -C "$G/repo" worktree add -q "$G/linked" -b linked 2>/dev/null
ln -s "$G/bucket" "$G/linked/.planning"
refused "a linked worktree as the repository" 1 create --bus b "$G/linked" feature/thing
fixture refuse-tracked
blob=$(git -C "$G/repo" hash-object -w "$G/repo/.envrc")
tree=$(printf '100644 blob %s\t.envrc\n' "$blob" | git -C "$G/repo" mktree)
git -C "$G/repo" branch withenvrc "$(git -C "$G/repo" commit-tree "$tree" -p HEAD -m 'Track .envrc')"
refused "a start point that tracks .envrc" 1 create --bus b --base withenvrc "$G/repo" feature/thing
refused "an existing branch that tracks .envrc" 1 create --bus b "$G/repo" withenvrc
fixture refuse-direnv
printf '1\n' >"$G/logs/direnv-exec-status"
refused "an .envrc direnv will not load" 1 create --bus b "$G/repo" feature/thing
try "an unloadable .envrc is never approved" "$(cat "$G/logs/direnv.log" 2>/dev/null)" not_logged direnv.log allow

fixture refuse-hookdir
ws create --no-launch --bus b "$G/repo" feature/thing
HOOKD=$(readlink "$G/scratch/repo-thing/.planning")
(cd "$G/repo" && DSMR_BUS_WATCH=$STUBS/dsmr-bus-watch bash "$SCRIPT" teardown --force repo-integration >/dev/null 2>&1)
mkdir -p "$HOOKD"
printf 'keep\n' >"$HOOKD/note"
refused "a hook path holding files" 1 create --no-launch --bus b "$G/repo" feature/thing
try "the refusal leaves the files" "" test -s "$HOOKD/note"
rm "$HOOKD/note"
ws create --no-launch --bus b "$G/repo" feature/thing
try "an empty hook path directory is replaced by the link" "rc=$RC out=$OUT" same "$(readlink "$HOOKD" 2>&1)" "$G/bucket/sisters/repo-integration"

fixture remote-branch
git -C "$G/repo" switch -q -c release/v1
printf 'release\n' >>"$G/repo/README"
git -C "$G/repo" commit -qam 'Release work'
git -C "$G/repo" push -q -u origin release/v1 2>/dev/null
REL=$(git -C "$G/repo" rev-parse HEAD)
git -C "$G/repo" switch -q main
git -C "$G/repo" branch -q -D release/v1
refused "a branch on a remote with --base" 1 create --no-launch --bus b --base main "$G/repo" release/v1
ws create --no-launch --bus b "$G/repo" release/v1
try "a branch only a remote has is created" "rc=$RC out=$OUT" same "$RC" 0
try "it starts at the remote's tip, not at HEAD" "" same "$(git -C "$G/scratch/repo-v1" rev-parse HEAD 2>&1)" "$REL"
try "it tracks the remote branch" "" same "$(git -C "$G/scratch/repo-v1" rev-parse --abbrev-ref '@{upstream}' 2>&1)" origin/release/v1

# ---------------------------------------------------------------------------
note "create: dry run and no launch"
fixture dry
refused "a dry run" 0 create -n --bus b "$G/repo" feature/thing
try "a dry run approves nothing" "$(cat "$G/logs/direnv.log" 2>/dev/null)" not_logged direnv.log allow
try "a dry run runs no launcher" "$(cat "$G/logs/launch.out" 2>/dev/null)" empty_log launch.out
try "a dry run prints the steps" "$OUT" has "$OUT" "would run: git -C $G/repo worktree add"

fixture nolaunch
ws create --no-launch --bus=b "$G/repo" feature/thing
try "--no-launch exits 0" "rc=$RC out=$OUT" same "$RC" 0
try "--no-launch creates the worktree" "" test -d "$G/scratch/repo-thing"
try "--no-launch registers the sister" "" test -s "$G/bucket/sisters/repo-integration/WORKTREE"
try "--no-launch runs no launcher" "$(cat "$G/logs/launch.out" 2>/dev/null)" empty_log launch.out

# ---------------------------------------------------------------------------
note "status report"
fixture status
ws create --no-launch --bus b "$G/repo" feature/thing
WT=$G/scratch/repo-thing
SD=$G/bucket/sisters/repo-integration
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)

# status: sets SOUT and SRC from the report on fixture G's repository.
status() { SOUT=$(bash "$STATUS" "$G/repo" 2>&1); SRC=$?; }
state_is() { grep -qE "^$1 +$2 " <<<"$SOUT"; }

status
try "no PARK.md reads NO-PARK-FILE" "$SOUT" state_is repo-integration NO-PARK-FILE
try "NO-PARK-FILE alone exits 0" "rc=$SRC" same "$SRC" 0
printf 'repo: repo-integration\nsha: %s\n' "$HEAD_SHA" >"$SD/PARK.md"
status
try "the full HEAD sha reads OK" "$SOUT" state_is repo-integration OK
try "OK exits 0" "rc=$SRC" same "$SRC" 0
printf 'repo: repo-integration\nsha: %s\n' "${HEAD_SHA:0:7}" >"$SD/PARK.md"
status
try "a 7-character prefix reads OK" "$SOUT" state_is repo-integration OK
OTHER=$(git -C "$G/repo" commit-tree "$(git -C "$G/repo" rev-parse 'HEAD^{tree}')" -p HEAD -m 'Another commit')
printf 'repo: repo-integration\nsha: %s\n' "$OTHER" >"$SD/PARK.md"
status
try "another commit's sha reads MISMATCH" "$SOUT" state_is repo-integration MISMATCH
try "MISMATCH exits 1" "rc=$SRC" same "$SRC" 1
printf 'repo: repo-integration\nsha: %s\nsha: %s\n' "$HEAD_SHA" "$HEAD_SHA" >"$SD/PARK.md"
status
try "two sha lines read SCHEMA" "$SOUT" state_is repo-integration SCHEMA
try "SCHEMA exits 1" "rc=$SRC" same "$SRC" 1
printf 'repo: repo-integration\nsha: %s\n' "$HEAD_SHA" >"$SD/PARK.md"
printf 'BLOCKED repo-integration: fixture block\n' >"$SD/BLOCKED.md"
status
try "an open block is printed" "$SOUT" has "$SOUT" "fixture block"
try "an open block is headed with her name" "$SOUT" has "$SOUT" "== repo-integration BLOCKED ($SD/BLOCKED.md)"
try "an open block exits 1" "rc=$SRC" same "$SRC" 1
: >"$SD/BLOCKED.md"
mkdir -p "$G/bucket/sisters/ghost"
sed "s|^name: .*|name: ghost|; s|^worktree: .*|worktree: $G/scratch/missing|" "$SD/WORKTREE" \
    >"$G/bucket/sisters/ghost/WORKTREE"
status
try "a registration whose worktree is gone reads NO-WORKTREE" "$SOUT" state_is ghost NO-WORKTREE
try "NO-WORKTREE exits 1" "rc=$SRC" same "$SRC" 1
try "the healthy sister still reads OK beside it" "$SOUT" state_is repo-integration OK
mkdir -p "$WORK/plain"
SOUT=$(bash "$STATUS" "$WORK/plain" 2>&1); SRC=$?
try "a directory without .planning exits 3" "rc=$SRC out=$SOUT" same "$SRC" 3

# ---------------------------------------------------------------------------
note "teardown"

# sister LABEL: a fresh fixture with repo-integration created on feature/thing
# and brought to the removable state: branch pushed, parked at HEAD, LEFT
# written, watcher dead. Sets WT and SD.
sister() {
    fixture "td-$1"
    ws create --no-launch --bus testbus "$G/repo" feature/thing
    WT=$G/scratch/repo-thing
    SD=$G/bucket/sisters/repo-integration
    git -C "$WT" push -q -u origin feature/thing 2>/dev/null
    park
    printf 'left: 2026-11-21T12:00:00Z\n' >"$SD/LEFT"
    printf 'dead\n' >"$G/logs/checklive"
}
park() { printf 'repo: repo-integration\nsha: %s\n' "$(git -C "$WT" rev-parse HEAD)" >"$SD/PARK.md"; }

# td ARGS...: run teardown from the main checkout; sets OUT and RC.
td() {
    OUT=$(cd "$G/repo" && DSMR_BUS_WATCH=$STUBS/dsmr-bus-watch bash "$SCRIPT" teardown "$@" 2>&1)
    RC=$?
}

kept() {
    [[ -d $WT ]] && grep -qxF "worktree $WT" <(git -C "$G/repo" worktree list --porcelain) &&
        [[ -s $SD/WORKTREE && -L $WT/.planning ]]
}
gone() {
    [[ ! -e $WT ]] && ! grep -qxF "worktree $WT" <(git -C "$G/repo" worktree list --porcelain) &&
        [[ ! -e $SD ]]
}
archives() { find "$G/bucket/sisters-retired" -mindepth 1 -maxdepth 1 -name 'repo-integration-*' 2>/dev/null; }

# refused_td LABEL ARGS...: teardown must exit 1 and leave everything in place.
refused_td() {
    local label=$1
    shift
    td "$@"
    try "$label is refused" "rc=$RC out=$OUT" same "$RC" 1
    try "$label leaves the worktree and registration" "$OUT" kept
}

sister removable
saved_park=$(cat "$SD/PARK.md"); saved_left=$(cat "$SD/LEFT"); saved_reg=$(cat "$SD/WORKTREE")
before=$(git -C "$G/repo" symbolic-ref --short HEAD; git -C "$G/repo" rev-parse HEAD)
HOOKD=$(readlink "$WT/.planning")
td repo-integration
try "a removable sister is removed" "rc=$RC out=$OUT" same "$RC" 0
try "the hook path link is removed" "$(ls -la "${HOOKD%/*}" 2>&1)" test ! -e "$HOOKD" -a ! -L "$HOOKD"
try "the hook path's empty project directory is removed" "" test ! -e "${HOOKD%/*}"
try "the leader's PARK.md survives" "" same "$(cat "$G/bucket/PARK.md")" "leader park"
try "the leader's other bucket entries survive" "" test -f "$G/bucket/.continue-here.md" -a -d "$G/bucket/codebase"
try "the archive holds her view with its links" "" test -L "$(archives)/STATE.md"
try "the worktree is gone and unlisted, the registration moved" "$OUT" gone
try "the branch is kept" "" git -C "$G/repo" show-ref --verify -q refs/heads/feature/thing
try "the bucket's STATE.md survives" "" same "$(cat "$G/bucket/STATE.md" 2>&1)" sentinel
try "exactly one archive is made" "$(archives)" same "$(archives | wc -l)" 1
A=$(archives)
try "the archive keeps WORKTREE unchanged" "" same "$(cat "$A/WORKTREE" 2>&1)" "$saved_reg"
try "the archive keeps PARK.md unchanged" "" same "$(cat "$A/PARK.md" 2>&1)" "$saved_park"
try "the archive keeps LEFT unchanged" "" same "$(cat "$A/LEFT" 2>&1)" "$saved_left"
try "the watcher is asked about her identity" "$(cat "$G/logs/buswatch.log" 2>/dev/null)" \
    logged buswatch.log "--check-live --bus testbus --agent repo-integration --namespace $WT/"
try "the main checkout's branch and HEAD are unchanged" "" \
    same "$(git -C "$G/repo" symbolic-ref --short HEAD; git -C "$G/repo" rev-parse HEAD)" "$before"
try "the output names the tab to close" "$OUT" has "$OUT" "close the tab titled repo-thing"

sister lockedwt
HOOKD=$(readlink "$WT/.planning")
git -C "$G/repo" worktree lock "$WT"
td --force repo-integration
try "a failed git removal is refused" "rc=$RC out=$OUT" same "$RC" 1
try "a failed git removal restores .planning" "$(readlink "$WT/.planning" 2>&1)" same "$(readlink "$WT/.planning" 2>&1)" "$HOOKD"
try "a failed git removal restores the hook path" "" same "$(readlink "$HOOKD" 2>&1)" "$SD"
try "a failed git removal leaves the registration" "$OUT" kept
git -C "$G/repo" worktree unlock "$WT"

sister live
printf 'live\n' >"$G/logs/checklive"
refused_td "a live watcher" repo-integration
try "a live watcher prints the LEAVE dispatch" "$OUT" has "$OUT" "LEAVE: commit and push feature/thing"
try "a live watcher prints the reap line" "$OUT" \
    has "$OUT" "--reap --all-buses --agent repo-integration --namespace $WT/"
refused_td "a live watcher under --force" --force repo-integration
printf 'unknown\n' >"$G/logs/checklive"
refused_td "an unknown watcher answer" repo-integration
refused_td "an unknown watcher answer under --force" --force repo-integration

sister noleft
rm "$SD/LEFT"
refused_td "no LEFT" repo-integration
try "no LEFT prints the LEAVE dispatch" "$OUT" has "$OUT" "send to repo-integration by name"
td --force repo-integration
try "no LEFT under --force is removed" "rc=$RC out=$OUT" same "$RC" 0
try "no LEFT under --force prints the disenroll line" "$OUT" \
    has "$OUT" "\"agent\": \"$WT/repo-integration\""

sister nopark
rm "$SD/PARK.md"
refused_td "no PARK.md" repo-integration
sister otherpark
OTHER=$(git -C "$WT" commit-tree "$(git -C "$WT" rev-parse 'HEAD^{tree}')" -p HEAD -m 'Another commit')
printf 'repo: repo-integration\nsha: %s\n' "$OTHER" >"$SD/PARK.md"
refused_td "PARK.md naming another commit" repo-integration
sister twosha
printf 'sha: %s\n' "$(git -C "$WT" rev-parse HEAD)" >>"$SD/PARK.md"
refused_td "PARK.md with two sha lines" repo-integration

sister blocked
printf 'BLOCKED repo-integration: fixture block\n' >"$SD/BLOCKED.md"
refused_td "an open BLOCKED.md" repo-integration
td --force repo-integration
try "an open BLOCKED.md under --force is removed" "rc=$RC out=$OUT" same "$RC" 0
try "the archive keeps BLOCKED.md" "" grep -qF 'fixture block' "$(archives)/BLOCKED.md"

sister modified
printf 'changed\n' >>"$WT/README"
refused_td "a modified tracked file" repo-integration
td --force repo-integration
try "a modified tracked file under --force is removed" "rc=$RC out=$OUT" same "$RC" 0
try "the forced removal still keeps the branch" "" \
    git -C "$G/repo" show-ref --verify -q refs/heads/feature/thing

sister untracked
printf 'new\n' >"$WT/scratch-note"
refused_td "an untracked file" repo-integration

sister ignoredfile
printf '*.log\n' >>"$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
printf 'output\n' >"$WT/build.log"
refused_td "an ignored file" repo-integration
try "the refusal names the ignored file" "$OUT" has "$OUT" "!! build.log"
td --force repo-integration
try "an ignored file under --force is removed" "rc=$RC out=$OUT" same "$RC" 0

sister hiddenuntracked
git -C "$WT" config status.showUntrackedFiles no
printf 'new\n' >"$WT/scratch-note"
refused_td "an untracked file when git is set to hide them" repo-integration

sister unpushed
printf 'more\n' >>"$WT/README"
git -C "$WT" commit -qam 'Change README'
park
refused_td "a commit on no remote" repo-integration
try "the refusal names the push" "$OUT" has "$OUT" "push feature/thing"
git -C "$WT" push -q 2>/dev/null
td repo-integration
try "after the push it is removed" "rc=$RC out=$OUT" same "$RC" 0

sister dryrun
td -n repo-integration
try "a dry run on a removable sister exits 0" "rc=$RC out=$OUT" same "$RC" 0
try "a dry run removes and archives nothing" "$OUT" kept
try "a dry run makes no archive" "$(archives)" same "$(archives)" ""

sister unregistered
td nobody
try "an unregistered name is refused" "rc=$RC out=$OUT" same "$RC" 1
try "an unregistered name lists the registered ones" "$OUT" has "$OUT" "registered: repo-integration"
try "an unregistered name deletes nothing" "$OUT" kept
mkdir -p "$G/scratch/stray" "$G/bucket/sisters/stray"
printf 'keep\n' >"$G/scratch/stray/file"
sed "s|^name: .*|name: stray|; s|^worktree: .*|worktree: $G/scratch/stray|" "$SD/WORKTREE" \
    >"$G/bucket/sisters/stray/WORKTREE"
printf 'left: 2026-11-21T12:00:00Z\n' >"$G/bucket/sisters/stray/LEFT"
td --force stray
try "a registration git does not list is refused, even under --force" "rc=$RC out=$OUT" same "$RC" 1
try "the unlisted directory is not touched" "" test -s "$G/scratch/stray/file"
try "the unlisted registration is kept" "" test -s "$G/bucket/sisters/stray/WORKTREE"

sister everything
rm "$SD/LEFT"
printf 'changed\n' >>"$WT/README"
refused_td "no LEFT and a dirty tree together" repo-integration
try "one run reports the missing LEFT" "$OUT" has "$OUT" "has not left"
try "one run reports the dirty tree" "$OUT" has "$OUT" "uncommitted, untracked or ignored files"

sister inside
OUT=$(cd "$WT" && DSMR_BUS_WATCH=$STUBS/dsmr-bus-watch bash "$SCRIPT" teardown --repo "$G/repo" repo-integration 2>&1)
RC=$?
try "teardown from inside the worktree is refused" "rc=$RC out=$OUT" same "$RC" 1
try "teardown from inside the worktree deletes nothing" "$OUT" kept

# ---------------------------------------------------------------------------
note "skills: the worker's state directory line finds the registration"

# shellcheck disable=SC2016  # the literal text of the skill line
S_LINE='S=.planning${DSMR_WORKTREE_SISTER:+/sisters/$DSMR_WORKTREE_SISTER}'
fixture skill
ws create --no-launch --bus testbus "$G/repo" feature/thing
WT=$G/scratch/repo-thing
for spec in "skills/worker/SKILL.md|3" "skills/fleet-restart/SKILL.md|1"; do
    file=${spec%|*} least=${spec#*|}
    n=$(grep -cF -- "$S_LINE" "$REPO_ROOT/$file")
    try "[$file] the state directory line appears at least $least times" "found $n" \
        test "$n" -ge "$least"
    line=$(grep -m1 -xF -- "$S_LINE" "$REPO_ROOT/$file")
    try "[$file] the line stands alone, as a snippet runs it" "" same "$line" "$S_LINE"
    got=$(cd "$WT" && DSMR_WORKTREE_SISTER=repo-integration bash -c "$line"'
        [ -f "$S/WORKTREE" ] && [ "$(awk '"'"'$1=="worktree:"{print $2}'"'"' "$S/WORKTREE")" = "$(pwd -P)" ] &&
            echo match' 2>&1)
    try "[$file] in her worktree it names her registration" "got=$got" same "$got" match
    # shellcheck disable=SC2016  # expanded by the inner shell
    got=$(cd "$WT" && env -u DSMR_WORKTREE_SISTER bash -c "$line"'; printf %s "$S"' 2>&1)
    try "[$file] for any other sister it is .planning" "got=$got" same "$got" .planning
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0 && PASSED > 0))
