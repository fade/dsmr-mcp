#!/usr/bin/env bash
#
# Out of band test of scripts/worktree-sister.sh and
# skills/leader/worktree-sister-status.sh, run by `make test-worktree-sister`.
#
# git runs for real in scratch repositories. direnv and kitten are stubs that
# log their argv; kitten exits 1 and must never be called. The fleet launcher
# is the real scripts/start-sisters.sh, run only with --dry-run against an
# empty socket directory. Nothing reaches kitty, a session or a bus.
#
# Usage: tests/scripts/worktree-sister-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=$REPO_ROOT/scripts/worktree-sister.sh
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
export HOME=$WORK/home XDG_STATE_HOME=$WORK/state XDG_CONFIG_HOME=$WORK/config
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
try ".planning resolves to the repository's bucket" "" \
    same "$(readlink -f "$WT/.planning")" "$(readlink -f "$G/repo/.planning")"
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

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0 && PASSED > 0))
