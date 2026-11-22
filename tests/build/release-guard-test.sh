#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One table of release shapes, each run through the release launcher and
# through `make register`, both with a stub SBCL, so the two give the same
# verdict: refused or accepted. A shape is a sound release plus one mutation.
# The launcher is run under `env -i` through <home>/current/bin; register is
# run with the same home and a scratch config. A launcher refusal is exit 78;
# register refuses with any non-zero status. The stub answers --version with
# 9.9.9, exits 0 for the boot probe unless the core file says `noboot`, and
# logs every other boot to $WORK/boot.log.
#
# A release with no launcher cannot be started through its launcher, so those
# rows run register only. A foreign-owned path needs another user and is not
# in the table.
#
# Usage: tests/build/release-guard-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-guard-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }
note() { printf '\n%s\n' "$1"; }
try() {
    local label=$1 detail=$2
    shift 2
    if "$@"; then ok "$label"; else bad "$label" "$detail"; fi
}

mkdir -p "$WORK/bin"
cat > "$WORK/bin/sbcl" <<STUB
#!/bin/sh
case " \$* " in
  *" --version "*) echo "SBCL 9.9.9"; exit 0 ;;
  *"(sb-ext:exit)"*)
    core=""
    while [ \$# -gt 0 ]; do [ "\$1" = --core ] && core="\$2"; shift; done
    grep -q noboot "\$core" 2>/dev/null && exit 1
    exit 0 ;;
esac
core=""
while [ \$# -gt 0 ]; do [ "\$1" = --core ] && core="\$2"; shift; done
printf 'boot core=%s worker=%s\n' "\$core" "\${DSMR_WORKER_CORE:-}" >> "$WORK/boot.log"
exit 0
STUB
chmod +x "$WORK/bin/sbcl"

# build <dir>: a sound release under <dir>/home, current naming it.
build() {
    local h="$1/home" r="$1/home/releases/r"
    mkdir -p "$r/core" "$r/bin" "$r/scripts" "$1/state" "$1/fakehome"
    printf 'core' > "$r/core/dsmr.core"
    printf 'sbcl-version 9.9.9\n' > "$r/core/dsmr.core.manifest"
    printf 'worker core' > "$r/core/dsmr.core.worker"
    printf 'sbcl-version 9.9.9\n' > "$r/core/dsmr.core.worker.manifest"
    printf 'commit 0000000\n' > "$r/MANIFEST"
    cp "$REPO_ROOT/scripts/release-paths.sh" "$r/scripts/release-paths.sh"
    cp "$REPO_ROOT/scripts/release-launch.sh" "$r/bin/dsmr-mcp-launch"
    chmod 755 "$1" "$h" "$h/releases" "$r" "$r/core" "$r/bin" "$r/scripts" "$r/bin/dsmr-mcp-launch"
    chmod 644 "$r/core/"* "$r/MANIFEST" "$r/scripts/release-paths.sh"
    ln -sfn releases/r "$h/current"
}

# Verdicts. launcher_verdict <dir> [VAR=value...] and register_verdict likewise
# print refused, accepted or an odd status.
verdict() {
    case "$1" in 0) echo accepted ;; 78) echo refused ;; *) echo "status-$1" ;; esac
}
run_env() {
    local d=$1; shift
    env -i HOME="$d/fakehome" PATH="$WORK/bin:$PATH" SBCL="$WORK/bin/sbcl" \
        XDG_STATE_HOME="$d/state" XDG_DATA_HOME="$d/xdg-data" \
        XDG_CACHE_HOME="$d/cache" XDG_CONFIG_HOME="$d/config" "$@"
}
launcher_verdict() {
    local d=$1 rc; shift
    rm -f "$WORK/boot.log"
    run_env "$d" "$@" "$d/home/current/bin/dsmr-mcp-launch" >/dev/null 2>"$d/launcher.err" </dev/null
    rc=$?
    verdict "$rc"
}
register_verdict() {
    local d=$1 rc; shift
    rm -f "$WORK/boot.log"
    run_env "$d" DSMR_HOME="$d/home" CLAUDE_CONFIG="$d/claude.json" "$@" \
        make --no-print-directory -C "$REPO_ROOT" register SBCL="$WORK/bin/sbcl" \
        >"$d/register.out" 2>&1 </dev/null
    rc=$?
    case "$rc" in 0) echo accepted ;; *) echo refused ;; esac
}

R() { echo "$1/home/releases/r"; }

# Mutations. Each takes the case directory.
m_sound()            { :; }
m_no_worker()        { rm -f "$(R "$1")/core/dsmr.core.worker"; }
m_worker_ow()        { chmod o+w "$(R "$1")/core/dsmr.core.worker.manifest"; }
m_no_launcher()      { rm -f "$(R "$1")/bin/dsmr-mcp-launch"; }
m_no_paths()         { rm -f "$(R "$1")/scripts/release-paths.sh"; }
m_no_core_manifest() { rm -f "$(R "$1")/core/dsmr.core.manifest"; }
m_no_MANIFEST()      { rm -f "$(R "$1")/MANIFEST"; }
m_no_core()          { rm -f "$(R "$1")/core/dsmr.core"; }
m_sbcl_mismatch()    { printf 'sbcl-version 1.0.0\n' > "$(R "$1")/core/dsmr.core.manifest"; }
m_sbcl_unrecorded()  { printf 'kind release-server\n' > "$(R "$1")/core/dsmr.core.manifest"; }
m_noboot()           { printf 'noboot' > "$(R "$1")/core/dsmr.core"; }
m_git_tree()         { git init -q "$1"; }
m_home_ow()          { chmod o+w "$1/home"; }
m_releases_gw()      { chmod g+w "$1/home/releases"; }
m_root_gw()          { chmod g+w "$(R "$1")"; }
m_scripts_gw()       { chmod g+w "$(R "$1")/scripts"; }
m_paths_gw()         { chmod g+w "$(R "$1")/scripts/release-paths.sh"; }
m_bin_gw()           { chmod g+w "$(R "$1")/bin"; }
m_launcher_gw()      { chmod g+w "$(R "$1")/bin/dsmr-mcp-launch"; }
m_core_dir_gw()      { chmod g+w "$(R "$1")/core"; }
m_core_ow()          { chmod o+w "$(R "$1")/core/dsmr.core"; }
m_core_manifest_gw() { chmod g+w "$(R "$1")/core/dsmr.core.manifest"; }
m_home_empty()       { :; }   # HOME is emptied at run time

# row <name> <mutation> <expected> <runs launcher: yes|no>
ROWS=(
    "sound release|m_sound|accepted|yes"
    "no worker core (withheld only)|m_no_worker|accepted|yes"
    "worker manifest o+w (withheld only)|m_worker_ow|accepted|yes"
    "no launcher|m_no_launcher|refused|no"
    "no scripts/release-paths.sh|m_no_paths|refused|yes"
    "no core manifest|m_no_core_manifest|refused|yes"
    "no MANIFEST|m_no_MANIFEST|refused|yes"
    "no server core|m_no_core|refused|yes"
    "core built by another SBCL|m_sbcl_mismatch|refused|yes"
    "core manifest with no sbcl-version|m_sbcl_unrecorded|refused|yes"
    "core that does not boot|m_noboot|refused|yes"
    "root inside a git work tree|m_git_tree|refused|yes"
    "deploy home o+w|m_home_ow|refused|yes"
    "releases/ g+w|m_releases_gw|refused|yes"
    "release root g+w|m_root_gw|refused|yes"
    "scripts/ g+w|m_scripts_gw|refused|yes"
    "release-paths.sh g+w|m_paths_gw|refused|yes"
    "bin/ g+w|m_bin_gw|refused|yes"
    "launcher g+w|m_launcher_gw|refused|yes"
    "core/ g+w|m_core_dir_gw|refused|yes"
    "server core o+w|m_core_ow|refused|yes"
    "core manifest g+w|m_core_manifest_gw|refused|yes"
    "HOME empty|m_home_empty|refused|yes"
)

note "launcher and register agree on every release shape"
n=0
for spec in "${ROWS[@]}"; do
    IFS='|' read -r name mut expect uses_launcher <<<"$spec"
    n=$((n + 1))
    d="$WORK/case$n"
    build "$d"
    "$mut" "$d"
    extra=()
    [ "$mut" = m_home_empty ] && extra=(HOME=)
    reg=$(register_verdict "$d" "${extra[@]}")
    try "register: $name is $expect" "got $reg: $(tail -n 3 "$d/register.out" | tr '\n' ' ')" \
        test "$reg" = "$expect"
    if [ "$uses_launcher" = yes ]; then
        lau=$(launcher_verdict "$d" "${extra[@]}")
        try "launcher: $name is $expect" "got $lau: $(tail -n 2 "$d/launcher.err" | tr '\n' ' ')" \
            test "$lau" = "$expect"
        try "both agree on $name" "register $reg, launcher $lau" test "$reg" = "$lau"
    fi
    chmod -R u+w "$d" 2>/dev/null
done

note "register boots the physical release it checked, never current"
d="$WORK/boot"
build "$d"
register_verdict "$d" >/dev/null
try "register boots the resolved release core" "boot.log: $(cat "$WORK/boot.log" 2>/dev/null)" \
    grep -qF "core=$(cd -P "$d/home/releases/r" && pwd -P)/core/dsmr.core " "$WORK/boot.log"

printf '\nrelease-guard-test: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
