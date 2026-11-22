#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/release-paths.sh: path helpers for the deploy home and its state
# directory, and the checks a release must pass before it boots. Sourced, never
# executed. dsmr_home and dsmr_state_dir report a refusal on stderr and return
# 1; release_refusal, release_problem and worker_core_withheld print their
# reason on stdout. None creates anything.

# dsmr_home
# Print the deploy home: DSMR_HOME when set and not empty, else
# ${XDG_DATA_HOME:-$HOME/.local/share}/dsmr-mcp. Return 1 when HOME is needed
# and empty, or when the result is not an absolute path.
dsmr_home() {
  local home="${DSMR_HOME:-}"
  if [ -z "$home" ]; then
    if [ -n "${XDG_DATA_HOME:-}" ]; then
      home="$XDG_DATA_HOME/dsmr-mcp"
    elif [ -n "${HOME:-}" ]; then
      home="$HOME/.local/share/dsmr-mcp"
    else
      printf 'HOME is empty and DSMR_HOME is unset; set DSMR_HOME to an absolute path\n' >&2
      return 1
    fi
  fi
  case "$home" in
    /*) printf '%s\n' "$home" ;;
    *)
      printf 'deploy home %s is relative; give an absolute path\n' "$home" >&2
      return 1
      ;;
  esac
}

# host_home_p HOME
# Return 0 when HOME is the account's own deploy home, else 1. The account's
# home is $HOME/.local/share/dsmr-mcp, or $XDG_DATA_HOME/dsmr-mcp when
# XDG_DATA_HOME resolves to a directory under $HOME. Paths are compared
# resolved. Every other deploy home is a scratch home, so an XDG_DATA_HOME
# outside $HOME never names the host's own release.
host_home_p() {
  local home user data
  [ -n "${HOME:-}" ] || return 1
  home="$(realpath -m -- "$1")"
  user="$(realpath -m -- "$HOME")"
  [ "$home" = "$user/.local/share/dsmr-mcp" ] && return 0
  [ -n "${XDG_DATA_HOME:-}" ] || return 1
  data="$(realpath -m -- "$XDG_DATA_HOME")"
  case "$data/" in
    "$user"/*) [ "$home" = "$data/dsmr-mcp" ] ;;
    *) return 1 ;;
  esac
}

# host_config_p FILE
# Return 0 when FILE is the account's Claude Code config, $HOME/.claude.json:
# the same file, a symlink or hard link to it included, or, when either file is
# absent, the same resolved path. Else return 1.
host_config_p() {
  local account
  [ -n "${HOME:-}" ] || return 1
  account="$HOME/.claude.json"
  if [ -e "$1" ] && [ -e "$account" ]; then
    [ "$1" -ef "$account" ]
    return
  fi
  [ "$(realpath -m -- "$1")" = "$(realpath -m -- "$account")" ]
}

# dsmr_state_dir
# Print ${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp under the same rules as
# dsmr_home.
dsmr_state_dir() {
  local state
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    state="$XDG_STATE_HOME/dsmr-mcp"
  elif [ -n "${HOME:-}" ]; then
    state="$HOME/.local/state/dsmr-mcp"
  else
    printf 'HOME is empty and XDG_STATE_HOME is unset; set XDG_STATE_HOME to an absolute path\n' >&2
    return 1
  fi
  case "$state" in
    /*) printf '%s\n' "$state" ;;
    *)
      printf 'state directory %s is relative; give an absolute path\n' "$state" >&2
      return 1
      ;;
  esac
}

# physical_dir DIR
# Print DIR with every symlink resolved. Return 1 when DIR is not a directory.
physical_dir() {
  (cd -P "$1" 2>/dev/null && pwd -P)
}

# inside_work_tree DIR
# Return 0 when DIR is inside a git work tree.
inside_work_tree() {
  [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}

# manifest_sbcl_version MANIFEST
# Print the sbcl-version a core manifest records, or nothing.
manifest_sbcl_version() {
  awk '/^sbcl-version /{ $1=""; sub(/^ /,""); print; exit }' "$1" 2>/dev/null
}

# running_sbcl_version
# Print the version "${SBCL:-sbcl}" --version reports, or nothing.
running_sbcl_version() {
  "${SBCL:-sbcl}" --version 2>/dev/null | awk '{print $2; exit}'
}

# foreign_owned PATH
# Return 0 when PATH exists and is not owned by the running user.
foreign_owned() {
  [ -e "$1" ] && [ ! -O "$1" ]
}

# others_can_write PATH
# Return 0 when PATH exists and is group or world writable.
others_can_write() {
  [ -e "$1" ] && [ -n "$(find "$1" -maxdepth 0 -perm /022 2>/dev/null)" ]
}

# release_path_problem ROOT [LAUNCHER]
# Print `<reason>; <remedy>` and return 1 when a path the release's code or
# cores can be replaced through is owned by another user or is group or world
# writable; print nothing and return 0 when all are sound. The paths: the
# deploy home and releases/ above ROOT, ROOT, scripts/,
# scripts/release-paths.sh, bin/, LAUNCHER (default bin/dsmr-mcp-launch),
# core/, the server core and its manifest. A path that does not exist is left
# to the presence checks of release_problem. The launcher and preflight both
# refuse with this list.
release_path_problem() {
  local root="$1" launcher="${2:-$1/bin/dsmr-mcp-launch}" path
  for path in "$(dirname "$(dirname "$root")")" "$(dirname "$root")" "$root" \
              "$root/scripts" "$root/scripts/release-paths.sh" "$root/bin" "$launcher" \
              "$root/core" "$root/core/dsmr.core" "$root/core/dsmr.core.manifest"; do
    if foreign_owned "$path"; then
      printf '%s is not owned by %s; restore ownership and permissions of %s\n' \
             "$path" "$(id -un)" "$path"
      return 1
    fi
    if others_can_write "$path"; then
      printf '%s is group or world writable; restore ownership and permissions of %s\n' \
             "$path" "$path"
      return 1
    fi
  done
  return 0
}

# worker_core_withheld ROOT
# Print why the release's worker core must not be offered and return 0, or
# print nothing and return 1 when it may be. The launcher offers the core to
# workers only then, and preflight reports it. The core and its manifest must
# be owned by the running user and not group or world writable, as every worker
# boots the core. SBCL refuses a core another build saved, so the manifest's
# sbcl-version must equal the running SBCL's.
worker_core_withheld() {
  local wcore="$1/core/dsmr.core.worker" recorded current path
  if [ ! -f "$wcore" ]; then
    printf 'no worker core at %s' "$wcore"
    return 0
  fi
  if [ ! -f "$wcore.manifest" ]; then
    printf 'no manifest at %s.manifest' "$wcore"
    return 0
  fi
  for path in "$wcore" "$wcore.manifest"; do
    if foreign_owned "$path"; then
      printf '%s is not owned by %s' "$path" "$(id -un)"
      return 0
    fi
    if others_can_write "$path"; then
      printf '%s is group or world writable' "$path"
      return 0
    fi
  done
  recorded="$(manifest_sbcl_version "$wcore.manifest")"
  current="$(running_sbcl_version)"
  if [ -z "$recorded" ] || [ "$recorded" != "$current" ]; then
    printf 'built by SBCL %s, running SBCL is %s' "${recorded:-unknown}" "${current:-unknown}"
    return 0
  fi
  return 1
}

# release_problem ROOT [LAUNCHER]
# Check the release at ROOT before anything boots from it. Print
# `<reason>; <remedy>` for the first problem found and return 1, or print
# nothing and return 0. Checks in order: release_path_problem ROOT LAUNCHER;
# the core, its manifest, MANIFEST, scripts/release-paths.sh and the launcher
# present; the core's sbcl-version equal to the running SBCL's; a boot of the
# core that exits 0, with stdin and stdout closed and DSMR_BOOT_PROBE_TIMEOUT
# seconds (default 30) to do it.
release_problem() {
  local root="$1" core="$1/core/dsmr.core" path recorded current status
  release_path_problem "$root" "${2:-}" || return 1
  for path in "$core" "$core.manifest" "$root/MANIFEST" \
              "$root/scripts/release-paths.sh" "${2:-$root/bin/dsmr-mcp-launch}"; do
    if [ ! -f "$path" ]; then
      printf 'no %s; run make deploy REF=<sha>\n' "$path"
      return 1
    fi
  done
  recorded="$(manifest_sbcl_version "$core.manifest")"
  current="$(running_sbcl_version)"
  if [ -z "$recorded" ] || [ "$recorded" != "$current" ]; then
    printf '%s was built by SBCL %s, running SBCL is %s; run make deploy REF=<sha> with this SBCL\n' \
           "$core" "${recorded:-unknown}" "${current:-unknown}"
    return 1
  fi
  timeout "${DSMR_BOOT_PROBE_TIMEOUT:-30}" "${SBCL:-sbcl}" --core "$core" \
          --noinform --non-interactive --no-sysinit --no-userinit \
          --eval '(sb-ext:exit)' <&- >&- 2>/dev/null
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s does not boot (probe exited %s); run make deploy REF=<sha>\n' "$core" "$status"
    return 1
  fi
  return 0
}

# release_refusal ROOT [LAUNCHER]
# The launcher's complete refusal sequence after release-paths.sh is sourced,
# for the launcher, `make register` and any other caller that must agree with
# it. Print `<reason>; <remedy>` for the first problem found and return 1, or
# print nothing and return 0. Checks in order: HOME set and not empty; neither
# LAUNCHER's directory (default ROOT/bin) nor ROOT inside a git work tree;
# release_problem ROOT LAUNCHER.
release_refusal() {
  local root="$1" launcher="${2:-$1/bin/dsmr-mcp-launch}" path
  if [ -z "${HOME:-}" ]; then
    printf 'HOME is unset or empty; start the server with HOME set\n'
    return 1
  fi
  for path in "$(dirname "$launcher")" "$root"; do
    if inside_work_tree "$path"; then
      printf '%s is inside a git work tree; a release is never run from a checkout; run make deploy REF=<sha> and make register\n' "$path"
      return 1
    fi
  done
  release_problem "$root" "$launcher"
}
