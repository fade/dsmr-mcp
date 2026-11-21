#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/release-paths.sh: path helpers for the deploy home and its state
# directory. Sourced, never executed. Every function reports a refusal on
# stderr and returns 1; none creates anything.

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
