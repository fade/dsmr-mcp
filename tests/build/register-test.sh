#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises `make register` against planted releases with a stub SBCL, so the
# scratch-home refusal is checked without booting a core or writing a real
# Claude Code config. Every run has HOME at $WORK/fakehome, so the default
# CLAUDE_CONFIG is $WORK/fakehome/.claude.json; the stub records the deploy
# home and config it was handed and writes nothing.
#
# Usage: tests/build/register-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/register-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

FAKEHOME="$WORK/fakehome"
mkdir -p "$WORK/bin" "$FAKEHOME"

# The stub answers --version with 9.9.9 and exits 0 for the boot probe, which
# the launcher's checks run before register boots; any other run is the
# registration and is logged.
cat > "$WORK/bin/sbcl" <<STUB
#!/bin/sh
case " \$* " in
  *" --version "*) echo "SBCL 9.9.9"; exit 0 ;;
  *"(sb-ext:exit)"*) exit 0 ;;
esac
printf '%s|%s\n' "\$DSMR_HOME" "\$DSMR_REGISTER_CONFIG" >> "$WORK/boot.log"
STUB
chmod +x "$WORK/bin/sbcl"

# plant <home>: a sound release under <home>/current. Modes are set outright,
# so the result does not depend on the umask.
plant() {
    local r="$1/releases/r"
    mkdir -p "$r/core" "$r/bin" "$r/scripts"
    printf 'planted core' > "$r/core/dsmr.core"
    printf 'sbcl-version 9.9.9\n' > "$r/core/dsmr.core.manifest"
    printf 'commit 0000000\n' > "$r/MANIFEST"
    cp "$REPO_ROOT/scripts/release-paths.sh" "$r/scripts/release-paths.sh"
    cp "$REPO_ROOT/scripts/release-launch.sh" "$r/bin/dsmr-mcp-launch"
    chmod 755 "$1" "$1/releases" "$r" "$r/core" "$r/bin" "$r/scripts" "$r/bin/dsmr-mcp-launch"
    chmod 644 "$r/core/dsmr.core" "$r/core/dsmr.core.manifest" "$r/MANIFEST" "$r/scripts/release-paths.sh"
    ln -sfn releases/r "$1/current"
}

# register [VAR=value...]: run make register; output in OUT, status in RC.
OUT=""; RC=0
register() {
    rm -f "$WORK/boot.log"
    OUT=$(env -i HOME="$FAKEHOME" PATH="$WORK/bin:$PATH" XDG_STATE_HOME="$WORK/state" \
              XDG_CACHE_HOME="$WORK/cache" "$@" \
              make --no-print-directory -C "$REPO_ROOT" register SBCL="$WORK/bin/sbcl" 2>&1)
    RC=$?
}
booted() { [ -s "$WORK/boot.log" ]; }
boot_line() { cat "$WORK/boot.log" 2>/dev/null; }

note "scratch home with the host's config"
plant "$WORK/xdg/dsmr-mcp"
register XDG_DATA_HOME="$WORK/xdg"
try "a scratch XDG_DATA_HOME with the default config is refused" "rc=$RC: $OUT" test "$RC" -ne 0
try "refusal names the deploy home" "$OUT" has "$OUT" "deploy home $WORK/xdg/dsmr-mcp is a scratch home but CLAUDE_CONFIG is the host's config"
try "refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"
try "refusal writes no config" "found $FAKEHOME/.claude.json" test ! -e "$FAKEHOME/.claude.json"

register XDG_DATA_HOME="$WORK/xdg" DSMR_HOME="$WORK/xdg/dsmr-mcp"
try "DSMR_HOME equal to a scratch XDG_DATA_HOME home is refused" "rc=$RC: $OUT" test "$RC" -ne 0
try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"

plant "$WORK/scratch"
register DSMR_HOME="$WORK/scratch"
try "a scratch DSMR_HOME with the default config is refused" "rc=$RC: $OUT" test "$RC" -ne 0
try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"

ln -s "$FAKEHOME/.claude.json" "$WORK/config-link.json"
register DSMR_HOME="$WORK/scratch" CLAUDE_CONFIG="$WORK/config-link.json"
try "a link to the host's config is refused too" "rc=$RC: $OUT" test "$RC" -ne 0
try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"

: > "$FAKEHOME/.claude.json"
ln "$FAKEHOME/.claude.json" "$WORK/config-hard.json"
register DSMR_HOME="$WORK/scratch" CLAUDE_CONFIG="$WORK/config-hard.json"
try "a hard link to the host's config is refused" "rc=$RC: $OUT" test "$RC" -ne 0
try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"
rm -f "$WORK/config-hard.json" "$FAKEHOME/.claude.json"

ln -s "$WORK/xdg" "$FAKEHOME/xdg-link"
register XDG_DATA_HOME="$FAKEHOME/xdg-link"
try "an XDG_DATA_HOME under HOME that resolves outside it is refused" "rc=$RC: $OUT" test "$RC" -ne 0
try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"
rm -f "$FAKEHOME/xdg-link"

note "scratch home with a scratch config"
register XDG_DATA_HOME="$WORK/xdg" CLAUDE_CONFIG="$WORK/scratch.json"
try "a scratch home with a scratch config registers" "rc=$RC: $OUT" test "$RC" -eq 0
try "it boots with that home and config" "booted: $(boot_line)" \
    test "$(boot_line)" = "$WORK/xdg/dsmr-mcp|$WORK/scratch.json"

note "the host's own home"
plant "$FAKEHOME/.local/share/dsmr-mcp"
register
try "the account's default home registers" "rc=$RC: $OUT" test "$RC" -eq 0
try "it boots with the default home and the host's config" "booted: $(boot_line)" \
    test "$(boot_line)" = "$FAKEHOME/.local/share/dsmr-mcp|$FAKEHOME/.claude.json"
plant "$FAKEHOME/data/dsmr-mcp"
register XDG_DATA_HOME="$FAKEHOME/data"
try "an XDG_DATA_HOME under HOME registers" "rc=$RC: $OUT" test "$RC" -eq 0
try "it boots with that home" "booted: $(boot_line)" \
    test "$(boot_line)" = "$FAKEHOME/data/dsmr-mcp|$FAKEHOME/.claude.json"

note "a release the launcher would refuse"
# Each case plants a sound release first, so a refusal can only come from the
# one path made unsafe; the host's config is the default, as for an account.
# release-guard-test.sh holds the full table of shapes.
refused_unsafe() {
    local label=$1; shift
    register "$@"
    try "$label is refused" "rc=$RC: $OUT" test "$RC" -ne 0
    try "that refusal boots nothing" "booted: $(boot_line)" test ! -e "$WORK/boot.log"
    try "that refusal names a path" "$OUT" has "$OUT" "writable"
}
rm -rf "$FAKEHOME/.local"
plant "$FAKEHOME/.local/share/dsmr-mcp"
register
try "a sound release registers (control)" "rc=$RC: $OUT" test "$RC" -eq 0
chmod g+w "$FAKEHOME/.local/share/dsmr-mcp/releases/r/core"
refused_unsafe "an account home whose core/ is group writable"
rm -rf "$FAKEHOME/.local"

plant "$WORK/unsafe"
chmod o+w "$WORK/unsafe"
refused_unsafe "a world writable deploy home" DSMR_HOME="$WORK/unsafe" CLAUDE_CONFIG="$WORK/unsafe.json"
chmod o-w "$WORK/unsafe"
chmod o+w "$WORK/unsafe/releases/r/core/dsmr.core"
refused_unsafe "a world writable server core" DSMR_HOME="$WORK/unsafe" CLAUDE_CONFIG="$WORK/unsafe.json"

printf '\nregister-test: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
