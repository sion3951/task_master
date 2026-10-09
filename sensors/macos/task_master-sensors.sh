#!/bin/sh
# Root-owned launchd helper. Its only input is Apple's fixed sensor command;
# the desktop reads a bounded, atomic, non-secret hardware snapshot.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL
umask 022
state=/var/run/task_master
if [ -L "$state" ]; then exit 1; fi
mkdir -p "$state"
chown root:wheel "$state"
chmod 0755 "$state"
work=$(mktemp -d "$state/.sensors.XXXXXX")
child=
cleanup() {
    if [ -n "$child" ]; then kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
    rm -rf "$work"
    rm -f "$state/sensors.txt"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
# Intel and Apple Silicon expose different samplers. Probe the richest
# supported combination once, then retain it across reporting intervals.
samplers=
for candidate in cpu_power,gpu_power,smc cpu_power,gpu_power cpu_power,smc cpu_power; do
    /usr/bin/powermetrics --samplers "$candidate" --sample-count 1 --sample-rate 1000 >"$work/raw" 2>"$work/error" &
    child=$!
    if wait "$child"; then samplers=$candidate; child=; break; fi
    child=
done
if [ -z "$samplers" ]; then cat "$work/error" >&2; exit 1; fi
while :; do
    {
        printf 'TASK_MASTER_SENSORS 1 %s\n' "$(date +%s)"
        cat "$work/raw"
    } >"$work/snapshot"
    chmod 0644 "$work/snapshot"
    mv -f "$work/snapshot" "$state/sensors.txt"
    /usr/bin/powermetrics --samplers "$samplers" --sample-count 1 --sample-rate 1000 >"$work/raw" 2>"$work/error" &
    child=$!
    if ! wait "$child"; then child=; cat "$work/error" >&2; exit 1; fi
    child=
done
