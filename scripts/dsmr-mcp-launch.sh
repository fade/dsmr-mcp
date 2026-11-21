#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/dsmr-mcp-launch.sh: forwards to the deployed release's launcher,
# <deploy home>/current/bin/dsmr-mcp-launch, with the same arguments. It builds
# nothing, loads no source and boots nothing from this checkout. It exists
# because a registration naming this path may outlive the switch to releases;
# `make register` names the release launcher directly.
#
# Exits 78 with the remedy on stderr when the deploy home cannot be resolved or
# holds no executable release launcher. stdout is left to the release launcher.
set -u

here="$(cd -P "$(dirname "$(readlink -f "$0")")" && pwd -P)"
# shellcheck source=release-paths.sh
. "$here/release-paths.sh"

log() { printf '%s [dsmr-launch] %s\n' "$(date -Is)" "$*" >&2; }

home="$(dsmr_home)" || exit 78
target="$home/current/bin/dsmr-mcp-launch"
if [ -x "$target" ]; then
  log "registration names the checkout launcher $(readlink -f "$0"); forwarding to $target; run make register to name the release launcher directly"
  exec "$target" "$@"
fi
log "cannot start: no deployed release at $home/current; run make deploy REF=<sha>, then make register"
exit 78
