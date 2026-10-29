# shellcheck shell=bash
#
# Kitty remote-control socket discovery, sourced by start-sisters.sh and
# restart-session-in-place.sh. Sets no options and prints nothing when sourced.

# Fill the array named by $1 with every socket under ${DSMR_KITTY_SOCKET_DIR:-/tmp}
# named kitty-* that the current user owns. A socket another user placed there is
# not one to type into. Returns 0 when there are none.
kitty_socket_paths() {
    local -n _ksp_out=$1
    local sock
    _ksp_out=()
    for sock in "${DSMR_KITTY_SOCKET_DIR:-/tmp}"/kitty-*; do
        [[ -S $sock && -O $sock ]] && _ksp_out+=("$sock")
    done
    return 0
}

# Print $1 without one leading "unix:", so KITTY_LISTEN_ON and a socket path compare equal.
kitty_socket_path() {
    printf '%s\n' "${1#unix:}"
}
