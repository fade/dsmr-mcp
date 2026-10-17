#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/measure-worker-footprint.sh <worker-core> [count]
#
# Measure what idle hermetic workers booted from the worker core cost, and how
# fast they come up. I keep no warm standby worker because a worker from the
# core starts in a fraction of a second, and I let many sessions hold a worker
# each because idle workers booted from one image share its pages. This script
# measures both claims on the host it runs on, so the memory budget rests on a
# figure taken there rather than on one carried over from another machine.
#
# It starts COUNT workers (default 8) from the image one after another, timing
# each from launch to its handshake line, waits for them to settle, sums the
# proportional set size (PSS) of every worker from /proc/<pid>/smaps_rollup,
# and prints one line on stdout:
#
#   workers=<n> total_pss_kb=<t> avg_pss_kb=<a> max_handshake_ms=<m> median_handshake_ms=<d>
#
# PSS divides each shared page among the processes mapping it, so the total is
# what the workers really add to the host. Every worker is stopped and the
# scratch directory removed on exit, whatever happens. Diagnostics go to
# stderr; the exit status is 1 when the image is missing or a worker does not
# reach its handshake within 60 seconds.
set -u

SBCL="${SBCL:-sbcl}"
HANDSHAKE_TIMEOUT_S=60
SETTLE_S=2

log() { printf '%s [measure-worker-footprint] %s\n' "$(date -Is)" "$*" >&2; }
die() { log "$*"; exit 1; }

core="${1:-}"
count="${2:-8}"

[ -n "$core" ] || die "usage: $0 <worker-core> [count]"
[ -f "$core" ] || die "no worker core image at $core"
case "$count" in
  ''|*[!0-9]*) die "count must be a positive whole number, got '$count'" ;;
esac
[ "$count" -ge 1 ] || die "count must be at least 1"

scratch="$(mktemp -d -t dsmr-footprint.XXXXXX)" || die "cannot create a scratch directory"
pids=()

stop_workers() {
  local pid alive=()
  [ "${#pids[@]}" -gt 0 ] || return 0
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null && alive+=("$pid")
  done
  [ "${#alive[@]}" -gt 0 ] || return 0
  sleep 2
  for pid in "${alive[@]}"; do
    kill -KILL "$pid" 2>/dev/null
  done
  wait 2>/dev/null
}

cleanup() {
  stop_workers
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

boot_ms=()
for ((i = 1; i <= count; i++)); do
  out="$scratch/worker-$i.out"
  err="$scratch/worker-$i.err"
  : >"$out"
  # A fresh secret per worker, so the idle listener refuses anyone else.
  secret="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  start_ns="$(date +%s%N)"
  DSMR_PARENT_PID=$$ DSMR_WORKER_ID="footprint-$i" DSMR_WORKER_SECRET="$secret" \
    "$SBCL" --core "$core" --noinform --disable-debugger --no-userinit \
    --eval '(dsmr-mcp/src/hermetic/worker/main:start)' \
    >"$out" 2>"$err" </dev/null &
  pid=$!
  pids+=("$pid")
  deadline_ns=$((start_ns + HANDSHAKE_TIMEOUT_S * 1000000000))
  until grep -q '"tcp_port"' "$out" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 5 "$err" >&2
      die "worker $i (pid $pid) exited before its handshake"
    fi
    if [ "$(date +%s%N)" -ge "$deadline_ns" ]; then
      tail -n 5 "$err" >&2
      die "worker $i (pid $pid) gave no handshake within ${HANDSHAKE_TIMEOUT_S}s"
    fi
    sleep 0.005
  done
  end_ns="$(date +%s%N)"
  boot_ms+=($(((end_ns - start_ns) / 1000000)))
done

sleep "$SETTLE_S"

total_kb=0
for pid in "${pids[@]}"; do
  pss="$(awk '/^Pss:/ { print $2; exit }' "/proc/$pid/smaps_rollup" 2>/dev/null)"
  [ -n "$pss" ] || die "worker pid $pid is gone or its smaps_rollup is unreadable"
  total_kb=$((total_kb + pss))
done

mapfile -t sorted < <(printf '%s\n' "${boot_ms[@]}" | sort -n)
n="${#sorted[@]}"
max_ms="${sorted[n - 1]}"
if ((n % 2)); then
  median_ms="${sorted[n / 2]}"
else
  median_ms=$(((sorted[n / 2 - 1] + sorted[n / 2]) / 2))
fi

printf 'workers=%d total_pss_kb=%d avg_pss_kb=%d max_handshake_ms=%d median_handshake_ms=%d\n' \
  "$n" "$total_kb" $((total_kb / n)) "$max_ms" "$median_ms"
